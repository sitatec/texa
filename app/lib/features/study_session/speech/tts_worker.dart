import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:texa/core/constants.dart';
import 'package:texa/features/study_session/speech/model_store.dart';

import '../../../core/data/models.dart';
import '../playback/wav_builder.dart';

/// Setup handed to the worker isolate at spawn.
typedef _WorkerSetup = ({
  SendPort reply,
  TtsEngine engine,
  String model,
  String? voices,
  String tokens,
  String lexicon,
  bool debug,
});

/// Long-lived worker isolate that owns the Kokoro TTS engine.
///
/// FFI synthesis blocks whichever isolate runs it, so it cannot run on
/// the UI isolate: generating one chunk would freeze frames until the
/// whole chunk is done. Instead the engine is created once inside this
/// worker (model load included) and reused for every request — spawning
/// an isolate, let alone reloading the model, per call would cost far
/// more than the synthesis itself.
///
/// Protocol: the UI isolate sends `(id, text)` requests; the worker
/// streams back `(id, wav)` per generated Kokoro sentence and a final
/// `(id, null)` when the request is done. Requests are generated one at
/// a time in the worker; segments produced before anyone listens are
/// buffered by the per-request [StreamController].
class TtsWorker {
  TtsWorker._(this._isolate, this._responses, this._errors) {
    _responseSub = _responses.listen(_onMessage);
    _errorSub = _errors.listen(_onError);
  }

  final Isolate _isolate;
  SendPort? _commands;
  final Completer<SendPort?> _ready = Completer<SendPort?>();
  final ReceivePort _responses;
  final ReceivePort _errors;
  late final StreamSubscription<dynamic> _responseSub;
  late final StreamSubscription<dynamic> _errorSub;
  final Map<int, StreamController<Uint8List>> _pending = {};
  int _nextId = 0;

  /// Spawns the worker and loads the selected TTS engine's model.
  /// Returns null when TTS is unavailable (e.g. on web, where isolates
  /// do not exist, or when the model fails to load).
  static Future<TtsWorker?> start({
    required TtsEngine engine,
    required String model,
    String? voices,
    required String tokens,
    required String lexicon,
  }) async {
    final responses = ReceivePort();
    final errors = ReceivePort();
    Isolate isolate;
    try {
      isolate = await Isolate.spawn(_entry, (
        reply: responses.sendPort,
        engine: engine,
        model: model,
        voices: voices,
        tokens: tokens,
        lexicon: lexicon,
        debug: kDebugMode,
      ), onError: errors.sendPort);
    } catch (_) {
      responses.close();
      errors.close();
      return null;
    }
    // One permanent listener per port handles the startup handshake
    // first (see _onMessage/_onError): ReceivePort streams are
    // single-subscription, so a temporary handshake listener cannot
    // be cancelled and replaced.
    final worker = TtsWorker._(isolate, responses, errors);
    final commands = await worker._ready.future;
    if (commands == null) {
      worker.dispose();
      return null;
    }
    worker._commands = commands;
    return worker;
  }

  /// Synthesises [text], streaming one WAV per Kokoro sentence as the
  /// worker generates it.
  Stream<Uint8List> synthesise(String text) {
    final id = _nextId++;
    final controller = StreamController<Uint8List>(
      // Nobody is listening anymore: drop whatever the worker still
      // produces for this request.
      onCancel: () => _pending.remove(id),
    );
    _pending[id] = controller;
    _commands?.send((id, text));
    return controller.stream;
  }

  void dispose() {
    final pending = _pending.values.toList();
    _pending.clear();
    for (final controller in pending) {
      unawaited(controller.close());
    }
    unawaited(_responseSub.cancel());
    unawaited(_errorSub.cancel());
    _responses.close();
    _errors.close();
    _isolate.kill(priority: Isolate.immediate);
  }

  void _onMessage(dynamic message) {
    if (!_ready.isCompleted) {
      // Startup handshake: the worker sends its command port on
      // success, or null when the model failed to load.
      _ready.complete(message as SendPort?);
      return;
    }
    final (id, wav) = message as (int, Uint8List?);
    final controller = _pending[id];
    if (controller == null) return; // request was cancelled
    if (wav == null) {
      _pending.remove(id);
      unawaited(controller.close());
    } else {
      controller.add(wav);
    }
  }

  void _onError(dynamic _) {
    if (!_ready.isCompleted) {
      _ready.complete(null);
      return;
    }
    _failPending();
  }

  /// The worker died: fail every in-flight request instead of leaving
  /// its listeners waiting forever.
  void _failPending() {
    final pending = _pending.values.toList();
    _pending.clear();
    for (final controller in pending) {
      controller.addError(StateError('TTS worker stopped unexpectedly'));
      unawaited(controller.close());
    }
  }

  /// Worker entry point. Loads the model once, then serves synthesis
  /// requests for the rest of the app's lifetime.
  static void _entry(_WorkerSetup setup) {
    final sherpa.OfflineTts tts;
    try {
      sherpa.initBindings();
      tts = sherpa.OfflineTts(
        sherpa.OfflineTtsConfig(
          model: sherpa.OfflineTtsModelConfig(
            kokoro: setup.engine == TtsEngine.kokoro
                ? sherpa.OfflineTtsKokoroModelConfig(
                    model: setup.model,
                    voices: setup.voices ?? '',
                    tokens: setup.tokens,
                    lexicon: setup.lexicon,
                  )
                : const sherpa.OfflineTtsKokoroModelConfig(),
            vits: setup.engine == TtsEngine.piper
                ? sherpa.OfflineTtsVitsModelConfig(
                    model: setup.model,
                    tokens: setup.tokens,
                    lexicon: setup.lexicon,
                  )
                : const sherpa.OfflineTtsVitsModelConfig(),
            numThreads: setup.engine == TtsEngine.piper && !isMobile
                ? 1 // For piper on desktop 1 thread is enough, more may even slow down perf due to context switching overhead
                : getOptimalThreads(),
            debug: setup.debug,
          ),
          // One sentence per batch, so the callback below delivers
          // audio sentence by sentence.
          maxNumSentences: 1,
        ),
      );
    } catch (_) {
      setup.reply.send(null); // tell the UI isolate init failed
      return;
    }
    final commands = ReceivePort();
    setup.reply.send(commands.sendPort);
    commands.listen((message) {
      final (id, text) = message as (int, String);
      try {
        tts.generateWithCallback(
          text: text,
          sid: setup.engine == TtsEngine.piper ? 0 : 3, // 30 for french
          callback: (samples) {
            if (samples.isNotEmpty) {
              setup.reply.send((id, buildWav(samples, tts.sampleRate)));
            }
            return 1; // non-zero: keep generating
          },
        );
      } catch (e) {
        debugPrint('Texa TTS worker: $e');
      }
      setup.reply.send((id, null));
    });
  }
}
