import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:texa/features/study_session/speech/model_provisioning.dart';
import 'package:texa/features/study_session/speech/model_store/model_store.dart';
import 'package:texa/core/data/models.dart';

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
  Future<void> activate([Iterable<String> files = const []]) async {
    activated = true;
  }
}

void main() {
  test('provision downloads and verifies the speech models', () async {
    final store = _FakeStore();
    final requested = <String>[];
    final client = MockClient((request) async {
      final url = request.url.toString();
      requested.add(url);
      if (url.contains('kokoro-multi-lang-v1_0')) {
        return http.Response.bytes(
          utf8.encode('fake:${request.url.pathSegments.last}'),
          200,
        );
      }
      if (url.contains('silero_vad')) {
        return http.Response.bytes([1, 2, 3], 200);
      }
      return http.Response.bytes([4, 5], 200);
    });
    final service = ModelProvisioningService(store: store, client: client);

    expect(await service.isReadyFor(TtsEngine.kokoro), isFalse);
    final progress = <double>[];
    await service.provision((_, f) => progress.add(f));

    expect(store.activated, isTrue);
    expect(await service.isReadyFor(TtsEngine.kokoro), isTrue);
    expect(await service.isReadyFor(TtsEngine.piper), isFalse);
    // Each Kokoro file used by the TTS worker is fetched individually
    // from the base URL, with the (non-int8) model name.
    expect(requested.where((u) => u.contains('kokoro-multi-lang-v1_0')), [
      endsWith('/model.onnx'),
      endsWith('/voices.bin'),
      endsWith('/tokens.txt'),
      endsWith('/lexicon-en-us.txt'),
    ]);
    expect(
      store.files.keys,
      containsAll([
        'kokoro-multi-lang-v1_0/model.onnx',
        'kokoro-multi-lang-v1_0/voices.bin',
        'kokoro-multi-lang-v1_0/tokens.txt',
        'kokoro-multi-lang-v1_0/lexicon-en-us.txt',
      ]),
    );
    expect(store.files['silero_vad.onnx'], [1, 2, 3]);
    expect(progress.last, 1);
    expect(await service.kokoroDir, endsWith('kokoro-multi-lang-v1_0'));
    expect(await service.vadPath, endsWith('silero_vad.onnx'));
  });

  test(
    'provision with Piper downloads only Piper plus the shared lexicon',
    () async {
      final store = _FakeStore();
      final requested = <String>[];
      final client = MockClient((request) async {
        requested.add(request.url.toString());
        return http.Response.bytes([1], 200);
      });
      final service = ModelProvisioningService(store: store, client: client);

      await service.provision((_, _) {}, engine: TtsEngine.piper);

      expect(await service.isReadyFor(TtsEngine.piper), isTrue);
      expect(await service.isReadyFor(TtsEngine.kokoro), isFalse);
      expect(
        requested,
        containsAll([
          endsWith('vits-piper-en_US-amy-medium/resolve/main/model.onnx'),
          endsWith('vits-piper-en_US-amy-medium/resolve/main/tokens.txt'),
          endsWith('kokoro-multi-lang-v1_0/resolve/main/lexicon-en-us.txt'),
        ]),
      );
      // No Kokoro model/voices are fetched for a Piper install.
      expect(requested.where((u) => u.contains('kokoro-multi-lang')), [
        endsWith('/lexicon-en-us.txt'),
      ]);
      final paths = await service.ttsPathsFor(TtsEngine.piper);
      expect(paths.model, endsWith('vits-piper-en_US-amy-medium/model.onnx'));
      expect(paths.voices, isNull);
      expect(paths.tokens, endsWith('vits-piper-en_US-amy-medium/tokens.txt'));
      expect(
        paths.lexicon,
        endsWith('kokoro-multi-lang-v1_0/lexicon-en-us.txt'),
      );
    },
  );

  test(
    'provision fails loudly when a Kokoro file cannot be downloaded',
    () async {
      final store = _FakeStore();
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/tokens.txt')) {
          return http.Response.bytes([], 404);
        }
        return http.Response.bytes([1], 200);
      });
      final service = ModelProvisioningService(store: store, client: client);
      await expectLater(
        service.provision((_, _) {}),
        throwsA(isA<StateError>()),
      );
      expect(await service.isReadyFor(TtsEngine.kokoro), isFalse);
    },
  );
}
