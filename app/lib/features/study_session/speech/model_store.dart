import 'dart:typed_data';

import 'model_store_stub.dart'
    if (dart.library.io) 'model_store_io.dart'
    if (dart.library.js_interop) 'model_store_web.dart'
    as impl;


int getOptimalThreads({int maxThreads = 4}) => impl.getOptimalThreadsImpl(maxThreads);

/// Where downloaded speech-model files live.
///
/// Native platforms keep real files under the app-support directory.
/// The web has no app-support directory (and `path_provider` throws
/// there), so on web the files persist in the browser Cache Storage
/// and are copied into sherpa-onnx's WASM filesystem by [activate],
/// which is what makes the usual model paths readable by the engine.
abstract interface class ModelStore {
  /// Path sherpa-onnx should be given for [relativePath]. Only valid
  /// after [activate] (or any other store call) has completed.
  String pathFor(String relativePath);

  Future<bool> exists(String relativePath);
  Future<Uint8List?> readBytes(String relativePath);
  Future<void> writeBytes(String relativePath, Uint8List bytes);
  Future<void> delete(String relativePath);

  /// Prepares the store for reads by the speech engine. Native: makes
  /// sure the models directory exists. Web: loads the sherpa WASM
  /// module and copies every persisted file into its filesystem.
  Future<void> activate();
}

ModelStore createModelStore() => impl.createModelStore();
