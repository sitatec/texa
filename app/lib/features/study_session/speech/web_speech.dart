import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import '../../../core/constants.dart';
import '../../../core/data/models.dart';
import 'model_store.dart';
import 'speech_engine.dart';

/// Web speech engine backed by the `texa-webspeech` package workers:
///
/// - `speech_worker.js` (realtime): raw Silero VAD + Smart Turn sharing
///   one onnxruntime-web instance. Kept separate so VAD and barge-in
///   stay responsive while TTS is generating.
/// - `speech_tts_worker.js` (TTS): Kokoro (fp32, WebGPU with threaded
///   WASM fallback) or Piper (self-provisioning into OPFS), one engine
///   alive at a time.
///
/// Model files for VAD/Smart Turn come from the existing Cache Storage
/// provisioning ([ModelStore]); Kokoro/Piper models are downloaded and
/// cached by their JS libraries on first init.
class WebSpeechEngine implements SpeechEngine {
  _WorkerClient? _realtime;
  _WorkerClient? _tts;
  String? _ttsEngine;

  /// Fire-and-forget warmup started by [initTts]; [synthesise] awaits
  /// it (only while still running) so a first real utterance never
  /// races WebGPU shader compilation, yet init never blocks on it.
  Future<void>? _warmup;

  /// In-flight [initTts], shared by concurrent callers (app startup and
  /// the setup screen can race): a second init request would reset the
  /// worker's engine mid-flight and break the warmup synthesis.
  Future<bool>? _initTtsInFlight;
  bool _vadReady = false;

  @override
  bool get isReady => _tts != null;

  String get _wasmBaseUrl => Uri.base.resolve('ort-wasm/').toString();

  static String _relative(String path) => path.startsWith('/texa-models/')
      ? path.substring('/texa-models/'.length)
      : path;

  Future<_WorkerClient> _realtimeWorker() async {
    if (_realtime != null) return _realtime!;
    final worker = web.Worker(
      Uri.base.resolve('speech_worker.js').toString().toJS,
    );
    return _realtime = _WorkerClient(worker);
  }

  Future<_WorkerClient> _ttsWorker() async {
    if (_tts != null) return _tts!;
    final worker = web.Worker(
      Uri.base.resolve('speech_tts_worker.js').toString().toJS,
    );
    return _tts = _WorkerClient(worker);
  }

  Future<bool> _initVad(String vadPath, String smartTurnPath) async {
    try {
      final store = createModelStore();
      await store.activate();
      final vadBytes = await store.readBytes(_relative(vadPath));
      if (vadBytes == null) return false;
      final smartBytes = smartTurnPath.isEmpty
          ? null
          : await store.readBytes(_relative(smartTurnPath));
      final client = await _realtimeWorker();
      final reply = await client.request({
        'type': 'init'.toJS,
        'vadModel': vadBytes.toJS,
        'smartTurnModel': smartBytes?.toJS,
        'wasmBaseUrl': _wasmBaseUrl.toJS,
        'config': _jsObject({
          'threshold': 0.5.toJS,
          'minSilenceMs': vadSilenceMs.toJS,
          'minSpeechMs': sustainedSpeechMs.toJS,
          'sampleRate': 16000.toJS,
        }),
      });
      _vadReady = reply != null;
      return _vadReady;
    } catch (e) {
      debugPrint('Texa web VAD init: $e');
      return false;
    }
  }

  @override
  Future<bool> verifyVad(String vadPath, {String smartTurnPath = ''}) =>
      _initVad(vadPath, smartTurnPath);

