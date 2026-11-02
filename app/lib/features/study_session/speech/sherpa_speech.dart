import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../../../core/constants.dart';
import '../../../core/data/models.dart';
import 'speech_engine.dart';
import 'tts_worker.dart';

/// Owns speech for the app lifetime: Silero VAD on this isolate and the
/// Kokoro TTS engine in its long-lived worker isolate ([TtsWorker]),
/// because FFI synthesis blocks the isolate that runs it.
class SherpaSpeech implements SpeechEngine {
  TtsWorker? _worker;
  String? _workerKey;

  /// Fire-and-forget warmup started by [initTts]; [synthesise] awaits
  /// it (only while still running) so a first real utterance never
  /// races one-time runtime warm-up, yet init never blocks on it.
  Future<void>? _warmup;

  /// In-flight [initTts], shared by concurrent callers (app startup and
  /// the setup screen can race) so the TTS worker is only started once.
  Future<bool>? _initTtsInFlight;
  @override
  bool get isReady => _worker != null;

  /// In-flight (then completed) bindings initialisation for this
  /// isolate. Bindings only need loading once per isolate, so
  /// [initTts] and [verifyVad] share this single future instead of
  /// unconditionally re-running `initBindingsAsync` at every call.
  Future<void>? _bindings;

  Future<void> _ensureBindings() => _bindings ??= _initBindings();

  Future<void> _initBindings() async {
    try {
      await sherpa.initBindingsAsync();
    } catch (_) {
      _bindings = null; // failed: let the next caller retry
      rethrow;
    }
  }

  /// Starts the TTS worker for [engine] (loading its model once);
  /// returns false where unavailable (web). Calling again with the
  /// same configuration reuses the running worker; a different one
  /// restarts it — which is how switching voice in Settings takes effect.
  @override
  Future<bool> initTts(
    TtsEngine engine, {
    required String model,
    String? voices,
    required String tokens,
    required String lexicon,
    void Function(String label, double fraction)? onProgress,
  }) {
    final inFlight = _initTtsInFlight;
    if (inFlight != null) return inFlight;
    final future = _initTts(
      engine,
      model: model,
      voices: voices,
      tokens: tokens,
      lexicon: lexicon,
      onProgress: onProgress,
    );
    _initTtsInFlight = future;
    return future.whenComplete(() {
      if (identical(_initTtsInFlight, future)) _initTtsInFlight = null;
    });
  }

  Future<bool> _initTts(
    TtsEngine engine, {
    required String model,
    String? voices,
    required String tokens,
    required String lexicon,
    void Function(String label, double fraction)? onProgress,
  }) async {
    try {
      // Still needed on this isolate for the VAD created by [createVad].
      await _ensureBindings();
      final key = '$engine|$model|$tokens|$lexicon';
      if (_worker != null && _workerKey == key) return true;
      _worker?.dispose();
      _worker = await TtsWorker.start(
        engine: engine,
        model: model,
        voices: voices,
        tokens: tokens,
        lexicon: lexicon,
      );
      _workerKey = _worker == null ? null : key;
      if (_worker != null) _startWarmup();
      return _worker != null;
    } catch (e) {
      debugPrint('Texa sherpa TTS init: $e');
      return false;
    }
  }

  /// Verifies Silero loads against the installed model file.
  @override
  Future<bool> verifyVad(String vadPath, {String smartTurnPath = ''}) async {
    SpeechVad? vad;
    try {
      await _ensureBindings();
      vad = await createVad(vadPath, smartTurnPath: smartTurnPath);
      return true;
    } catch (e) {
      debugPrint('Texa sherpa VAD verify: $e');
      return false;
    } finally {
      await vad?.dispose();
    }
  }

  /// Creates a live VAD for one session's microphone pipeline.
  @override
  Future<SpeechVad> createVad(
    String vadPath, {
    String smartTurnPath = '',
  }) async => _SherpaVad(
    sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: vadPath,
          minSilenceDuration: vadSilenceMs / 1000.0,
          minSpeechDuration: sustainedSpeechMs / 1000.0,
          maxSpeechDuration: 20,
        ),
        smartTurnConfig: sherpa.SmartTurnConfig(
          model: smartTurnPath,
          maxSilenceDuration: 2.5,
        ),
        numThreads: 1,
        debug: kDebugMode,
      ),
      bufferSizeInSeconds: 10,
    ),
  );

  @override
  void cancelSynthesis() {
    // Native synthesis is request-scoped: dropping the stream
    // subscription (as SpeechSpeaker does on stop) drops delivery.
  }

  void _startWarmup() {
    final worker = _worker;
    if (worker == null) return;
    _warmup = () async {
      try {
        await worker.synthesise('a').forEach((_) {});
      } catch (e) {
        debugPrint('Texa speech warmup: $e');
      }
    }();
  }

  /// Synthesises [chunk] in the TTS worker, streaming one WAV per
  /// Kokoro sentence as it is generated (Kokoro splits more finely than
  /// our own sentence splitter — it also breaks at commas and other
  /// punctuation — so playback can start on the first sentence).
  @override
  Stream<Uint8List> synthesise(String chunk) async* {
    final warmup = _warmup;
    if (warmup != null) await warmup;
    yield* _worker?.synthesise(chunk) ?? const Stream<Uint8List>.empty();
  }

  @override
  void dispose() {
    _worker?.dispose();
    _worker = null;
    _workerKey = null;
    _warmup = null;
  }
}

/// Synchronous Sherpa VAD behind the async [SpeechVad] interface.
class _SherpaVad implements SpeechVad {
  _SherpaVad(this._vad);
  final sherpa.VoiceActivityDetector _vad;

  @override
  Future<bool> process(Float32List window) async {
    _vad.acceptWaveform(window);
    return _vad.isDetected();
  }

  @override
  Future<bool> turnComplete(Float32List turnAudio) async {
    // Sherpa applies Smart Turn internally while endpointing segments;
    // there is no separate judgement to query, so silence decides.
    return true;
  }

  @override
  void reset() => _vad.reset();

  @override
  Future<void> dispose() async {
    try {
      _vad.free();
    } catch (_) {}
  }
}
