import 'dart:math';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:texa/core/constants.dart';
import 'package:web/web.dart' as web;

import 'model_store.dart';

int getOptimalThreadsImpl(int maxThreads) {
  try {
    final cores = web.window.navigator.hardwareConcurrency.toInt();
    return min(max(1, cores), maxThreads);
  } catch (_) {
    return min(isMobile ? 2 : 4, maxThreads);
  }
}

/// Web model store.
///
/// Downloaded files persist in the browser Cache Storage (survives
/// reloads). [pathFor] returns virtual `/texa-models/...` keys; the web
/// speech workers receive the actual bytes via [readBytes] (see
/// `web_speech.dart`), so no WASM filesystem is involved anymore.
class WebModelStore implements ModelStore {
  static const _cacheName = 'texa-speech-models-v1';
  static const _root = '/texa-models';
  bool _activated = false;

  String _key(String relativePath) => '$_root/$relativePath';

  Future<web.Cache> get _cache => web.window.caches.open(_cacheName).toDart;

  @override
  String pathFor(String relativePath) => _key(relativePath);

  @override
  Future<bool> exists(String relativePath) async {
    final cache = await _cache;
    return (await cache.match(_key(relativePath).toJS).toDart) != null;
  }

  @override
  Future<Uint8List?> readBytes(String relativePath) async {
    final cache = await _cache;
    final response = await cache.match(_key(relativePath).toJS).toDart;
    if (response == null) return null;
    final buffer = await response.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  }

  @override
  Future<void> writeBytes(String relativePath, Uint8List bytes) async {
    final cache = await _cache;
    await cache.put(_key(relativePath).toJS, web.Response(bytes.toJS)).toDart;
  }

  @override
  Future<void> delete(String relativePath) async {
    final cache = await _cache;
    await cache.delete(_key(relativePath).toJS).toDart;
  }

  @override
  Future<void> activate() async {
    if (_activated) return;
    // Cache Storage needs no preparation; bytes are handed to the
    // speech workers directly by WebSpeechEngine.
    _activated = true;
  }
}

ModelStore createModelStore() => WebModelStore();
