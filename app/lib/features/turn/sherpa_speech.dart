import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../../core/constants.dart';
import '../playback/wav_builder.dart';

/// Owns the sherpa-onnx Kokoro engine and Silero VAD for the app lifetime.
class SherpaSpeech {
  sherpa.OfflineTts? _tts;
  bool get isReady => _tts != null;

  /// Initialises bindings and Kokoro; returns false where unavailable (web).
  Future<bool> initTts(String kokoroDir) async {
    try {
      await sherpa.initBindingsAsync();
      _tts = sherpa.OfflineTts(
        sherpa.OfflineTtsConfig(
          model: sherpa.OfflineTtsModelConfig(
            kokoro: sherpa.OfflineTtsKokoroModelConfig(
              model: '$kokoroDir/model.int8.onnx',
              voices: '$kokoroDir/voices.bin',
              tokens: '$kokoroDir/tokens.txt',
              lexicon: '$kokoroDir/lexicon-us-en.txt',
              dataDir: '$kokoroDir/espeak-ng-data',
            ),
            numThreads: 1,
            debug: false,
          ),
          maxNumSentences: 1,
        ),
      );
      return true;
    } catch (e) {
      debugPrint('Texa sherpa TTS init: $e');
      return false;
    }
  }

  /// Verifies Silero loads against the installed model file.
  Future<bool> verifyVad(String vadPath) async {
    sherpa.VoiceActivityDetector? vad;
    try {
      await sherpa.initBindingsAsync();
      vad = createVad(vadPath);
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
  sherpa.VoiceActivityDetector createVad(String vadPath) =>
      sherpa.VoiceActivityDetector(
        config: sherpa.VadModelConfig(
          sileroVad: sherpa.SileroVadModelConfig(
            model: vadPath,
            minSilenceDuration: vadSilenceMs / 1000.0,
            minSpeechDuration: sustainedSpeechMs / 1000.0,
          ),
          numThreads: 1,
          debug: false,
        ),
        bufferSizeInSeconds: 10,
      );

  /// Synthesises one sentence chunk to in-memory WAV bytes.
  Future<Uint8List?> synthesise(String chunk) async {
    final tts = _tts;
    if (tts == null) return null;
    try {
      final audio = tts.generateWithConfig(
        text: chunk,
        config: sherpa.OfflineTtsGenerationConfig(
          sid: kokoroSpeakerId,
          speed: kokoroSpeed,
          silenceScale: 0.2,
        ),
      );
      if (audio.samples.isEmpty) return null;
      return buildWav(audio.samples, audio.sampleRate);
    } catch (e) {
      debugPrint('Texa sherpa synth: $e');
      return null;
    }
  }

  void dispose() {
    try {
      _tts?.free();
    } catch (_) {}
    _tts = null;
  }
}
