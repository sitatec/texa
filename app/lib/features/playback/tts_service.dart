import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'speech_chunker.dart';
import 'wav_builder.dart';

/// Streaming speech sink: sentence chunks are enqueued as they arrive and
/// played sequentially, synthesising chunk n+1 while chunk n plays.
class SpeechSpeaker {
  SpeechSpeaker({required this.synthesise});

  /// Synthesises one sentence chunk to WAV bytes (Kokoro via sherpa-onnx).
  final Future<Uint8List?> Function(String chunk) synthesise;
  final AudioPlayer _player = AudioPlayer();
  final ValueNotifier<String?> currentChunk = ValueNotifier<String?>(null);
  final Queue<String> _queue = Queue<String>();
  Completer<void>? _idle;
  bool _running = false;
  bool _stopped = false;
  String? interruptedChunk;

  bool get isSpeaking => _running || _queue.isNotEmpty;

  /// Enqueues one already-split sentence chunk for immediate playback.
  void enqueue(String chunk) {
    final t = chunk.trim();
    if (t.isEmpty) {
      return;
    }
    _stopped = false;
    _queue.add(t);
    _idle ??= Completer<void>();
    if (!_running) {
      unawaited(_run());
    }
  }

  /// Splits [text] into sentence chunks and enqueues each one.
  void enqueueText(String text) {
    for (final c in splitSpeech(text)) {
      enqueue(c);
    }
  }

  Future<void> _run() async {
    _running = true;
    Uint8List? nextWav;
    String? nextChunk;
    if (_queue.isNotEmpty) {
      nextChunk = _queue.first;
      nextWav = await _trySynth(nextChunk);
    }
    while (_queue.isNotEmpty && !_stopped) {
      final chunk = _queue.removeFirst();
      final wav = (nextChunk == chunk) ? nextWav : await _trySynth(chunk);
      nextWav = null;
      nextChunk = null;
      Future<Uint8List?>? nextFuture;
      if (_queue.isNotEmpty) {
        nextChunk = _queue.first;
        nextFuture = _trySynth(nextChunk);
      }
      if (wav == null) {
        // A chunk that failed to synthesise is skipped, not faked: the
        // caption never shows text that is not actually being spoken.
        debugPrint('Texa TTS: skipping chunk that failed to synthesise');
      } else {
        currentChunk.value = chunk;
        interruptedChunk = chunk;
        try {
          await _player.setAudioSource(WavStreamAudioSource(wav));
          final done = _player.playerStateStream.firstWhere(
            (s) => s.processingState == ProcessingState.completed,
          );
          await _player.play();
          await done.timeout(
            const Duration(seconds: 90),
            onTimeout: () => _player.playerState,
          );
          await _player.stop();
        } catch (e) {
          debugPrint('Texa TTS playback: $e');
        }
      }
      if (nextFuture != null) {
        nextWav = await nextFuture;
      }
    }
    _running = false;
    currentChunk.value = null;
    final idle = _idle;
    _idle = null;
    if (idle != null && !idle.isCompleted) {
      idle.complete();
    }
  }

  Future<Uint8List?> _trySynth(String chunk) async {
    try {
      return await synthesise(chunk);
    } catch (e) {
      debugPrint('Texa TTS synth: $e');
      return null;
    }
  }

  /// Waits until every enqueued chunk has finished playing.
  Future<void> get drained => _idle?.future ?? Future<void>.value();

  /// Stops within one chunk: audio halts now, the queue is cleared.
  Future<void> stop() async {
    _stopped = true;
    _queue.clear();
    currentChunk.value = null;
    try {
      await _player.stop();
    } catch (_) {}
    final idle = _idle;
    _idle = null;
    if (idle != null && !idle.isCompleted) {
      idle.complete();
    }
  }

  void dispose() {
    unawaited(stop());
    _player.dispose();
    currentChunk.dispose();
  }
}

/// In-memory WAV source for just_audio (no temp files).
// ignore: experimental_member_use
class WavStreamAudioSource extends StreamAudioSource {
  WavStreamAudioSource(this.bytes);
  final List<int> bytes;
  @override
  // ignore: experimental_member_use
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    start ??= 0;
    end ??= bytes.length;
    // ignore: experimental_member_use
    return StreamAudioResponse(
      sourceLength: bytes.length,
      contentLength: end - start,
      offset: start,
      stream: Stream.value(bytes.sublist(start, end)),
      contentType: 'audio/wav',
    );
  }
}

/// Builds WAV bytes from sherpa Kokoro float output.
Uint8List wavFromFloat(Float32List samples, int sampleRate) =>
    buildWav(samples, sampleRate);
