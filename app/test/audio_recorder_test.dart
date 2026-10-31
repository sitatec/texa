import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:texa/features/study_session/playback/wav_builder.dart';
import 'package:texa/features/study_session/audio_recorder.dart';

void main() {
  group('AudioRecorder AEC strategy', () {
    test('software AEC flag is exposed and gates feedPlaybackData', () {
      final software = AudioRecorder(usesSoftwareEchoCancellation: true);
      final preset = AudioRecorder(usesSoftwareEchoCancellation: false);
      expect(software.usesSoftwareEchoCancellation, isTrue);
      expect(preset.usesSoftwareEchoCancellation, isFalse);
      // Neither is initialised, so feeding playback must be a safe no-op
      // (and on preset platforms it must never reach the native filter).
      software.feedPlaybackData(Uint8List.fromList([0, 0, 1, 0]));
      preset.feedPlaybackData(Uint8List.fromList([0, 0, 1, 0]));
      expect(software.isStreaming, isFalse);
    });

    test('startStreaming before init throws', () {
      final recorder = AudioRecorder(usesSoftwareEchoCancellation: true);
      expect(recorder.startStreaming, throwsStateError);
    });
  });

  group('pcm16MonoFromWav', () {
    test('strips the WAV header at the native rate', () {
      final wav = buildWav(Float32List.fromList([0, 0.5, -0.5]), 16000);
      final pcm = pcm16MonoFromWav(wav, targetSampleRate: 16000);
      expect(pcm.length, 6);
      final view = ByteData.sublistView(pcm);
      expect(view.getInt16(0, Endian.little), 0);
      expect(view.getInt16(2, Endian.little), closeTo(16384, 1));
      expect(view.getInt16(4, Endian.little), closeTo(-16384, 1));
    });

    test('resamples 24 kHz playback to the 16 kHz capture rate', () {
      final wav = buildWav(Float32List(240), 24000);
      final pcm = pcm16MonoFromWav(wav, targetSampleRate: 16000);
      expect(pcm.length, 160 * 2);
    });

    test('rejects non-WAV input', () {
      expect(
        pcm16MonoFromWav(
          Uint8List.fromList([1, 2, 3]),
          targetSampleRate: 16000,
        ),
        isEmpty,
      );
    });
  });
}
