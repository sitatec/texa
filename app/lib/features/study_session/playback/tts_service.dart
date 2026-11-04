import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../debug_log.dart';
import 'speech_chunker.dart';
import 'wav_builder.dart';

/// Streaming speech sink: sentence chunks are enqueued as they arrive and
/// played sequentially, synthesising chunk n+1 while chunk n plays.
///
/// Synthesis streams too: each chunk yields one WAV per Kokoro sentence
/// (Kokoro splits more finely than [splitSpeech], e.g. at commas), and
/// segments are played as they arrive instead of waiting for the whole
/// chunk's audio to be generated first.
class SpeechSpeaker {
  SpeechSpeaker({required this.synthesise});

  /// Synthesises one chunk, streaming a WAV per Kokoro sentence
  /// (Kokoro via sherpa-onnx).
  final Stream<Uint8List> Function(String chunk) synthesise;
  final AudioPlayer _player = AudioPlayer();
  final ValueNotifier<String?> currentChunk = ValueNotifier<String?>(null);
  final Queue<String> _queue = Queue<String>();
  Completer<void>? _idle;
  bool _running = false;
  bool _stopped = false;
  String? interruptedChunk;

  /// Completed by [stop] so an in-progress segment wait ends at once
  /// instead of waiting for the player to report completion.
  Completer<void> _stopSignal = Completer<void>();

  bool get isSpeaking => _running || _queue.isNotEmpty;

  /// Enqueues one already-split sentence chunk for immediate playback.
  void enqueue(String chunk) {
    final t = chunk.trim();
    if (t.isEmpty) {
      return;
    }
    _stopped = false;
    _queue.add(t);
    texaDiag(
      'tts',
      'enqueue ${diagText(t)} queued=${_queue.length} running=$_running',
    );
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
    _stopSignal = Completer<void>();
    Stream<Uint8List>? nextStream;
    String? nextChunk;
    if (_queue.isNotEmpty) {
      nextChunk = _queue.first;
      nextStream = _startSynth(nextChunk);
    }
    while (_queue.isNotEmpty && !_stopped) {
      final chunk = _queue.removeFirst();
      final stream = (nextChunk == chunk && nextStream != null)
          ? nextStream
          : _startSynth(chunk);
      nextStream = null;
      nextChunk = null;
      // Start synthesising the following chunk now, so its generation
      // overlaps playback of this one.
      if (_queue.isNotEmpty) {
        nextChunk = _queue.first;
        nextStream = _startSynth(nextChunk);
      }
      var spoke = false;
      texaDiag('tts', 'chunk start ${diagText(chunk)} queued=${_queue.length}');
      try {
        await for (final wav in stream) {
          if (_stopped) break;
          if (!spoke) {
            currentChunk.value = chunk;
            interruptedChunk = chunk;
            spoke = true;
          }
          await _playSegment(wav);
        }
      } catch (e) {
        debugPrint('Texa TTS playback: $e');
      }
      texaDiag(
        'tts',
        'chunk end ${diagText(chunk)} spoke=$spoke stopped=$_stopped',
      );
      if (!spoke) {
        // A chunk that failed to synthesise is skipped, not faked: the
        // caption never shows text that is not actually being spoken.
        debugPrint('Texa TTS: skipping chunk that failed to synthesise');
      }
    }
    texaDiag('tts', 'run end stopped=$_stopped queued=${_queue.length}');
    _running = false;
    currentChunk.value = null;
    final idle = _idle;
    _idle = null;
    if (idle != null && !idle.isCompleted) {
      idle.complete();
    }
  }

  /// Starts synthesising [chunk] immediately and returns its segment
  /// stream. The backing [StreamController] buffers segments generated
  /// before the playback loop starts consuming them (which is what makes
  /// the next-chunk prefetch above work) and forwards cancellation to
  /// the synthesis stream.
  Stream<Uint8List> _startSynth(String chunk) {
    final controller = StreamController<Uint8List>();
    final sub = synthesise(chunk).listen(
      controller.add,
      onError: (Object e, StackTrace st) {
        debugPrint('Texa TTS synth: $e');
        controller.addError(e, st);
      },
      onDone: () => unawaited(controller.close()),
    );
    controller.onCancel = () => sub.cancel();
    return controller.stream;
  }

  /// Plays one synthesised sentence segment to completion.
  Future<void> _playSegment(Uint8List wav) async {
    await _player.setAudioSource(WavStreamAudioSource(wav));
    final done = _player.playerStateStream.firstWhere(
      (s) => s.processingState == ProcessingState.completed,
    );
    await _player.play();
    await Future.any<void>([done.then((_) {}), _stopSignal.future])
        .timeout(const Duration(seconds: 90), onTimeout: () {});
    await _player.stop();
  }

  /// Waits until every enqueued chunk has finished playing.
  Future<void> get drained => _idle?.future ?? Future<void>.value();

  /// Stops within one chunk: audio halts now, the queue is cleared.
  Future<void> stop() async {
    texaDiag(
      'tts',
      'stop queued=${_queue.length} current=${currentChunk.value == null ? 'none' : diagText(currentChunk.value!)}',
    );
    _stopped = true;
    _queue.clear();
    currentChunk.value = null;
    if (!_stopSignal.isCompleted) _stopSignal.complete();
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
