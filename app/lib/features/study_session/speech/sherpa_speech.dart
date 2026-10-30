import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../../../core/constants.dart';
import '../../../core/data/models.dart';
import 'tts_worker.dart';

/// Owns speech for the app lifetime: Silero VAD on this isolate and the
/// Kokoro TTS engine in its long-lived worker isolate ([TtsWorker]),
/// because FFI synthesis blocks the isolate that runs it.
class SherpaSpeech {
  TtsWorker? _worker;
  String? _workerKey;
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
  Future<bool> initTts(
    TtsEngine engine, {
    required String model,
    String? voices,
    required String tokens,
    required String lexicon,
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
      return _worker != null;
    } catch (e) {
      debugPrint('Texa sherpa TTS init: $e');
      return false;
    }
  }

  /// Verifies Silero loads against the installed model file.
  Future<bool> verifyVad(String vadPath, {String smartTurnPath = ""}) async {
    sherpa.VoiceActivityDetector? vad;
    try {
      await _ensureBindings();
      vad = createVad(vadPath, smartTurnPath: smartTurnPath);
      return true;
    } catch (e) {
      debugPrint('Texa sherpa VAD verify: $e');
      return false;
    } finally {
      try {
        vad?.free();
      } catch (_) {}
    }
  }

  /// Creates a live VAD for one session's microphone pipeline.
  sherpa.VoiceActivityDetector createVad(
    String vadPath, {
    String smartTurnPath = "",
  }) => sherpa.VoiceActivityDetector(
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
  );

  /// Synthesises [chunk] in the TTS worker, streaming one WAV per
  /// Kokoro sentence as it is generated (Kokoro splits more finely than
  /// our own sentence splitter — it also breaks at commas and other
  /// punctuation — so playback can start on the first sentence).
  Stream<Uint8List> synthesise(String chunk) =>
      _worker?.synthesise(chunk) ?? const Stream<Uint8List>.empty();

  void dispose() {
    _worker?.dispose();
    _worker = null;
    _workerKey = null;
  }
}
