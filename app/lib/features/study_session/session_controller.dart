import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:record/record.dart';

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
import 'speech/speech_engine.dart';
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
    this.smartTurnPath,
  }) : speaker = SpeechSpeaker(synthesise: speech.synthesise);
  final AppDb db;
  Session session;
  AppSettings settings;
  final SpeechEngine speech;
  final String? vadPath;
  final String? smartTurnPath;
  final BoardController board = BoardController();
  final GlobalKey captureKey = GlobalKey();
  final SpeechSpeaker speaker;
  TurnState state = TurnState.listening;
  bool micMuted = false;
  bool captionsOn = true;
  String? errorMessage;

  /// Auto-dismissal for a transient [errorMessage] (one shown without a
  /// retry affordance - see [_showError]).
  Timer? _errorTimer;

  /// Whether the in-flight turn has already received any part of the
  /// AI's response (text or a tool call). Reset at the start of every
  /// turn in [_streamReply]; read by [_sendCapturedTurn] when a turn
  /// fails, because retrying a turn the AI already started answering
  /// would make it repeat (and re-draw) what it already produced.
  bool _turnResponseReceived = false;

  /// Whether anything from the in-flight reply has actually surfaced
  /// to the student (speech started or a board action started). Unlike
  /// [_turnResponseReceived] (first streamed delta), this only flips in
  /// the playback consumer, so it stays false while the model is still
  /// thinking - the phase where an interruption can simply cancel the
  /// request instead of suspending a partial explanation.
  bool _turnOutputSurfaced = false;

  /// The turn currently being sent/streamed, kept so a thinking-phase
  /// interruption can supersede it (see [_supersededTurn]).
  _CapturedTurn? _activeTurn;

  /// A turn cancelled while the model was still thinking (nothing said
  /// or drawn yet). It was never answered, so instead of being dropped
  /// or resumed, its input is concatenated into the next fresh turn:
  /// the model receives the earlier turn video(s) before the new one
  /// and answers them together. Cleared when merged, when Stop is
  /// pressed, or when the interrupting capture turns out to be a
  /// false alarm (in which case the turn is resent as-is).
  _CapturedTurn? _supersededTurn;
  List<ChatMessage> messages = [];
  String memoryText = '';
  List<SessionObservation> observations = [];
  String sessionObservation = '';

  /// Background turn-video transcriptions, by student message id.
  /// Each job runs on its own [AiClient], so interrupting or closing
  /// the active tutor turn never cancels one, and vice versa.
  final Map<String, Future<bool>> _transcriptionJobs = {};
  bool _transcriptionSweepRunning = false;

  /// Serializes whole-history saves. A background transcription and
  /// the tutor turn can both finish (and persist) at the same time;
  /// chaining the saves - each over a snapshot - keeps their upserts
  /// from interleaving over the live, still-growing [messages] list.
  Future<void> _messageSaveChain = Future<void>.value();

  /// Serializes board saves for the same reason: a debounced autosave
  /// and the final flush on close can race, and an older capture
  /// finishing last would leave a stale board (and preview) behind.
  /// Each chained save snapshots the board when it runs, so the last
  /// save queued always persists the board as it is at that moment.
  Future<void> _boardSaveChain = Future<void>.value();

  Future<void> _saveMessages() {
    final snapshot = List<ChatMessage>.of(messages);
    final save = _messageSaveChain.then(
      (_) => db.saveMessages(session.id, snapshot),
    );
    _messageSaveChain = save.then((_) {}, onError: (_, _) {});
    return save;
  }

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

  final AudioRecorder _recorder = AudioRecorder();
  SpeechVad? _vad;
  final List<double> _vadBuffer = [];

  /// Rolling buffer of the most recent mic audio, kept whether or not a
  /// turn is being captured. Capture only starts once the VAD fires, so
  /// without this the onset of speech (up to a whole short word) is lost
  /// from the recording; on capture start the buffer is prepended so the
  /// voice is heard in full with a little leading silence.
  static const int _preRollMs = 600;
  static const int _tailHangoverMs = 200;
  final List<Uint8List> _preRoll = [];
  int _preRollBytes = 0;

  /// When the last board frame was sent to the turn encoder. Used at
  /// finalise time to decide whether a closing board frame is needed
  /// (see the frame-count logic in [_finaliseCapture]).
  DateTime? _lastFrameAt;

  void _pushPreRoll(Uint8List data) {
    _preRoll.add(data);
    _preRollBytes += data.length;
    final maxBytes = _sampleRate * 2 * _preRollMs ~/ 1000;
    while (_preRollBytes > maxBytes && _preRoll.isNotEmpty) {
      final excess = _preRollBytes - maxBytes;
      final first = _preRoll.first;
      if (first.length <= excess) {
        _preRoll.removeAt(0);
        _preRollBytes -= first.length;
      } else {
        _preRoll[0] = Uint8List.sublistView(first, excess);
        _preRollBytes -= excess;
      }
    }
  }

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
  bool get replyActive => _playing || _activeTurn != null;

  /// A turn is in flight from the moment it is sent - before (and
  /// regardless of whether) any of its reply has streamed. The status
  /// already reads "thinking" in this window, so interruption must
  /// work then too, not only once playback/streaming has begun.
  bool get _turnInFlight => _playing || _activeTurn != null;

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
    _scheduleResumeTranscriptions();
    if (!settings.micPermissionDenied) await startListening();
  }

  // ---------- Turn-video transcription ----------
  //
  // Only the newest [maxVideoTurnsPerRequest] student turns can be
  // sent to Meta AI as video; older turns go as transcripts (see
  // AiClient). Transcription is transcribe-ahead: the oldest retained
  // video is transcribed in the background while its turn is still
  // being answered, so the transcript is already persisted when the
  // next turn pushes that video out of the window.

  /// Replaces the payload of the message with [id], keeping its
  /// identity, role, kind and timestamp. Returns false when the
  /// message is no longer in the history.
  bool _updateMessagePayload(String id, Map<String, dynamic> updates) {
    final index = messages.indexWhere((m) => m.id == id);
    if (index < 0) return false;
    final old = messages[index];
    messages[index] = ChatMessage(
      id: old.id,
      sessionId: old.sessionId,
      role: old.role,
      kind: old.kind,
      payloadJson: jsonEncode({...old.payload, ...updates}),
      createdAt: old.createdAt,
    );
    return true;
  }

  /// Ensures [message]'s video has a persisted transcript, joining an
  /// in-flight job for the same message when there is one. Resolves
  /// true when a transcript is stored; false on failure (the message
  /// is marked `failed` and a later call retries). Never throws:
  /// transcription must not break the tutoring turn it supports.
  Future<bool> _ensureTranscription(ChatMessage message) {
    if (AiClient.transcriptOf(message) != null) return Future.value(true);
    final inFlight = _transcriptionJobs[message.id];
    if (inFlight != null) return inFlight;
    late final Future<bool> job;
    job = _runTranscription(message.id).whenComplete(() {
      if (identical(_transcriptionJobs[message.id], job)) {
        _transcriptionJobs.remove(message.id);
      }
    });
    _transcriptionJobs[message.id] = job;
    return job;
  }

  Future<bool> _runTranscription(String messageId) async {
    final index = messages.indexWhere((m) => m.id == messageId);
    if (index < 0) return false;
    final videoBase64 = messages[index].payload['videoBase64'] as String?;
    if (videoBase64 == null || videoBase64.isEmpty) return false;
    // Mark pending *before* the request, so an app kill mid-flight is
    // distinguishable on resume and re-driven by
    // [_scheduleResumeTranscriptions] / [_prepareTranscriptions].
    _updateMessagePayload(messageId, {
      'transcriptionStatus': 'pending',
      'transcriptionError': null,
    });
    await _saveMessages();
    final client = AiClient(settings.apiKey);
    try {
      final transcript = await client.transcribeVideo(
        model: session.model,
        videoBase64: videoBase64,
      );
      if (_disposed) return false;
      _updateMessagePayload(messageId, {
        'transcript': transcript,
        'transcriptionStatus': 'done',
        'transcriptionError': null,
        'transcribedAt': DateTime.now().toIso8601String(),
      });
      await _saveMessages();
      notifyListeners();
      return true;
    } catch (e) {
      if (_disposed) return false;
      final detail = e.toString();
      _updateMessagePayload(messageId, {
        'transcriptionStatus': 'failed',
        'transcriptionError': detail.length > 200
            ? detail.substring(0, 200)
            : detail,
      });
      await _saveMessages();
      await db.appendLog('turn-video transcription failed: $detail');
      return false;
    } finally {
      client.close();
    }
  }

  /// On resume, (re)transcribes - oldest first, one at a time so a
  /// long legacy session does not flood the API - every video turn
  /// that the next request could no longer send as video: all but the
  /// newest few, which covers both already-aged-out turns and the
  /// oldest retained video that will age out on the next turn.
  void _scheduleResumeTranscriptions() {
    if (_transcriptionSweepRunning || _disposed) return;
    final videos = AiClient.studentVideoTurns(messages);
    if (videos.length <= maxVideoTurnsPerRequest - 1) return;
    final candidates = videos.sublist(
      0,
      videos.length - (maxVideoTurnsPerRequest - 1),
    );
    _transcriptionSweepRunning = true;
    unawaited(() async {
      try {
        for (final message in candidates) {
          if (_disposed) return;
          await _ensureTranscription(message);
        }
      } finally {
        _transcriptionSweepRunning = false;
      }
    }());
  }

  /// Prepares transcripts for the turn about to be sent. Turns that
  /// this request will already send as transcripts are awaited (in
  /// steady state their transcribe-ahead job is done or in flight, so
  /// this rarely waits); the oldest video this request still sends as
  /// video is kicked off in the background, in parallel with the
  /// tutor's reply, ready for the next turn. A failed preparation
  /// never blocks the turn: AiClient degrades that one history item
  /// to an explicit marker and the failure is retried next turn.
  Future<void> _prepareTranscriptions() async {
    final videos = AiClient.studentVideoTurns(messages);
    if (videos.isEmpty) return;
    final retainedStart = videos.length > maxVideoTurnsPerRequest
        ? videos.length - maxVideoTurnsPerRequest
        : 0;
    for (final message in videos.sublist(0, retainedStart)) {
      await _ensureTranscription(message);
      if (_disposed) return;
    }
    if (videos.length >= maxVideoTurnsPerRequest) {
      unawaited(_ensureTranscription(videos[retainedStart]));
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 450), _saveNow);
  }

  Future<void> _saveNow() {
    final save = _boardSaveChain.then((_) async {
      await db.saveBoard(session.id, board.snapshot(null).encode());
      final all = await db.loadSessions();
      final i = all.indexWhere((e) => e.id == session.id);
      if (i >= 0) {
        all[i] = all[i].copyWith(updatedAt: DateTime.now());
        await db.saveSessions(all);
      }
    });
    _boardSaveChain = save.then((_) {}, onError: (_, _) {});
    return save;
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
        _lastFrameAt = DateTime.now();
        _streamVideoFrame(Uint8List.fromList(rgba.buffer.asUint8List()));
      }
    } catch (e) {
      debugPrint('Texa frame capture: $e');
    }
  }

  // ---------- Microphone / VAD ----------
  /// Whether the platform recorder supports voice processing (echo
  /// cancellation, noise suppression, automatic gain).
  ///
  /// iOS/Android route capture through the voice-communication stack, so
  /// voice processing works there. On macOS `record` instead flips the
  /// `AVAudioEngine` input node into voice-processing mode, which is a
  /// duplex (input + output) unit: the recorder's engine is input-only,
  /// the input format changes under its converter, conversion fails and
  /// the plugin silently stops the stream - no audio is ever delivered.
  /// There is no `AVAudioSession` on macOS either (the `audio_session`
  /// plugin's macOS side only stores the configuration), so the setup in
  /// `main.dart` cannot rescue this; it still matters on iOS/Android.
  /// Even a patched recorder could not cancel the tutor's voice on macOS:
  /// the voice-processing unit only cancels audio rendered through its
  /// own engine, not `just_audio`'s separate player. That is why the
  /// session screen warns Mac students to use headphones (otherwise Texa
  /// hears itself and loops) while voice barge-in stays enabled.
  bool get _voiceProcessingSupported =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

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
          _vad = await speech.createVad(
            vadPath!,
            smartTurnPath: smartTurnPath ?? '',
          );
        } catch (e) {
          debugPrint('Texa VAD init: $e');
          _vad = null;
        }
      }
      final stream = await _recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _sampleRate,
          numChannels: 1,
          echoCancel: _voiceProcessingSupported,
          noiseSuppress: _voiceProcessingSupported,
          autoGain: _voiceProcessingSupported,
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

  /// Permanently dismisses the macOS headphones notice (the student
  /// ticked "Don't show again" on it) and persists the choice.
  Future<void> dismissMacHeadphonesNotice() async {
    if (settings.macHeadphonesNoticeDismissed) return;
    settings = settings.copyWith(macHeadphonesNoticeDismissed: true);
    await db.saveSettings(settings);
  }

  /// Serialises VAD processing: web VAD runs in a worker, so detection
  /// is async; chaining keeps windows (and capture decisions) in order.
  Future<void> _vadChain = Future<void>.value();

  /// Captured turn audio (last 8s) for the Smart Turn judgement.
  final List<double> _turnSamples = [];
  int _smartTurnChecks = 0;

  void _onPcm(Uint8List data) {
    if (data.length < 2 || _vad == null) return;
    final copy = Uint8List.fromList(data);
    _vadChain = _vadChain.then((_) => _processPcm(copy));
  }

  Future<void> _processPcm(Uint8List data) async {
    // Silero VAD is the single voice detector on every platform: PCM16
    // is converted once to float samples and fed in window-sized chunks;
    // the same bytes are buffered for the turn video.
    final count = data.length ~/ 2;
    final vad = _vad;
    if (vad == null || _disposed) return;
    // Every chunk feeds the pre-roll, capturing or not: it must already
    // hold the student's first word on the chunk where the VAD fires.
    _pushPreRoll(data);
    final view = ByteData.sublistView(data);
    var voice = false;
    try {
      for (var i = 0; i < count; i++) {
        _vadBuffer.add(view.getInt16(i * 2, Endian.little) / 32768.0);
      }
      while (_vadBuffer.length >= 512) {
        final window = Float32List.fromList(_vadBuffer.sublist(0, 512));
        _vadBuffer.removeRange(0, 512);
        if (await vad.process(window)) voice = true;
        if (_disposed) return;
      }
    } catch (e) {
      debugPrint('Texa VAD: $e');
      return;
    }
    final now = DateTime.now();
    if (voice) {
      _smartTurnChecks = 0;
      _lastVoiceAt = now;
      if (_turnInFlight && !_playbackCancelled) {
        unawaited(interruptPlayback(fromVoice: true));
      }
      if (!_capturing && (state == TurnState.listening || _playing)) {
        _beginCapture(now, current: data);
      }
      if (_capturing) _appendTurnSamples(data);
    } else if (_capturing) {
      _appendTurnSamples(data);
      if (_lastVoiceAt != null &&
          now.difference(_lastVoiceAt!).inMilliseconds >= vadSilenceMs) {
        await _finaliseCapture();
      }
    }
    if (_capturing) _bufferPcm(data);
  }

  void _appendTurnSamples(Uint8List data) {
    final view = ByteData.sublistView(data);
    for (var i = 0; i < data.length ~/ 2; i++) {
      _turnSamples.add(view.getInt16(i * 2, Endian.little) / 32768.0);
    }
    const maxSamples = 8 * _sampleRate;
    if (_turnSamples.length > maxSamples) {
      _turnSamples.removeRange(0, _turnSamples.length - maxSamples);
    }
  }

  void _beginCapture(DateTime now, {Uint8List? current}) {
    if (_capturing) return;
    _capturing = true;
    _turnSamples.clear();
    // The chunk that triggered detection is excluded from the pre-roll
    // seeding: the live path below appends it as usual, so including it
    // here too would duplicate it in the recording.
    for (final chunk in _preRoll) {
      if (identical(chunk, current)) continue;
      _appendTurnSamples(chunk);
    }
    _smartTurnChecks = 0;
    // The student is speaking again: any error banner (with its retry
    // affordance) from the previous turn is stale, so drop it now
    // rather than leaving it up until the new turn resolves.
    _clearError();
    _speechStart = now;
    _drewDuringCapture = false;
    _startTurnEncoder();
    // Prepend the pre-roll so the recording starts just before the
    // student's first word instead of at the VAD's detection point.
    for (final chunk in _preRoll) {
      if (identical(chunk, current)) continue;
      _bufferPcm(chunk);
    }
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
      // False alarm: the "interruption" was just noise, but it already
      // cancelled a thinking turn. Resend that turn as-is (it was
      // never answered and nothing replaced it).
      final superseded = _supersededTurn;
      if (superseded != null) {
        _supersededTurn = null;
        state = TurnState.listening;
        notifyListeners();
        await _sendCapturedTurn(superseded, recordStudentMessage: false);
        return;
      }
      state = _playing ? TurnState.working : TurnState.listening;
      notifyListeners();
      return;
    }
    // Smart Turn: an apparently finished pause may be mid-thought.
    // Re-check a few times (bounded, ~2s) before ending the turn.
    // Native SherpaVad always returns true here (smart turn is backed into the vad for native).
    if (_vad != null && _smartTurnChecks < 4) {
      bool complete;
      try {
        complete = await _vad!.turnComplete(Float32List.fromList(_turnSamples));
      } catch (_) {
        complete = true;
      }
      if (!complete) {
        _smartTurnChecks++;
        _capturing = true;
        _lastVoiceAt = DateTime.now();
        return;
      }
    }
    final suspended = _suspended;
    _suspended = null;
    // The video is 1 FPS, so its length is a whole number of seconds
    // and the audio is padded/truncated to match. Cover exactly the
    // audio we want to keep (pre-roll + speech + a short hangover) and
    // no more: an unconditional final frame here used to force a whole
    // extra second of trailing silence onto every recording. If the
    // student drew during the turn and the periodic cadence has been
    // quiet for a while, one closing board frame is still taken (at the
    // cost of that second) so the finished board state is not lost.
    final desiredSeconds = ((_preRollMs + speechMs + _tailHangoverMs) / 1000)
        .ceil();
    var guard = 0;
    while (_framesAppended < desiredSeconds && guard++ < 3) {
      final before = _framesAppended;
      await _captureFrame();
      await _encodeChain;
      if (_framesAppended == before) break;
    }
    // Closing board frame: only when drawing may have changed the
    // board since the last periodic frame (see note above).
    if (_framesAppended >= desiredSeconds &&
        _drewDuringCapture &&
        (_lastFrameAt == null ||
            DateTime.now().difference(_lastFrameAt!).inMilliseconds >= 900)) {
      await _captureFrame();
      await _encodeChain;
    }
    final Uint8List mp4Bytes;
    try {
      mp4Bytes = await _finishTurnEncoder();
    } on AppError catch (e) {
      debugPrint(e.cause?.toString());
      // Encode failure: the turn is not sent (Tech Specs 7.4). The board
      // is untouched and the student simply speaks again.
      _showError(e.message, transient: true);
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
      await _recorder.stop();
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
      _showError(e.message, transient: true);
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

  /// Shows [message] in the error banner. A persistent error stays
  /// until the next turn starts; a transient one dismisses itself
  /// after a few seconds. Callers pair a persistent error with a
  /// [_failedTurn] snapshot (the banner's Retry button only renders
  /// while [canRetryTurn]); a transient error must have none, so the
  /// student is never offered - or able to trigger - a resend.
  void _showError(String message, {bool transient = false}) {
    _errorTimer?.cancel();
    _errorTimer = null;
    errorMessage = message;
    if (transient) {
      _errorTimer = Timer(const Duration(seconds: 8), () {
        if (_disposed) return;
        errorMessage = null;
        notifyListeners();
      });
    }
  }

  /// Drops the current error banner and any pending auto-dismissal.
  void _clearError() {
    _errorTimer?.cancel();
    _errorTimer = null;
    errorMessage = null;
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
    // A fresh turn after a thinking-phase interruption absorbs the
    // superseded turn: its videos/uploads ride along before this
    // turn's own, so the model answers the concatenated input at once.
    // (A retry is not fresh: it resends its snapshot verbatim.)
    final superseded = _supersededTurn;
    if (superseded != null && recordStudentMessage) {
      _supersededTurn = null;
      turn = _CapturedTurn(
        mp4Bytes: turn.mp4Bytes,
        interruption: turn.interruption,
        uploads: [...superseded.uploads, ...turn.uploads],
        priorMp4Bytes: [...superseded.priorMp4Bytes, superseded.mp4Bytes],
      );
    }
    _activeTurn = turn;
    state = TurnState.thinking;
    _clearError();
    // From here on, any failure of this send is judged against what
    // this turn (not an earlier one) received - reset before anything
    // that can throw, not just when streaming starts.
    _turnResponseReceived = false;
    _turnOutputSurfaced = false;
    if (recordStudentMessage) _failedTurn = null;
    notifyListeners();
    final videoB64 = base64Encode(turn.mp4Bytes);
    if (recordStudentMessage) {
      final studentPayload = <String, dynamic>{
        'hasVideo': true,
        // Attachments sent with this turn, kept so the attachments
        // modal and the history sheet can show what the student sent
        // after the staged selection itself has been cleared.
        if (turn.uploads.isNotEmpty)
          'uploads': [for (final upload in turn.uploads) upload.toJson()],
        // Kept (base64, like thumbnails) so the history can replay the
        // turn video locally. On the wire the newest few are resent as
        // video when history is replayed; older ones are replaced by
        // their persisted transcript (see _prepareTranscriptions).
        'videoBase64': videoB64,
        'transcriptionStatus': 'none',
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
      await _saveMessages();
    }
    if (identical(_supersededTurn, turn)) return;
    try {
      await _prepareTranscriptions();
      if (_disposed) return;
      await _streamReply(
        videoB64: videoB64,
        interruption: turn.interruption,
        uploads: turn.uploads,
        priorVideosBase64: turn.priorMp4Bytes.map(base64Encode).toList(),
      );
      _failedTurn = null;
    } on AppError catch (e) {
      await db.appendLog('turn failed: ${e.message} ${e.cause ?? ''}');
      _reportTurnFailure(turn, e.message);
      state = TurnState.listening;
      notifyListeners();
    } catch (e) {
      await db.appendLog('turn failed: $e');
      _reportTurnFailure(
        turn,
        'That turn could not be sent. Your work is safe on the board.',
      );
      state = TurnState.listening;
      notifyListeners();
    } finally {
      if (identical(_activeTurn, turn)) _activeTurn = null;
    }
  }

  /// Decides how a failed turn is surfaced. If the AI never produced
  /// anything, the captured turn is kept so the banner can offer a
  /// verbatim retry. If a response had already started - even
  /// partially: some speech heard, a tool call performed - retrying
  /// would resend the student's turn from scratch and make the AI
  /// repeat (and re-draw) what it already did, so no retry snapshot is
  /// kept and only a temporary, button-less message is shown. The
  /// partial output itself is untouched: board actions already
  /// performed stay performed.
  void _reportTurnFailure(_CapturedTurn turn, String message) {
    if (_turnResponseReceived) {
      _failedTurn = null;
      _showError(
        'That reply stopped partway, so it cannot be retried without '
        'the AI repeating itself. What it already said and drew is '
        'still here - just carry on when you are ready.',
        transient: true,
      );
    } else {
      _failedTurn = turn;
      _showError(message);
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

  /// True while everything streamed so far could still turn out to be
  /// (only) a control sentinel - <[IGNORE_TURN]> - so
  /// none of it may reach the speech splitter yet. Covers the whole
  /// sentinel, a prefix of it (split across deltas), and real text
  /// ending in a partial sentinel fragment, which must be held back
  /// until the next delta shows whether it completes the sentinel.
  bool _isSentinelOnlySoFar(String raw) {
    final trimmed = raw.trim();
    for (final sentinel in [ignoreTurnSentinel, turnDoneSentinel]) {
      if (raw.contains(sentinel)) return true;
      if (sentinel.startsWith(trimmed)) return true;
    }
    // Ends with a partial sentinel start (e.g. "Done. <[TURN"): hold.
    for (final sentinel in [ignoreTurnSentinel, turnDoneSentinel]) {
      for (var i = 1; i < sentinel.length; i++) {
        if (raw.endsWith(sentinel.substring(0, i))) return true;
      }
    }
    return false;
  }

  Future<void> _streamReply({
    required String videoB64,
    SuspendedPlayback? interruption,
    List<AiUpload> uploads = const [],
    String? extraContext,
    List<String> priorVideosBase64 = const [],
  }) async {
    // A fresh AiClient per turn is deliberate: it snapshots the current
    // API key and, via _activeClient, gives interrupt/dispose a handle
    // whose close() aborts exactly this turn's in-flight request. It is
    // not a fresh transport per request - AiClient reuses its underlying
    // HTTP client for every tool round of the turn (see its
    // _NonClosingClient), which the function_call_output follow-ups need.
    final client = AiClient(settings.apiKey);
    _activeClient = client;
    _queue = PlaybackQueue();
    _producerDone = false;
    _playbackCancelled = false;
    _playing = true;
    // A new reply reclaims the camera: cameraTakenByStudent is only
    // meant to stop the AI fighting the student *within* a reply (it
    // is set again by any manual pan/zoom/draw while this reply plays).
    // Left sticky, the first manual camera move of the session would
    // silently disable framing for every later reply.
    board.cameraTakenByStudent = false;
    // Nothing of this turn's reply has arrived yet; the first text or
    // tool call flips this, and _sendCapturedTurn uses it to decide
    // whether a failure may offer a retry (see _reportTurnFailure).
    _turnResponseReceived = false;
    _turnOutputSurfaced = false;
    // Thinking, not speaking: no speech (and possibly no reply at all)
    // exists yet. The consumer promotes this to speaking / the specific
    // action as it actually performs each queued item.
    state = TurnState.thinking;
    notifyListeners();
    final generation = _playbackGeneration;
    final consumer = _consumeQueue(generation);

    // Performs one tool call the model asked for. Board/notebook
    // actions go through the playback queue (so speech and drawing
    // stay in the order the model issued them) and the future only
    // completes when the consumer has actually performed the action;
    // the AI client persists that outcome with the turn and only
    // sends it back to the model when a call failed.
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
    var sentinelHeldBack = false;
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
        priorVideosBase64: priorVideosBase64,
        reasoningEffort: session.reasoningEffort,
        executeToolCall: executeToolCall,
      )) {
        if (generation != _playbackGeneration) break;
        if (event is AiTextDelta) {
          _turnResponseReceived = true;
          rawText += event.text;
          if (_isSentinelOnlySoFar(rawText)) {
            if (rawText.contains(ignoreTurnSentinel) ||
                rawText.contains(turnDoneSentinel)) {
              sentinelHeldBack = true;
            }
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
          _turnResponseReceived = true;
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
          // Performing the call (and recording its outcome) is
          // executeToolCall's job, above; here we only keep the
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
          // Save the AI reply before playback drains. When a sentinel
          // was involved, persist the cleaned text instead of the raw
          // one: the sentinel is a control signal, never content, and
          // must stay out of history/replay. responseId is kept, so
          // request chaining (previous_response_id) still works.
          final cleanedRaw =
              parsed.kind == 'turnDone' || parsed.text != rawText.trim()
              ? <String, dynamic>{...event.raw, 'text': parsed.text}
              : event.raw;
          messages.add(
            ChatMessage(
              id: newId(),
              sessionId: session.id,
              role: 'ai',
              kind: sawTool ? 'actions' : 'text',
              payloadJson: jsonEncode(cleanedRaw),
              createdAt: DateTime.now(),
            ),
          );
          await _saveMessages();
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
          if (parsed.kind == 'turnDone') {
            // The model closed the turn after tool results: nothing
            // more to say. Drop any held (unspoken) fragments - tool
            // actions already performed stay performed - and let the
            // normal post-loop path drain the queue and return to
            // listening. No suspended-explanation resume: unlike
            // IGNORE_TURN this is not an interruption verdict.
            held.clear();
            _producerDone = true;
            await consumer;
            if (generation != _playbackGeneration) return;
            state = micMuted ? TurnState.muted : TurnState.listening;
            notifyListeners();
            return;
          }
          if (sentinelHeldBack && !textReleased && parsed.text.isNotEmpty) {
            // Speech arrived glued to a stray sentinel and was held
            // back whole; queue the cleaned text directly.
            held.clear();
            _queue.add(TextItem(parsed.text));
          } else {
            for (final s in splitter.flush()) {
              held.add(s);
            }
            for (final h in held) {
              _queue.add(TextItem(h));
            }
            held.clear();
          }
        }
      }
    } finally {
      _producerDone = true;
      client.close();
      if (identical(_activeClient, client)) _activeClient = null;
    }
    if (generation != _playbackGeneration) return;
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
          _turnOutputSurfaced = true;
          state = TurnState.speaking;
          notifyListeners();
          _currentSpeechChunkForSuspend =
              splitSpeech(item.text).firstOrNull ?? item.text;
          speaker.enqueueText(item.text);
          await speaker.drained;
          _queue.completed.add({'tool': 'text', 'rect': ''});
        } else if (item is ActionItem) {
          _turnOutputSurfaced = true;
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
  /// happened, so the outcome can be persisted as the tool result (and
  /// sent back to the model when the action failed, instead of the
  /// model assuming every call succeeded).
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
    // The pre-action framing above used the rect predicted from the
    // raw arguments; the applied rect is the truth (text is measured,
    // edits may have moved/resized the element, landmarks land where
    // they land). Frame it if the prediction missed it, otherwise the
    // new content can end up off-screen with no camera move at all.
    if (applied != null && item.tool != 'remove_element') {
      await board.frameRectUnlessCovered(applied, rect);
    }
    if (applied != null) {
      _queue.completed.add({
        'tool': item.tool,
        'rect':
            '${applied.left.round()},${applied.top.round()},${applied.width.round()}x${applied.height.round()}',
      });
    }
    _scheduleSave();
    return applied != null
        ? AiToolResult.success(_boardActionResultText(item, applied))
        : AiToolResult.failure(
            '${item.tool} could not be performed: check the element_id, '
            'the arguments, and that the target element exists.',
          );
  }

  /// The success result of a board action: just the element and its
  /// bounding box on the board (see
  /// [BoardController.describeBoardRect]). The element's own stored
  /// rect is preferred over the rect applyAction returned, since text
  /// is re-measured and edited elements may have moved. These outputs
  /// are persisted and replayed with later turns, so over a session
  /// the bboxes accumulate into the model's map of what is where -
  /// that is what lets it place the next element in free space
  /// instead of overwriting something.
  String _boardActionResultText(ActionItem item, Rect applied) {
    final id = item.elementId;
    var rect = applied;
    if (id != null && item.tool != 'remove_element') {
      final el = board.elements.where((e) => e.id == id).firstOrNull;
      if (el != null) rect = el.rect;
    }
    final bbox = BoardController.describeBoardRect(rect);
    final named = id == null ? item.tool : "${item.tool} '$id'";
    return switch (item.tool) {
      'remove_element' => '$named removed, $bbox now free.',
      'point_at' => '$named pointed at $bbox.',
      'focus_viewport' => '$named framed $bbox.',
      'mark_landmarks' => '$named marked $bbox.',
      _ => '$named placed, $bbox.',
    };
  }

  // ---------- Interruption ----------
  /// Halts playback promptly; completed board content stays exactly as drawn.
  Future<void> interruptPlayback({required bool fromVoice}) async {
    if (!_turnInFlight) return;
    _failPendingToolCalls('Playback was interrupted before this action ran.');
    // Abort the request FIRST, before anything that can take time
    // (stopping audio): this completes AiClient's close signal, which
    // both ends the locally-awaited stream at once and fires the
    // transport's abort trigger for the in-flight HTTP request - even
    // while it is still reaching the server or awaiting its first
    // token, the phases where the status already reads "thinking".
    _activeClient?.close();
    // Thinking-phase interruption: the model has produced nothing the
    // student has seen or heard yet, so there is no partial explanation
    // to suspend/resume. Cancel the request outright (client close
    // below, made prompt by AiClient._untilClosed) and supersede the
    // turn: its input is concatenated into the next fresh turn instead
    // of being answered on its own. Any interruption context the model
    // already received with it is moot - nothing was ever said.
    final thinkingPhase = !_turnOutputSurfaced && _activeTurn != null;
    if (thinkingPhase) {
      _supersededTurn = _activeTurn;
      _suspended = null;
    } else {
      _suspended = _queue.suspend(
        speaker.currentChunk.value ?? _currentSpeechChunkForSuspend,
      );
    }
    _suspendedFromVoice = fromVoice;
    _playbackGeneration++;
    _playbackCancelled = true;
    _producerDone = true;
    await speaker.stop();
    activeActionTool = null;
    state = TurnState.listening;
    notifyListeners();
    // A new playback generation can start (e.g. false-trigger resume).
    _playbackCancelled = false;
  }

  /// Stops the AI completely, discarding any suspended explanation.
  Future<void> stopPlayback() async {
    // Stop means discard entirely - including a turn superseded while
    // thinking, which a voice/draw barge-in would otherwise merge into
    // the next turn.
    _supersededTurn = null;
    _suspended = null;
    await interruptPlayback(fromVoice: false);
    // interruptPlayback may have superseded a thinking turn; Stop
    // discards it rather than merging it into a later turn.
    _supersededTurn = null;
    _suspended = null;
    state = micMuted ? TurnState.muted : TurnState.listening;
    notifyListeners();
  }

  void _resumeSuspended() {
    final s = _suspended;
    if (s == null) return;
    _suspended = null;
    // The resumed explanation continues on the board; show its actions
    // again (a fresh manual move during it re-takes the camera).
    board.cameraTakenByStudent = false;
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
    if (_turnInFlight) unawaited(interruptPlayback(fromVoice: false));
  }

  void onManualCamera() {
    board.cameraTakenByStudent = true;
  }

  @override
  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    _errorTimer?.cancel();
    unawaited(flushSave());
    _frameTimer?.cancel();
    _silenceTimer?.cancel();
    unawaited(_stopMic());
    unawaited(_turnEncoder?.abort() ?? Future<void>.value());
    unawaited(_vad?.dispose() ?? Future<void>.value());
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
    this.priorMp4Bytes = const [],
  });

  final Uint8List mp4Bytes;
  final SuspendedPlayback? interruption;
  final List<AiUpload> uploads;

  /// Videos of earlier turns that were cancelled while the model was
  /// still thinking and never answered; sent before [mp4Bytes] so the
  /// model answers the concatenated input in one turn.
  final List<Uint8List> priorMp4Bytes;
}
