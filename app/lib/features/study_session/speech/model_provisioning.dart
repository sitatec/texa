import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

import '../../../core/constants.dart';
import 'model_store.dart';

/// Downloads, extracts and verifies the on-device speech models once.
///
/// File storage is delegated to a [ModelStore]: real files under the
/// app-support directory on native platforms, browser Cache Storage
/// (copied into sherpa-onnx's WASM filesystem) on web — `path_provider`
/// has no app-support directory on web and throws there.
class ModelProvisioningService {
  ModelProvisioningService({ModelStore? store, http.Client? client})
    : _store = store ?? createModelStore(),
      _client = client ?? http.Client();
  final ModelStore _store;
  final http.Client _client;

  static const _kokoroDirName = 'kokoro-int8-multi-lang-v1_1';

  Future<bool> get isReady async {
    try {
      final meta = await _store.readBytes('models.json');
      if (meta == null) return false;
      final j = jsonDecode(utf8.decode(meta)) as Map<String, dynamic>;
      return j['verified'] == true &&
          await _store.exists('$_kokoroDirName/model.int8.onnx') &&
          await _store.exists('silero_vad.onnx');
    } catch (_) {
      return false;
    }
  }

  Future<String> get kokoroDir async {
    await _store.activate();
    return _store.pathFor(_kokoroDirName);
  }

  Future<String> get vadPath async {
    await _store.activate();
    return _store.pathFor('silero_vad.onnx');
  }

  /// Downloads all three models, reporting (label, fraction) progress.
  Future<void> provision(
    void Function(String label, double fraction) onProgress,
  ) async {
    await _store.activate();
    final kokoroArchive = await _download(
      kokoroModelUrl,
      'Kokoro voice',
      (f) => onProgress('Kokoro voice', f * 0.85),
    );
    onProgress('Kokoro voice', 0.87);
    final archive = TarDecoder().decodeBytes(
      BZip2Decoder().decodeBytes(kokoroArchive),
    );
    for (final file in archive) {
      final name = file.name.replaceAll('\\', '/');
      if (name.contains('..') || !file.isFile) continue;
      await _store.writeBytes(
        name,
        Uint8List.fromList(file.content as List<int>),
      );
    }
    await _store.writeBytes(
      'silero_vad.onnx',
      await _download(
        sileroVadModelUrl,
        'Silero listening',
        (f) => onProgress('Silero listening', 0.9 + f * 0.06),
      ),
    );
    try {
      await _store.writeBytes(
        'smart-turn-v3.2-int8.onnx',
        await _download(
          smartTurnModelUrl,
          'Smart Turn',
          (f) => onProgress('Smart Turn', 0.96 + f * 0.04),
        ),
      );
    } catch (_) {
      // Smart Turn is an optional refinement; VAD alone still works.
    }
    for (final p in [
      '$_kokoroDirName/model.int8.onnx',
      '$_kokoroDirName/voices.bin',
      '$_kokoroDirName/tokens.txt',
      '$_kokoroDirName/lexicon-us-en.txt',
      'silero_vad.onnx',
    ]) {
      if (!await _store.exists(p)) {
        throw StateError(
          'A speech model file is missing after download: ${_store.pathFor(p)}',
        );
      }
    }
    await _store.writeBytes(
      'models.json',
      utf8.encode(
        jsonEncode({
          'verified': true,
          'kokoro': kokoroModelUrl,
          'vad': sileroVadModelUrl,
          'installedAt': DateTime.now().toIso8601String(),
        }),
      ),
    );
    onProgress('Speech', 1);
  }

  Future<Uint8List> _download(
    String url,
    String label,
    void Function(double) onProgress,
  ) async {
    final res = await _client.send(http.Request('GET', Uri.parse(url)));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('Download failed for $label (${res.statusCode}).');
    }
    final total = res.contentLength ?? 0;
    var received = 0;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res.stream) {
      builder.add(chunk);
      received += chunk.length;
      if (total > 0) onProgress(received / total);
    }
    return builder.takeBytes();
  }
}
