import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'model_store.dart';

int getOptimalThreadsImpl(int maxThreads) {
  return min(max(1, Platform.numberOfProcessors), maxThreads);
}

/// Native model store: plain files under the app-support directory.
class IoModelStore implements ModelStore {
  Directory? _dir;

  Future<Directory> _root() async {
    if (_dir == null) {
      _dir = Directory(
        '${(await getApplicationSupportDirectory()).path}/models',
      );
      if (!await _dir!.exists()) await _dir!.create(recursive: true);
    }
    return _dir!;
  }

  Future<File> _file(String relativePath) async =>
      File('${(await _root()).path}/$relativePath');

  @override
  String pathFor(String relativePath) => '${_dir!.path}/$relativePath';

  @override
  Future<bool> exists(String relativePath) async =>
      (await _file(relativePath)).exists();

  @override
  Future<Uint8List?> readBytes(String relativePath) async {
    final f = await _file(relativePath);
    return await f.exists() ? f.readAsBytes() : null;
  }

  @override
  Future<void> writeBytes(String relativePath, Uint8List bytes) async {
    final f = await _file(relativePath);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<void> delete(String relativePath) async {
    final f = await _file(relativePath);
    if (await f.exists()) await f.delete();
  }

  @override
  Future<void> activate() async {
    await _root();
  }
}

ModelStore createModelStore() => IoModelStore();
