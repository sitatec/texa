import 'dart:async';
import 'dart:typed_data';

import '../../../core/data/models.dart';
import 'speech_engine_stub.dart'
    if (dart.library.io) 'speech_engine_native.dart'
    if (dart.library.js_interop) 'speech_engine_web.dart'
    as impl;

/// One live voice-activity detector for a session's microphone pipeline.
///
/// Native (Sherpa) detectors are synchronous internally; web detectors
/// run in the `speech_worker.js` worker, so detection is asynchronous
/// on every platform through this interface.
abstract interface class SpeechVad {
  /// Feeds one 512-sample window (16 kHz mono floats); resolves to
  /// whether speech is currently detected after that window.
  Future<bool> process(Float32List window);

  /// Smart Turn end-of-turn judgement over the captured turn audio.
  /// Returns true when the turn looks complete (or when no Smart Turn
  /// model is available, in which case callers fall back to silence).
  Future<bool> turnComplete(Float32List turnAudio);

  void reset();
  Future<void> dispose();
}

/// Platform speech engine: TTS synthesis plus VAD creation.
///
/// Native platforms use Sherpa (`SherpaSpeech`); web uses
/// `WebSpeechEngine`, backed by the `texa-webspeech` workers.
abstract interface class SpeechEngine {
  bool get isReady;

  Future<bool> initTts(
    TtsEngine engine, {
    required String model,
    String? voices,
    required String tokens,
    required String lexicon,
    void Function(String label, double fraction)? onProgress,
  });

  Future<bool> verifyVad(String vadPath, {String smartTurnPath = ''});

  Future<SpeechVad> createVad(String vadPath, {String smartTurnPath = ''});

  Stream<Uint8List> synthesise(String chunk);

  /// Drops any in-flight synthesis result (barge-in). Playback stop is
  /// handled by the caller; this only tells the engine not to deliver.
  void cancelSynthesis();

  void dispose();
}

SpeechEngine createSpeechEngine() => impl.createSpeechEngine();
