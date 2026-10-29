import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:web/web.dart' as web;

import 'model_store.dart';

/// Web model store.
///
/// Downloaded files persist in the browser Cache Storage (survives
/// reloads, unlike a plain download on every visit). sherpa-onnx's
/// WASM engine reads plain paths from its in-memory filesystem, so
/// [activate] loads the WASM module and copies the persisted files
/// into that filesystem under `/texa-models/...`; those virtual paths
/// are what [pathFor] hands to the engine.
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
    // If the WASM filesystem is already live, keep it in sync too.
    if (_activated) _writeToFileSystem(pathFor(relativePath), bytes);
  }

  @override
  Future<void> delete(String relativePath) async {
    final cache = await _cache;
    await cache.delete(_key(relativePath).toJS).toDart;
  }

  @override
  Future<void> activate() async {
    if (_activated) return;
    await sherpa.initBindingsAsync();
    final cache = await _cache;
    final requests = (await cache.keys().toDart).toDart;
    for (final request in requests) {
      final path = Uri.parse(request.url).path;
      if (!path.startsWith('$_root/')) continue;
      final relativePath = Uri.decodeComponent(
        path.substring(_root.length + 1),
      );
      final bytes = await readBytes(relativePath);
      if (bytes != null) _writeToFileSystem(path, bytes);
    }
    _activated = true;
  }

  JSObject? get _fileSystem {
    final module = globalContext.getProperty('Module'.toJS);
    if (module == null || !module.isA<JSObject>()) return null;
    final fs = (module as JSObject).getProperty('FS'.toJS);
    return fs != null && fs.isA<JSObject>() ? fs as JSObject : null;
  }

  void _writeToFileSystem(String path, Uint8List bytes) {
    final fs = _fileSystem;
    if (fs == null) return;
    try {
      if (_fileSystemHas(fs, path, bytes.length)) return;
      var current = '';
      final segments = path.split('/').where((e) => e.isNotEmpty).toList();
      for (final segment in segments.take(segments.length - 1)) {
        current += '/$segment';
        try {
          fs.callMethod('mkdir'.toJS, current.toJS);
        } catch (_) {
          // Already exists.
        }
      }
      fs.callMethod('writeFile'.toJS, path.toJS, bytes.toJS);
    } catch (_) {
      // The engine will fail loudly on init if a file is truly missing;
      // persistence in Cache Storage is unaffected.
    }
  }

  bool _fileSystemHas(JSObject fs, String path, int size) {
    try {
      final stat = fs.callMethod('stat'.toJS, path.toJS);
      if (stat == null || !stat.isA<JSObject>()) return false;
      final sizeProp = (stat as JSObject).getProperty('size'.toJS);
      return sizeProp != null &&
          sizeProp.isA<JSNumber>() &&
          (sizeProp as JSNumber).toDartInt == size;
    } catch (_) {
      return false;
    }
  }
}

ModelStore createModelStore() => WebModelStore();