  @override
  Future<SpeechVad> createVad(
    String vadPath, {
    String smartTurnPath = '',
  }) async {
    if (!_vadReady) {
      final ok = await _initVad(vadPath, smartTurnPath);
      if (!ok) throw StateError('Web VAD failed to initialise');
    }
    return _WebVad(await _realtimeWorker());
  }

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
      // Model/token paths are Sherpa concepts; the JS engines resolve
      // and cache their own models, so only the engine matters here.
      final client = await _ttsWorker();
      if (_ttsEngine == engine.name) return true;
      final label = engine == TtsEngine.kokoro ? 'Kokoro voice' : 'Piper voice';
      final reply = await client.request({
        'type': 'init'.toJS,
        'engine': engine.name.toJS,
        'wasmBaseUrl': _wasmBaseUrl.toJS,
        'kokoroBaseUrl': kokoroWebBaseUrl.toJS,
        'voice': 'af_heart'.toJS,
        'voiceId': 'en_US-amy-medium'.toJS,
      }, onProgress: (fraction) => onProgress?.call(label, fraction));
      _ttsEngine = reply == null ? null : engine.name;
      if (reply != null) _startWarmup(client);
      return reply != null;
    } catch (e) {
      debugPrint('Texa web TTS init: $e');
      return false;
    }
  }

  void _startWarmup(_WorkerClient client) {
    _warmup = () async {
      try {
        await client.synthesise('a').forEach((_) {});
      } catch (e) {
        debugPrint('Texa speech warmup: $e');
      }
    }();
  }

  @override
  Stream<Uint8List> synthesise(String chunk) async* {
    final warmup = _warmup;
    if (warmup != null) await warmup;
    final client = _tts;
    if (client == null) return;
    yield* client.synthesise(chunk);
  }

  @override
  void cancelSynthesis() => _tts?.cancelCurrent();

  @override
  void dispose() {
    _realtime?.dispose();
    _tts?.dispose();
    _realtime = null;
    _tts = null;
    _ttsEngine = null;
    _warmup = null;
    _vadReady = false;
  }
}

class _WebVad implements SpeechVad {
  _WebVad(this._client);
  final _WorkerClient _client;

  @override
  Future<bool> process(Float32List window) async {
    final reply = await _client.request({
      'type': 'vad'.toJS,
      'samples': window.toJS,
    }, expect: 'vad-result');
    final detected = reply?.getProperty('detected'.toJS);
    return detected != null &&
        detected.isA<JSBoolean>() &&
        (detected as JSBoolean).toDart;
  }

  @override
  Future<bool> turnComplete(Float32List turnAudio) async {
    final reply = await _client.request({
      'type': 'smart-turn'.toJS,
      'samples': turnAudio.toJS,
    }, expect: 'smart-turn-result');
    final complete = reply?.getProperty('complete'.toJS);
    if (complete == null || !complete.isA<JSBoolean>()) return true;
    return (complete as JSBoolean).toDart;
  }

  @override
  void reset() => _client.post({'type': 'reset'.toJS});

  @override
  Future<void> dispose() async {
    // The realtime worker is shared for the app lifetime (owned by
    // WebSpeechEngine); a session VAD only resets its state.
    reset();
  }
}

/// Request/response client for one dedicated worker. Synthesis uses the
/// same id space but streams multiple `audio` messages before `done`.
class _WorkerClient {
  _WorkerClient(this._worker) {
    _worker.onmessage = ((web.MessageEvent event) {
      final data = event.data;
      if (data == null || !data.isA<JSObject>()) return;
      _onMessage(data as JSObject);
    }).toJS;
    _worker.onerror = ((web.Event event) {
      _failAll(StateError('Speech worker error'));
    }).toJS;
  }

  final web.Worker _worker;
  int _nextId = 1;
  final Map<int, Completer<JSObject?>> _pending = {};
  final Map<int, StreamController<Uint8List>> _streams = {};
  int? _currentSynthesisId;

  void post(Map<String, JSAny?> fields) {
    _worker.postMessage(_jsObject(fields));
  }

  final Map<int, void Function(double fraction)> _progressCallbacks = {};

