import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:texa/features/study_session/speech/model_provisioning.dart';
import 'package:texa/features/study_session/speech/model_store.dart';

class _FakeStore implements ModelStore {
  final files = <String, Uint8List>{};
  bool activated = false;

  @override
  String pathFor(String relativePath) => '/models/$relativePath';
  @override
  Future<bool> exists(String relativePath) async =>
      files.containsKey(relativePath);
  @override
  Future<Uint8List?> readBytes(String relativePath) async =>
      files[relativePath];
  @override
  Future<void> writeBytes(String relativePath, Uint8List bytes) async {
    files[relativePath] = bytes;
  }

  @override
  Future<void> delete(String relativePath) async {
    files.remove(relativePath);
  }

  @override
  Future<void> activate() async {
    activated = true;
  }
}

Uint8List _kokoroTarBz2() {
  final archive = Archive();
  for (final name in [
    'model.int8.onnx',
    'voices.bin',
    'tokens.txt',
    'lexicon-us-en.txt',
  ]) {
    archive.addFile(
      ArchiveFile('kokoro-int8-multi-lang-v1_1/$name', 4, utf8.encode('fake')),
    );
  }
  final tar = TarEncoder().encodeBytes(archive);
  return Uint8List.fromList(BZip2Encoder().encodeBytes(tar));
}

void main() {
  test(
    'provision downloads, extracts and verifies the speech models',
    () async {
      final store = _FakeStore();
      final tarBytes = _kokoroTarBz2();
      final client = MockClient((request) async {
        final url = request.url.toString();
        if (url.contains('kokoro')) {
          return http.Response.bytes(tarBytes, 200);
        }
        if (url.contains('silero_vad')) {
          return http.Response.bytes([1, 2, 3], 200);
        }
        return http.Response.bytes([4, 5], 200);
      });
      final service = ModelProvisioningService(store: store, client: client);

      expect(await service.isReady, isFalse);
      final progress = <double>[];
      await service.provision((_, f) => progress.add(f));

      expect(store.activated, isTrue);
      expect(await service.isReady, isTrue);
      expect(
        store.files.keys,
        contains('kokoro-int8-multi-lang-v1_1/model.int8.onnx'),
      );
      expect(store.files['silero_vad.onnx'], [1, 2, 3]);
      expect(progress.last, 1);
      expect(await service.kokoroDir, endsWith('kokoro-int8-multi-lang-v1_1'));
      expect(await service.vadPath, endsWith('silero_vad.onnx'));
    },
  );

  test('provision fails loudly when an archive member is missing', () async {
    final store = _FakeStore();
    final archive = Archive()
      ..addFile(
        ArchiveFile('kokoro-int8-multi-lang-v1_1/model.int8.onnx', 1, [0]),
      );
    final tarBytes = Uint8List.fromList(
      BZip2Encoder().encodeBytes(TarEncoder().encodeBytes(archive)),
    );
    final client = MockClient((request) async {
      if (request.url.toString().contains('kokoro')) {
        return http.Response.bytes(tarBytes, 200);
      }
      return http.Response.bytes([1], 200);
    });
    final service = ModelProvisioningService(store: store, client: client);
    await expectLater(service.provision((_, _) {}), throwsA(isA<StateError>()));
    expect(await service.isReady, isFalse);
  });
}
