import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../core/data/db.dart';
import '../../core/data/models.dart';
import 'ai/ai_actions.dart';
import 'ai/utils/file_edit.dart';
import 'ai/ai_client.dart';
import 'board/board_models.dart';
import 'playback/playback_engine.dart';
import 'playback/speech_chunker.dart';
import 'playback/tts_service.dart';
import 'playback/wav_builder.dart';
import 'audio_recorder.dart';
import 'speech/sherpa_speech.dart';
import 'board_controller.dart';
import 'turn_video_encoder/pcm_second_buffer.dart';
import 'turn_video_encoder/turn_video_encoder.dart';

enum TurnState { listening, capturing, thinking, speaking, working, muted }

const int _sampleRate = 16000;

/// Coordinates mic/VAD capture, streaming AI playback and autosave for a session.
class SessionController extends ChangeNotifier {
  SessionController({
    required this.db,
    required this.session,
    required this.settings,
    required this.speech,
    required this.vadPath,
  }) {
    speaker = SpeechSpeaker(
      synthesise: speech.synthesise,
      onPlaybackAudio: _feedPlaybackAudio,
    );
  }
  final AppDb db;
  Session session;
  final AppSettings settings;
  final SherpaSpeech speech;
  final String? vadPath;
  final BoardController board = BoardController();
  final GlobalKey captureKey = GlobalKey();
  late final SpeechSpeaker speaker;
  TurnState state = TurnState.listening;
  bool micMuted = false;
  bool captionsOn = true;
  String? errorMessage;
  List<ChatMessage> messages = [];
  String memoryText = '';
  List<SessionObservation> observations = [];
  String sessionObservation = '';

  /// Tool calls queued for playback whose outcome the AI client is
  /// waiting on, keyed by their queued item. Completed by the playback
  /// consumer as soon as the action has actually been performed (or
  /// failed when playback is interrupted before it runs).
  final Map<ActionItem, Completer<AiToolResult>> _pendingToolCalls = {};
  bool _disposed = false;

  /// Uploads staged by the student, sent with their next explicit turn
  /// (never on their own when picked).
  List<AiUpload> _pendingUploads = const [];

  /// Snapshot of the last captured turn whose send failed, kept verbatim
  /// so [retryTurn] can resend it instead of capturing a new turn.
  _CapturedTurn? _failedTurn;

  final AudioRecorder _recorder = AudioRecorder(sampleRate: _sampleRate);
  sherpa.VoiceActivityDetector? _vad;
  final List<double> _vadBuffer = [];
  StreamSubscription<Uint8List>? _micSub;
  bool _micRunning = false;
  bool _hasMicPermission = false;
  DateTime? _speechStart;
  DateTime? _lastVoiceAt;
  bool _capturing = false;
  bool _drewDuringCapture = false;
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

  /// Tool the AI is performing right now (e.g. `write_math`), set by
  /// the playback consumer for exactly the duration of the action so
  /// the status pill can say "Writing math expression…" instead of a
  /// generic state. Null between actions.
  String? activeActionTool;

  /// Whether an AI reply is in flight at all (generating, speaking or
  /// drawing). Drives the Stop button: it must be available from the
  /// moment the turn is sent, not only once speech starts.
  bool get replyActive => _playing;

  /// What the status pill should show, in priority order: the specific
  /// action being performed, then the coarse turn state. `speaking` is
  /// only reported while audio is actually playing (or queued to play);
  /// a reply that is busy with anything else - waiting between steps,
  /// drawing silently, wrapping up - reports `working`, never a
  /// misleading "Speaking…". Waiting on the model is `thinking`, which
  /// is where a turn stays until the first speech or action starts.
  String get statusKey {
    final tool = activeActionTool;
    if (tool != null && _playing) return 'action:$tool';
    return switch (state) {
      TurnState.capturing => 'capturing',
      TurnState.thinking => 'thinking',
      TurnState.speaking => speaker.isSpeaking ? 'speaking' : 'working',
      TurnState.working => 'working',
      TurnState.muted => 'muted',
      TurnState.listening => micMuted ? 'muted' : 'listening',
    };
  }

