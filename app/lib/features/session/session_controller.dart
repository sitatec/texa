import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_quick_video_encoder/flutter_quick_video_encoder.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../data/db.dart';
import '../../data/models.dart';
import '../ai/ai_actions.dart';
import '../ai/ai_client.dart';
import '../board/board_models.dart';
import '../playback/playback_engine.dart';
import '../playback/speech_chunker.dart';
import '../playback/tts_service.dart';
import '../turn/sherpa_speech.dart';
import 'board_controller.dart';

enum TurnState { listening, capturing, thinking, speaking, muted }

/// Coordinates mic/VAD capture, streaming AI playback and autosave for a session.
class SessionController extends ChangeNotifier {
  SessionController({
    required this.db,
    required this.session,
    required this.settings,
    required this.speech,
    required this.vadPath,
  }) : speaker = SpeechSpeaker(synthesise: speech.synthesise);
  final AppDb db;
  Session session;
  final AppSettings settings;
  final SherpaSpeech speech;
  final String? vadPath;
  final BoardController board = BoardController();
  final GlobalKey captureKey = GlobalKey();
  final SpeechSpeaker speaker;
  TurnState state = TurnState.listening;
  bool micMuted = false;
  bool captionsOn = true;
  String? errorMessage;
  String? lastFailedText;
  List<ChatMessage> messages = [];
  bool _disposed = false;

  final AudioRecorder _recorder = AudioRecorder();
  sherpa.VoiceActivityDetector? _vad;
  final List<double> _vadBuffer = [];
  StreamSubscription<Uint8List>? _micSub;
  bool _micRunning = false;
  bool _hasMicPermission = false;
  DateTime? _speechStart;
  DateTime? _lastVoiceAt;
  bool _capturing = false;
  bool _drewDuringCapture = false;
  final BytesBuilder _pcm = BytesBuilder(copy: false);
  final List<Uint8List> _frameRgbas = [];
  Timer? _frameTimer;
  Timer? _silenceTimer;
  Timer? _saveTimer;

  PlaybackQueue _queue = PlaybackQueue();
  bool _playing = false;
  bool _producerDone = true;
  bool _playbackCancelled = false;
  SuspendedPlayback? _suspended;
  bool _suspendedFromVoice = false;
  StreamSubscription<AiEvent>? _aiSub;
  AiClient? _activeClient;
  Completer<void>? _playbackIdle;
  String _currentSpeechChunkForSuspend = '';
  int _playbackGeneration = 0;

  Future<void> setSubject(String? subject) async {
    session = session.copyWith(subject: subject, clearSubject: subject == null);
    final all = await db.loadSessions();
    final i = all.indexWhere((e) => e.id == session.id);
    if (i >= 0) {
      all[i] = session;
      await db.saveSessions(all);
    }
    notifyListeners();
  }

  String get statusKey {
    if (micMuted) return 'muted';
    return switch (state) {
      TurnState.capturing => 'capturing',
      TurnState.thinking => 'thinking',
      TurnState.speaking => 'speaking',
      _ => 'listening',
    };
  }