  Future<JSObject?> request(
    Map<String, JSAny?> fields, {
    String? expect,
    void Function(double fraction)? onProgress,
  }) {
    final id = _nextId++;
    final completer = Completer<JSObject?>();
    _pending[id] = completer;
    if (onProgress != null) _progressCallbacks[id] = onProgress;
    _worker.postMessage(_jsObject({...fields, 'id': id.toJS}));
    return completer.future.whenComplete(() => _progressCallbacks.remove(id));
  }

  Stream<Uint8List> synthesise(String text) {
    final id = _nextId++;
    _currentSynthesisId = id;
    final controller = StreamController<Uint8List>(
      onCancel: () {
        _streams.remove(id);
        _worker.postMessage(
          _jsObject({'type': 'cancel'.toJS, 'requestId': id.toJS}),
        );
      },
    );
    _streams[id] = controller;
    _worker.postMessage(
      _jsObject({
        'type': 'synthesise'.toJS,
        'id': id.toJS,
        'text': text.toJS,
        'voice': 'af_heart'.toJS,
      }),
    );
    return controller.stream;
  }

  void cancelCurrent() {
    final id = _currentSynthesisId;
    if (id != null) {
      _worker.postMessage(
        _jsObject({'type': 'cancel'.toJS, 'requestId': id.toJS}),
      );
    }
  }

  void _onMessage(JSObject data) {
    final type = data.getProperty('type'.toJS);
    final idProp = data.getProperty('id'.toJS);
    if (idProp == null || !idProp.isA<JSNumber>()) return;
    final id = (idProp as JSNumber).toDartInt;
    final typeStr = type != null && type.isA<JSString>()
        ? (type as JSString).toDart
        : '';
    if (typeStr == 'progress') {
      // Progress is not a reply: it must only feed the progress
      // callback and never complete the pending request. Falling
      // through to the completion below once made initTts return (and
      // start the warmup synthesis) while the worker was still loading
      // the model, hence spurious "TTS not initialised" errors.
      final callback = _progressCallbacks[id];
      if (callback != null) {
        final loaded = data.getProperty('loaded'.toJS);
        final total = data.getProperty('total'.toJS);
        if (loaded != null &&
            loaded.isA<JSNumber>() &&
            total != null &&
            total.isA<JSNumber>()) {
          final t = (total as JSNumber).toDartDouble;
          if (t > 0) {
            callback(((loaded as JSNumber).toDartDouble / t).clamp(0, 1));
          }
        }
      }
      return;
    }
    if (typeStr == 'audio') {
      final wav = data.getProperty('wav'.toJS);
      if (wav != null && wav.isA<JSArrayBuffer>()) {
        _streams[id]?.add((wav as JSArrayBuffer).toDart.asUint8List());
      }
      return;
    }
    if (typeStr == 'done') {
      final controller = _streams.remove(id);
      if (controller != null) unawaited(controller.close());
      if (_currentSynthesisId == id) _currentSynthesisId = null;
      return;
    }
    if (typeStr == 'error') {
      final message = data.getProperty('message'.toJS);
      final error = StateError(
        message != null && message.isA<JSString>()
            ? (message as JSString).toDart
            : 'Speech worker error',
      );
      final controller = _streams.remove(id);
      if (controller != null) {
        controller.addError(error);
        unawaited(controller.close());
      }
      _pending.remove(id)?.completeError(error);
      return;
    }
    _pending.remove(id)?.complete(data);
  }

  void _failAll(Object error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
    for (final controller in _streams.values) {
      controller.addError(error);
      unawaited(controller.close());
    }
    _streams.clear();
  }

  void dispose() {
    _failAll(StateError('Speech worker disposed'));
    _worker.terminate();
  }
}

JSObject _jsObject(Map<String, JSAny?> entries) {
  final obj = JSObject();
  for (final e in entries.entries) {
    if (e.value != null) obj.setProperty(e.key.toJS, e.value);
  }
  return obj;
}