  Future<void> init() async {
    captionsOn = settings.captionsDefault;
    messages = await db.loadMessages(session.id);
    memoryText = await db.loadMemory();
    observations = await db.loadObservations();
    sessionObservation =
        observations
            .where((o) => o.sessionId == session.id)
            .firstOrNull
            ?.content ??
        '';
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
        _streamVideoFrame(Uint8List.fromList(rgba.buffer.asUint8List()));
      }
    } catch (e) {
      debugPrint('Texa frame capture: $e');
    }
  }

  // ---------- Microphone / VAD ----------
  Future<void> startListening() async {
    if (_micRunning || micMuted || _disposed) return;
    try {
      if (vadPath != null && _vad == null) {
        try {
          _vad = speech.createVad(vadPath!);
        } catch (e) {
          debugPrint('Texa VAD init: $e');
          _vad = null;
        }
      }
      await _recorder.init();
      final stream = _recorder.startStreaming();
      // flutter_recorder has no permission query: reaching here means
      // the OS granted microphone access, while a denial (or a missing
      // device) surfaces as an error from init/start instead.
      _hasMicPermission = true;
      _micRunning = true;
      _micSub = stream.listen(
        _onPcm,
        onError: (Object e) => debugPrint('Texa mic: $e'),
      );
    } catch (e) {
      debugPrint('Texa mic start: $e');
      _hasMicPermission = false;
      _micRunning = false;
    }
    notifyListeners();
  }

  /// Feeds loudspeaker playback to the recorder's software echo
  /// canceller (macOS/Windows/Linux only; a no-op where the platform
  /// voice-communication preset handles AEC). The speaker hands over
  /// complete WAV segments, so strip the header and resample to the
  /// capture rate the canceller expects.
  void _feedPlaybackAudio(Uint8List wav) {
    if (!_recorder.usesSoftwareEchoCancellation) return;
    final pcm = pcm16MonoFromWav(wav, targetSampleRate: _sampleRate);
    if (pcm.isNotEmpty) _recorder.feedPlaybackData(pcm);
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
      if (_playing && !_playbackCancelled) {
        unawaited(interruptPlayback(fromVoice: true));
      }
      if (!_capturing && (state == TurnState.listening || _playing)) {
        _beginCapture(now);
      }
      if (_capturing) {
        _bufferPcm(data);
      }
    } else if (_capturing) {
      _bufferPcm(data);
      if (_lastVoiceAt != null &&
          now.difference(_lastVoiceAt!).inMilliseconds >= vadSilenceMs) {
        unawaited(_finaliseCapture());
      }
    }
  }

  void _beginCapture(DateTime now) {
    if (_capturing) return;
    _capturing = true;
    // The student is speaking again: any error banner (with its retry
    // affordance) from the previous turn is stale, so drop it now
    // rather than leaving it up until the new turn resolves.
    if (errorMessage != null) errorMessage = null;
    _speechStart = now;
    _drewDuringCapture = false;
    _startTurnEncoder();
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
    // False alarm during playback: brief noise resumes the interrupted chunk.
    if (_suspended != null &&
        _suspendedFromVoice &&
        speechMs < sustainedSpeechMs &&
        !_drewDuringCapture) {
      await _discardTurnEncoder();
      _resumeSuspended();
      return;
    }
    if (speechMs < 120 || _pcm.totalReceived == 0) {
      await _discardTurnEncoder();
      state = _playing ? TurnState.working : TurnState.listening;
      notifyListeners();
      return;
    }
    final suspended = _suspended;
    _suspended = null;
    // One last frame of the finished board, then finalize — every
    // earlier frame and audio second was encoded while capturing.
    await _captureFrame();
    final Uint8List mp4Bytes;
    try {
      mp4Bytes = await _finishTurnEncoder();
    } on AppError catch (e) {
      debugPrint(e.cause?.toString());
      // Encode failure: the turn is not sent (Tech Specs 7.4). The board
      // is untouched and the student simply speaks again.
      errorMessage = e.message;
      state = TurnState.listening;
      notifyListeners();
      return;
    }
    await _sendCapturedTurn(
      _CapturedTurn(
        mp4Bytes: mp4Bytes,
        interruption: suspended,
        uploads: _takePendingUploads(),
      ),
    );
  }

  Future<void> setMuted(bool muted) async {
    micMuted = muted;
    if (muted) {
      // Muting only prevents voice input: it must never finalise (and
      // thereby send) the in-progress capture as a turn, and it must not
      // interrupt or otherwise disturb ongoing playback.
      await _stopMic();
      if (_capturing) {
        _capturing = false;
        _frameTimer?.cancel();
        await _discardTurnEncoder();
        if (_suspended != null && _suspendedFromVoice) {
          // The student was only silencing their input; give Texa its
          // interrupted sentence back.
          _resumeSuspended();
        }
      }
      if (!_playing) state = TurnState.muted;
    } else {
      if (!_playing) state = TurnState.listening;
      await startListening();
    }
    notifyListeners();
  }

  Future<void> _stopMic() async {
    try {
      await _micSub?.cancel();
      _micSub = null;
      await _recorder.stopStreaming();
    } catch (_) {}
    _micRunning = false;
  }

  // ---------- Sending a turn (streaming) ----------

  /// Files staged for the student's next explicit turn.
  List<AiUpload> get pendingUploads => List.unmodifiable(_pendingUploads);

  bool get hasPendingUploads => _pendingUploads.isNotEmpty;

  /// Whether [retryTurn] has a failed turn to resend.
  bool get canRetryTurn => _failedTurn != null;

  /// Stages [uploads] to ride along with the student's next explicit
  /// turn. Picking files never sends anything by itself; the staged set
  /// is replaced (the picker always reports the full selection).
  void stageUploads(List<AiUpload> uploads) {
    _pendingUploads = List.of(uploads);
    notifyListeners();
  }

  /// Removes and returns the staged uploads (a turn is being sent).
  List<AiUpload> _takePendingUploads() {
    final uploads = _pendingUploads;
    _pendingUploads = const [];
    return uploads;
  }

  Future<void> addTurn() async {
    if (state == TurnState.thinking) return;
    _startTurnEncoder();
    await _captureFrame();
    final suspended = _suspended;
    _suspended = null;
    final Uint8List mp4Bytes;
    try {
      mp4Bytes = await _finishTurnEncoder();
    } on AppError catch (e) {
      errorMessage = e.message;
      state = TurnState.listening;
      notifyListeners();
      return;
    }
    await _sendCapturedTurn(
      _CapturedTurn(
        mp4Bytes: mp4Bytes,
        interruption: suspended,
        uploads: _takePendingUploads(),
      ),
    );
  }

  /// Resends the previous failed turn exactly as it was captured — same
  /// turn video, uploads and interruption context — without capturing a
  /// new turn or recording the student message a second time.
  Future<void> retryTurn() async {
    final failed = _failedTurn;
    if (failed == null ||
        state == TurnState.thinking ||
        state == TurnState.capturing) {
      return;
    }
    await _sendCapturedTurn(failed, recordStudentMessage: false);
  }

  Future<void> _sendCapturedTurn(
    _CapturedTurn turn, {
    bool recordStudentMessage = true,
  }) async {
    state = TurnState.thinking;
    errorMessage = null;
    if (recordStudentMessage) _failedTurn = null;
    notifyListeners();
    final videoB64 = base64Encode(turn.mp4Bytes);
    if (recordStudentMessage) {
      final studentPayload = <String, dynamic>{
        'hasVideo': true,
        // Kept (base64, like thumbnails) so the history can replay the
        // turn video locally; only the response id is ever resent to
        // the API, never these bytes again.
        'videoBase64': videoB64,
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
    }
    try {
      await _streamReply(
        videoB64: videoB64,
        interruption: turn.interruption,
        uploads: turn.uploads,
      );
      _failedTurn = null;
    } on AppError catch (e) {
      _failedTurn = turn;
      errorMessage = e.message;
      await db.appendLog('turn failed: ${e.message} ${e.cause ?? ''}');
      state = TurnState.listening;
      notifyListeners();
    } catch (e) {
      _failedTurn = turn;
      errorMessage =
          'That turn could not be sent. Your work is safe on the board.';
      await db.appendLog('turn failed: $e');
      state = TurnState.listening;
      notifyListeners();
    }
  }

  // ---------- Streaming turn-video encoding ----------
  //
  // Encoding runs *during* the student's turn: the encoder is set up
  // when capture begins, each 1 FPS board frame is appended as soon as
  // it is captured, and mic PCM is appended a second at a time as it
  // arrives (paired behind the matching video frame, per the native
  // encoder's fixed frame sizes). Ending a turn only pads the final
  // audio second and finalizes, instead of re-encoding buffered raw
  // frames and audio from scratch. All encoder calls are serialized
  // through [_encodeChain] so appends never interleave.
  TurnVideoEncoder? _turnEncoder;
  Future<void> _encodeChain = Future<void>.value();
  Object? _encodeError;
  int _framesAppended = 0;
  int _audioSecondsAppended = 0;
  final PcmSecondBuffer _pcm = PcmSecondBuffer(secondBytes: _sampleRate * 2);

  void _startTurnEncoder() {
    _turnEncoder = createTurnVideoEncoder();
    _encodeError = null;
    _framesAppended = 0;
    _audioSecondsAppended = 0;
    _pcm.clear();
    final encoder = _turnEncoder!;
    _enqueueEncode(
      () => encoder.setup(
        width: frameWidth,
        height: frameHeight,
        fps: 1,
        videoBitrate: 500000,
        audioChannels: 1,
        // 16 kHz mono AAC tops out at 48 kbps (valid range
        // 12-48 kbps); asking for more makes AVAssetWriter fail
        // mid-stream with "Cannot Encode Media" (-11861), typically
        // surfacing on a later append. 32 kbps is ample for speech.
        audioBitrate: 32000,
        sampleRate: _sampleRate,
      ),
    );
  }

  void _enqueueEncode(Future<void> Function() op) {
    _encodeChain = _encodeChain.then((_) async {
      try {
        await op();
      } catch (e) {
        _encodeError ??= e;
      }
    });
  }

  /// Encodes [rgba] right away (called on every captured frame).
  void _streamVideoFrame(Uint8List rgba) {
    final encoder = _turnEncoder;
    if (encoder == null) return;
    _enqueueEncode(() async {
      if (!identical(encoder, _turnEncoder)) return;
      await encoder.appendVideoFrame(rgba);
      _framesAppended++;
      await _drainAudioSeconds();
    });
  }

  void _bufferPcm(Uint8List data) {
    _pcm.add(data);
    _enqueueEncode(_drainAudioSeconds);
  }

  /// Appends every complete buffered audio second that already has a
  /// video frame ahead of it, keeping the interleaved V/A/V/A order
  /// the encoders expect.
  Future<void> _drainAudioSeconds() async {
    final encoder = _turnEncoder;
    if (encoder == null) return;
    while (_audioSecondsAppended < _framesAppended && _pcm.hasFullSecond) {
      await encoder.appendAudioFrame(_pcm.takeSecond());
      _audioSecondsAppended++;
    }
  }

  /// Finalizes the streaming encoder and returns the turn's MP4 bytes.
  Future<Uint8List> _finishTurnEncoder() async {
    final encoder = _turnEncoder;
    if (encoder == null) {
      throw const AppError(
        'I could not capture the board just now. Please try again.',
      );
    }
    Uint8List? bytes;
    _enqueueEncode(() async {
      // Pad any video frames whose audio second never arrived with a
      // final (possibly partial, silence-padded) audio second.
      while (_audioSecondsAppended < _framesAppended) {
        await encoder.appendAudioFrame(_pcm.takeSecond());
        _audioSecondsAppended++;
      }
      bytes = await encoder.finish();
    });
    await _encodeChain;
    _turnEncoder = null;
    final error = _encodeError;
    _encodeError = null;
    if (error != null) {
      throw AppError(
        'I could not prepare that turn to send. Your work is safe on the board — please try again.',
        cause: error,
      );
    }
    if (bytes == null || _framesAppended == 0) {
      throw const AppError(
        'I could not capture the board just now. Please try again.',
      );
    }
    return bytes!;
  }

  /// Abandons the in-progress encode (discarded/false-alarm captures).
  Future<void> _discardTurnEncoder() async {
    final encoder = _turnEncoder;
    _turnEncoder = null;
    if (encoder == null) return;
    _enqueueEncode(() => encoder.abort());
    await _encodeChain;
    _encodeError = null;
    _framesAppended = 0;
    _audioSecondsAppended = 0;
    _pcm.clear();
  }

  Future<void> _streamReply({
    required String videoB64,
    SuspendedPlayback? interruption,
    List<AiUpload> uploads = const [],
    String? extraContext,
  }) async {
    final client = AiClient(settings.apiKey);
    _activeClient = client;
    _queue = PlaybackQueue();
    _producerDone = false;
    _playbackCancelled = false;
    _playing = true;
    // Thinking, not speaking: no speech (and possibly no reply at all)
    // exists yet. The consumer promotes this to speaking / the specific
    // action as it actually performs each queued item.
    state = TurnState.thinking;
    notifyListeners();
    final generation = _playbackGeneration;
    final consumer = _consumeQueue(generation);

    // Performs one tool call the model asked for and reports the outcome
    // back to it. Board/notebook actions go through the playback queue
    // (so speech and drawing stay in the order the model issued them)
    // and the future only completes when the consumer has actually
    // performed the action; the AI client then sends that result to the
    // model before asking it for the next step.
    Future<AiToolResult> executeToolCall(
      String name,
      Map<String, dynamic> args,
    ) async {
      if (generation != _playbackGeneration || _playbackCancelled) {
        return const AiToolResult.failure(
          'Playback was interrupted before this action ran.',
        );
      }
      if (name == 'search_session_observations') {
        return AiToolResult.success(_observationSearchText(args));
      }
      if (name == 'resume_explanation') {
        _queue.add(ResumeItem());
        return const AiToolResult.success(
          'The suspended explanation will resume.',
        );
      }
      final item = ActionItem(name, args);
      final completer = Completer<AiToolResult>();
      _pendingToolCalls[item] = completer;
      _queue.add(item);
      final result = await completer.future;
      // The result is on its way back to the model: until it replies
      // with speech or the next action, we are waiting on it again.
      if (generation == _playbackGeneration &&
          !_playbackCancelled &&
          activeActionTool == null) {
        state = TurnState.thinking;
        notifyListeners();
      }
      return result;
    }

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
        videoBase64: videoB64,
        interruptionContext: interruption?.toContext(),
        studentMemory: memoryText,
        recentObservations: observations.take(3).toList(),
        currentObservation: sessionObservation,
        uploads: uploads,
        extraContext: extraContext,
        reasoningEffort: session.reasoningEffort,
        executeToolCall: executeToolCall,
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
          toolCallsRaw.add({
            if (event.callId.isNotEmpty) 'id': event.callId,
            'name': event.name,
            'args': event.args,
          });
          for (final h in held) {
            _queue.add(TextItem(h));
          }
          held.clear();
          textReleased = true;
          for (final s in splitter.flush()) {
            _queue.add(TextItem(s));
          }
          // Performing the call (and reporting its outcome to the model)
          // is executeToolCall's job, above; here we only keep the
          // surrounding text flowing to playback in order.
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
          state = TurnState.speaking;
          notifyListeners();
          _currentSpeechChunkForSuspend =
              splitSpeech(item.text).firstOrNull ?? item.text;
          speaker.enqueueText(item.text);
          await speaker.drained;
          _queue.completed.add({'tool': 'text', 'rect': ''});
        } else if (item is ActionItem) {
          activeActionTool = item.tool;
          notifyListeners();
          AiToolResult result;
          try {
            result = await _executeAction(item);
          } catch (e) {
            result = AiToolResult.failure('The action failed: $e');
          }
          activeActionTool = null;
          notifyListeners();
          _pendingToolCalls.remove(item)?.complete(result);
        }
        if (_disposed) break;
      }
    } finally {
      _failPendingToolCalls('Playback stopped before this action ran.');
      if (activeActionTool != null) activeActionTool = null;
      _playing = false;
      if (!_disposed &&
          generation == _playbackGeneration &&
          !_capturing &&
          !_playbackCancelled) {
        state = micMuted ? TurnState.muted : TurnState.listening;
        notifyListeners();
      }
      final c = _playbackIdle;
      _playbackIdle = null;
      if (c != null && !c.isCompleted) c.complete();
    }
  }

  void _failPendingToolCalls(String reason) {
    if (_pendingToolCalls.isEmpty) return;
    final pending = _pendingToolCalls.values.toList();
    _pendingToolCalls.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.complete(AiToolResult.failure(reason));
      }
    }
  }

  String _observationSearchText(Map<String, dynamic> args) {
    DateTime? parseDate(String? v) => v == null ? null : DateTime.tryParse(v);
    final results = db.searchObservations(
      observations,
      query: args['query'] as String?,
      from: parseDate(args['from'] as String?),
      to: parseDate(args['to'] as String?),
    );
    return results.isEmpty
        ? 'Your search of past session observations found nothing. Continue the student\'s turn without that history.'
        : 'Results of your search of past session observations: ${results.map((o) => '[${o.date.toIso8601String().substring(0, 10)}] ${o.content}').join(' ')} Use these to continue answering the student\'s last turn; do not redraw steps already on the board.';
  }

  String _applyNotebookEdits(String current, Object? rawEdits) {
    final edits = <Edit>[];
    if (rawEdits is List) {
      for (final e in rawEdits) {
        if (e is Map) {
          edits.add(
            Edit(
              oldText: (e['old_text'] ?? e['oldText'] ?? '') as String,
              newText: (e['new_text'] ?? e['newText'] ?? '') as String,
            ),
          );
        }
      }
    }
    return applyNotebookEdits(current, edits);
  }

  /// Performs one board/notebook action and reports whether it actually
  /// happened, so the outcome can be sent back to the model as the tool
  /// result (instead of the model assuming every call succeeded).
  Future<AiToolResult> _executeAction(ActionItem item) async {
    if (item.tool == 'update_session_observation' ||
        item.tool == 'update_memory') {
      AiToolResult result;
      try {
        if (item.tool == 'update_session_observation') {
          sessionObservation = clampToTwoParagraphs(
            _applyNotebookEdits(sessionObservation, item.args['edits']),
          );
          await db.saveObservation(session.id, sessionObservation);
          observations = await db.loadObservations();
        } else {
          memoryText = _applyNotebookEdits(memoryText, item.args['edits']);
          await db.saveMemory(memoryText);
        }
        result = const AiToolResult.success('Notebook updated.');
      } catch (e) {
        await db.appendLog('notebook update skipped: $e');
        result = AiToolResult.failure('The notebook update failed: $e');
      }
      final speech = item.speech;
      if (speech != null && speech.isNotEmpty) {
        speaker.enqueueText(speech);
        await speaker.drained;
      }
      return result;
    }
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
    return applied != null
        ? AiToolResult.success(
            '${item.tool} performed on the board at '
            '${applied.left.round()},${applied.top.round()} '
            '(${applied.width.round()}x${applied.height.round()}).',
          )
        : AiToolResult.failure(
            '${item.tool} could not be performed: check the element_id, '
            'the arguments, and that the target element exists.',
          );
  }

  // ---------- Interruption ----------
  /// Halts playback promptly; completed board content stays exactly as drawn.
  Future<void> interruptPlayback({required bool fromVoice}) async {
    if (!_playing) return;
    _failPendingToolCalls('Playback was interrupted before this action ran.');
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
    activeActionTool = null;
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
    state = TurnState.working;
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
    _recorder.dispose();
    unawaited(_turnEncoder?.abort() ?? Future<void>.value());
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

/// One captured student turn, kept whole so a failed send can be retried
/// verbatim (same video bytes, uploads and interruption context).
class _CapturedTurn {
  const _CapturedTurn({
    required this.mp4Bytes,
    this.interruption,
    this.uploads = const [],
  });

  final Uint8List mp4Bytes;
  final SuspendedPlayback? interruption;
  final List<AiUpload> uploads;
}