  Future<void> init() async {
    captionsOn = settings.captionsDefault;
    messages = await db.loadMessages(session.id);
    board.restore(BoardSnapshot.decode(await db.loadBoard(session.id)));
    board.addListener(_scheduleSave);
    if (!settings.micPermissionDenied) await startListening();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 450), _saveNow);
  }

  Future<void> _saveNow() async {
    String? thumb;
    try {
      final png = await captureBoardPng(pixelRatio: 0.12);
      if (png != null) thumb = base64Encode(png);
    } catch (_) {}
    await db.saveBoard(session.id, board.snapshot(thumb).encode());
    if (thumb != null) {
      final all = await db.loadSessions();
      final i = all.indexWhere((e) => e.id == session.id);
      if (i >= 0) {
        all[i] = all[i].copyWith(
          updatedAt: DateTime.now(),
          thumbnailBase64: thumb,
        );
        await db.saveSessions(all);
      }
    }
  }

  Future<void> flushSave() async {
    _saveTimer?.cancel();
    await _saveNow();
  }

  // ---------- Board capture ----------
  Future<ui.Image?> _captureImage(double pixelRatio) async {
    final ctx = captureKey.currentContext;
    if (ctx == null) return null;
    final boundary = ctx.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return null;
    return boundary.toImage(pixelRatio: pixelRatio);
  }

  Future<Uint8List?> captureBoardPng({double pixelRatio = 0.45}) async {
    final img = await _captureImage(pixelRatio);
    if (img == null) return null;
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return data?.buffer.asUint8List();
  }

  Future<void> _captureFrame() async {
    try {
      final img = await _captureImage(frameWidth / boardWidth);
      if (img == null) return;
      final rgba = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      if (rgba != null && rgba.lengthInBytes == frameWidth * frameHeight * 4) {
        _frameRgbas.add(Uint8List.fromList(rgba.buffer.asUint8List()));
      }
    } catch (e) {
      debugPrint('Texa frame capture: $e');
    }
  }

  // ---------- Microphone / VAD ----------
  Future<void> startListening() async {
    if (_micRunning || micMuted || _disposed) return;
    try {
      _hasMicPermission = await _recorder.hasPermission();
      if (!_hasMicPermission) {
        notifyListeners();
        return;
      }
      if (vadPath != null && _vad == null) {
        try {
          _vad = speech.createVad(vadPath!);
        } catch (e) {
          debugPrint('Texa VAD init: $e');
          _vad = null;
        }
      }
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: sampleRate,
          numChannels: 1,
          echoCancel: true,
          noiseSuppress: true,
          autoGain: true,
        ),
      );
      _micRunning = true;
      _micSub = stream.listen(
        _onPcm,
        onError: (Object e) => debugPrint('Texa mic: $e'),
      );
    } catch (e) {
      debugPrint('Texa mic start: $e');
      _hasMicPermission = false;
    }
    notifyListeners();
  }

  bool get hasMicPermission => _hasMicPermission;

  void _onPcm(Uint8List data) {
    // Silero VAD (sherpa-onnx) is the single voice detector on every
    // platform: PCM16 is converted once to float samples and fed in
    // window-sized chunks; the same bytes are buffered for the turn video.
    final count = data.length ~/ 2;
    if (count == 0) {
      return;
    }
    final vad = _vad;
    if (vad == null) {
      return;
    }
    final view = ByteData.sublistView(data);
    var voice = false;
    try {
      for (var i = 0; i < count; i++) {
        _vadBuffer.add(view.getInt16(i * 2, Endian.little) / 32768.0);
      }
      while (_vadBuffer.length >= 512) {
        vad.acceptWaveform(Float32List.fromList(_vadBuffer.sublist(0, 512)));
        _vadBuffer.removeRange(0, 512);
        if (vad.isDetected()) {
          voice = true;
        }
      }
    } catch (e) {
      debugPrint('Texa VAD: $e');
      return;
    }
    final now = DateTime.now();
    if (voice) {
      _lastVoiceAt = now;
      if (state == TurnState.speaking && !_playbackCancelled) {
        unawaited(interruptPlayback(fromVoice: true));
      }
      if (!_capturing &&
          (state == TurnState.listening || state == TurnState.speaking)) {
        _beginCapture(now);
      }
      if (_capturing) {
        _pcm.add(data);
      }
    } else if (_capturing) {
      _pcm.add(data);
      if (_lastVoiceAt != null &&
          now.difference(_lastVoiceAt!).inMilliseconds >= vadSilenceMs) {
        unawaited(_finaliseCapture());
      }
    }
  }

  void _beginCapture(DateTime now) {
    if (_capturing) return;
    _capturing = true;
    _speechStart = now;
    _drewDuringCapture = false;
    _pcm.clear();
    _frameRgbas.clear();
    state = TurnState.capturing;
    notifyListeners();
    unawaited(_captureFrame());
    _frameTimer?.cancel();
    _frameTimer = Timer.periodic(
      const Duration(milliseconds: frameIntervalMs),
      (_) => unawaited(_captureFrame()),
    );
  }

  Future<void> _finaliseCapture() async {
    if (!_capturing) return;
    _capturing = false;
    _frameTimer?.cancel();
    final speechMs = _speechStart != null && _lastVoiceAt != null
        ? _lastVoiceAt!.difference(_speechStart!).inMilliseconds
        : 0;
    final pcmBytes = _pcm.takeBytes();
    // False alarm during playback: brief noise resumes the interrupted chunk.
    if (_suspended != null &&
        _suspendedFromVoice &&
        speechMs < sustainedSpeechMs &&
        !_drewDuringCapture) {
      _resumeSuspended();
      return;
    }
    if (speechMs < 120 || pcmBytes.isEmpty) {
      state = _playing ? TurnState.speaking : TurnState.listening;
      notifyListeners();
      return;
    }
    final suspended = _suspended;
    _suspended = null;
    await _sendCapturedTurn(pcmBytes: pcmBytes, interruption: suspended);
  }

  Future<void> setMuted(bool muted) async {
    micMuted = muted;
    if (muted) {
      if (_capturing) {
        await _finaliseCapture();
      }
      await _stopMic();
      state = TurnState.muted;
    } else {
      state = TurnState.listening;
      await startListening();
    }
    notifyListeners();
  }

  Future<void> _stopMic() async {
    try {
      await _micSub?.cancel();
      await _recorder.stop();
    } catch (_) {}
    _micRunning = false;
  }

  // ---------- Sending a turn (streaming) ----------
  /// Sends the current board (typed question and/or drawing-only ask).
  Future<void> askTexa(String typedText) async {
    if (state == TurnState.thinking) return;
    await _captureFrame();
    final suspended = _suspended;
    _suspended = null;
    await _sendCapturedTurn(
      pcmBytes: Uint8List(0),
      typedText: typedText,
      interruption: suspended,
    );
  }

  Future<void> _sendCapturedTurn({
    required Uint8List pcmBytes,
    String? typedText,
    SuspendedPlayback? interruption,
  }) async {
    state = TurnState.thinking;
    errorMessage = null;
    notifyListeners();
    final String videoB64;
    try {
      videoB64 = await _encodeVideo(pcmBytes);
    } on AppError catch (e) {
      // Encode failure: the turn is not sent (Tech Specs 7.4). The board is
      // untouched and the student simply speaks again.
      errorMessage = e.message;
      state = TurnState.listening;
      notifyListeners();
      return;
    }
    final studentPayload = <String, dynamic>{
      'text': typedText ?? '',
      'hasVideo': true,
    };
    messages.add(
      ChatMessage(
        id: newId(),
        sessionId: session.id,
        role: 'student',
        kind: 'video-turn',
        payloadJson: jsonEncode(studentPayload),
        createdAt: DateTime.now(),
      ),
    );
    await db.saveMessages(session.id, messages);
    lastFailedText = typedText;
    try {
      await _streamReply(
        videoB64: videoB64,
        typedText: typedText,
        interruption: interruption,
      );
    } on AppError catch (e) {
      errorMessage = e.message;
      await db.appendLog('turn failed: ${e.message} ${e.cause ?? ''}');
      state = TurnState.listening;
      notifyListeners();
    } catch (e) {
      errorMessage =
          'That turn could not be sent. Your work is safe on the board.';
      await db.appendLog('turn failed: $e');
      state = TurnState.listening;
      notifyListeners();
    }
  }

  Future<String> _encodeVideo(Uint8List pcmBytes) async {
    if (_frameRgbas.isEmpty) {
      throw const AppError(
        'I could not capture the board just now. Please try again.',
      );
    }
    io.File? file;
    try {
      final dir = await getTemporaryDirectory();
      file = io.File('${dir.path}/turn_${newId()}.mp4');
      await FlutterQuickVideoEncoder.setup(
        width: frameWidth,
        height: frameHeight,
        fps: 1,
        videoBitrate: 500000,
        profileLevel: ProfileLevel.highAutoLevel,
        audioChannels: 1,
        audioBitrate: 64000,
        sampleRate: sampleRate,
        filepath: file.path,
      );
      // Typed turns carry no mic audio: their seconds are padded with
      // silence by the same loop that pads a short final spoken second.
      final seconds = _frameRgbas.length;
      for (var i = 0; i < seconds; i++) {
        await FlutterQuickVideoEncoder.appendVideoFrame(_frameRgbas[i]);
        final start = i * sampleRate * 2;
        final chunk = Uint8List(sampleRate * 2);
        if (start < pcmBytes.length) {
          chunk.setRange(
            0,
            (pcmBytes.length - start).clamp(0, chunk.length),
            pcmBytes.sublist(start),
          );
        }
        await FlutterQuickVideoEncoder.appendAudioFrame(chunk);
      }
      await FlutterQuickVideoEncoder.finish();
      return base64Encode(await file.readAsBytes());
    } catch (e) {
      try {
        await FlutterQuickVideoEncoder.finish();
      } catch (_) {}
      if (e is AppError) rethrow;
      throw AppError(
        'I could not prepare that turn to send. Your work is safe on the board — please try again.',
        cause: e,
      );
    } finally {
      try {
        await file?.delete();
      } catch (_) {}
    }
  }

  Future<void> _streamReply({
    String? videoB64,
    String? typedText,
    SuspendedPlayback? interruption,
  }) async {
    final client = AiClient(settings.apiKey);
    _activeClient = client;
    _queue = PlaybackQueue();
    _producerDone = false;
    _playbackCancelled = false;
    _playing = true;
    state = TurnState.speaking;
    notifyListeners();
    final generation = _playbackGeneration;
    final consumer = _consumeQueue(generation);
    final splitter = StreamingSpeechSplitter();
    final held = <String>[];
    var textReleased = false;
    var rawText = '';
    var sawTool = false;
    final toolCallsRaw = <Map<String, dynamic>>[];
    try {
      await for (final event in client.streamTurn(
        model: session.model,
        history: messages,
        registry: board.registry,
        videoBase64: videoB64,
        typedText: typedText,
        interruptionContext: interruption?.toContext(),
        subject: session.subject,
      )) {
        if (generation != _playbackGeneration) break;
        if (event is AiTextDelta) {
          rawText += event.text;
          if (rawText.contains(ignoreTurnSentinel) ||
              ignoreTurnSentinel.startsWith(rawText.trim())) {
            continue;
          }
          for (final sentence in splitter.add(event.text)) {
            if (!textReleased) {
              held.add(sentence);
              if (held.length >= 2) {
                textReleased = true;
                for (final h in held) {
                  _queue.add(TextItem(h));
                }
                held.clear();
              }
            } else {
              _queue.add(TextItem(sentence));
            }
          }
        } else if (event is AiToolCallComplete) {
          sawTool = true;
          toolCallsRaw.add({'name': event.name, 'args': event.args});
          for (final h in held) {
            _queue.add(TextItem(h));
          }
          held.clear();
          textReleased = true;
          for (final s in splitter.flush()) {
            _queue.add(TextItem(s));
          }
          if (event.name == 'resume_explanation') {
            _queue.add(ResumeItem());
          } else {
            _queue.add(ActionItem(event.name, event.args));
          }
        } else if (event is AiStreamDone) {
          rawText = event.fullText;
          final parsed = parseReply(
            rawText,
            toolCallsRaw
                .map(
                  (c) => (
                    name: c['name'] as String,
                    args: c['args'] as Map<String, dynamic>,
                  ),
                )
                .toList(),
          );
          // Save the AI reply as received, before playback drains.
          messages.add(
            ChatMessage(
              id: newId(),
              sessionId: session.id,
              role: 'ai',
              kind: sawTool ? 'actions' : 'text',
              payloadJson: jsonEncode(event.raw),
              createdAt: DateTime.now(),
            ),
          );
          await db.saveMessages(session.id, messages);
          if (parsed.kind == 'ignore') {
            held.clear();
            _queue.clearPending();
            _producerDone = true;
            if (_suspended != null) {
              _resumeSuspended();
            } else {
              state = TurnState.listening;
            }
            await consumer;
            return;
          }
          if (parsed.kind == 'invalidSentinel') {
            await db.appendLog('invalid sentinel reply discarded: $rawText');
            held.clear();
            _queue.clearPending();
            _producerDone = true;
            await consumer;
            state = TurnState.listening;
            notifyListeners();
            return;
          }
          for (final s in splitter.flush()) {
            held.add(s);
          }
          for (final h in held) {
            _queue.add(TextItem(h));
          }
          held.clear();
        }
      }
    } finally {
      _producerDone = true;
      client.close();
      if (identical(_activeClient, client)) _activeClient = null;
    }
    await consumer;
    if (!_playbackCancelled) {
      state = micMuted ? TurnState.muted : TurnState.listening;
      notifyListeners();
    }
  }

  // ---------- Playback consumer ----------
  Future<void> _consumeQueue(int generation) async {
    _playbackIdle = Completer<void>();
    try {
      while (generation == _playbackGeneration && !_disposed) {
        final item = _queue.next();
        if (item == null) {
          if (_producerDone) break;
          await Future<void>.delayed(const Duration(milliseconds: 40));
          continue;
        }
        if (item is ResumeItem) {
          final s = _suspended;
          _suspended = null;
          if (s != null) {
            _queue.addAll(s.remaining);
          }
          continue;
        }
        if (generation != _playbackGeneration) break;
        if (item is TextItem) {
          _currentSpeechChunkForSuspend =
              splitSpeech(item.text).firstOrNull ?? item.text;
          speaker.enqueueText(item.text);
          await speaker.drained;
          _queue.completed.add({'tool': 'text', 'rect': ''});
        } else if (item is ActionItem) {
          await _executeAction(item);
        }
        if (_disposed) break;
      }
    } finally {
      _playing = false;
      final c = _playbackIdle;
      _playbackIdle = null;
      if (c != null && !c.isCompleted) c.complete();
    }
  }

  Future<void> _executeAction(ActionItem item) async {
    final rect = board.rectForArgs(item.args);
    if (rect != null && item.tool != 'remove_element') {
      await board.frameRect(clampToBoard(rect));
    }
    final speech = item.speech;
    var animDone = false;
    Future<void> animate() async {
      final sw = Stopwatch()..start();
      while (sw.elapsedMilliseconds < 450 && !_playbackCancelled) {
        final el = board.elements
            .where((e) => e.id == item.elementId)
            .firstOrNull;
        if (el != null) {
          el.progress = (sw.elapsedMilliseconds / 450).clamp(0, 1);
          board.notifyListenersPublic();
        }
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      animDone = true;
    }

    Rect? applied;
    final actionFuture = board.applyAction(item, animate: animate);
    if (speech != null && speech.isNotEmpty) {
      _currentSpeechChunkForSuspend = splitSpeech(speech).firstOrNull ?? speech;
      speaker.enqueueText(speech);
    }
    applied = await actionFuture;
    if (speech != null && speech.isNotEmpty) await speaker.drained;
    if (!animDone) await animate();
    if (applied != null) {
      _queue.completed.add({
        'tool': item.tool,
        'rect':
            '${applied.left.round()},${applied.top.round()},${applied.width.round()}x${applied.height.round()}',
      });
    }
    _scheduleSave();
  }

  // ---------- Interruption ----------
  /// Halts playback promptly; completed board content stays exactly as drawn.
  Future<void> interruptPlayback({required bool fromVoice}) async {
    if (!_playing) return;
    _suspended = _queue.suspend(
      speaker.currentChunk.value ?? _currentSpeechChunkForSuspend,
    );
    _suspendedFromVoice = fromVoice;
    _playbackGeneration++;
    _playbackCancelled = true;
    _producerDone = true;
    await speaker.stop();
    try {
      await _aiSub?.cancel();
    } catch (_) {}
    _activeClient?.close();
    state = TurnState.listening;
    notifyListeners();
    // A new playback generation can start (e.g. false-trigger resume).
    _playbackCancelled = false;
  }

  /// Stops the AI completely, discarding any suspended explanation.
  Future<void> stopPlayback() async {
    _suspended = null;
    await interruptPlayback(fromVoice: false);
    _suspended = null;
    state = micMuted ? TurnState.muted : TurnState.listening;
    notifyListeners();
  }

  void _resumeSuspended() {
    final s = _suspended;
    if (s == null) return;
    _suspended = null;
    _queue = PlaybackQueue()..addAll(s.remaining);
    _producerDone = true;
    _playbackCancelled = false;
    _playing = true;
    state = TurnState.speaking;
    notifyListeners();
    unawaited(_consumeQueue(_playbackGeneration));
  }

  /// Called when the student starts drawing (a barge-in signal).
  void onStudentDrawStart() {
    _drewDuringCapture = true;
    board.cameraTakenByStudent = true;
    if (_playing) unawaited(interruptPlayback(fromVoice: false));
  }

  void onManualCamera() {
    board.cameraTakenByStudent = true;
  }

  @override
  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    unawaited(flushSave());
    _frameTimer?.cancel();
    _silenceTimer?.cancel();
    unawaited(_stopMic());
    unawaited(speaker.stop());
    speaker.dispose();
    _activeClient?.close();
    board.dispose();
    super.dispose();
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
