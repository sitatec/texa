import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/constants.dart';

/// Downloads, extracts and verifies the on-device speech models once.
class ModelProvisioningService {
  Directory? _dir;
  Future<Directory> modelsDir() async {
    _dir ??= Directory(
      '${(await getApplicationSupportDirectory()).path}/models',
    );
    if (!await _dir!.exists()) await _dir!.create(recursive: true);
    return _dir!;
  }

  Future<bool> get isReady async {
    try {
      final d = await modelsDir();
      final m = File('${d.path}/models.json');
      if (!await m.exists()) return false;
      final j = jsonDecode(await m.readAsString()) as Map<String, dynamic>;
      return j['verified'] == true &&
          await File('${d.path}/kokoro-int8-multi-lang-v1_1/model.int8.onnx')
              .exists() &&
          await File('${d.path}/silero_vad.onnx').exists();
    } catch (_) {
      return false;
    }
  }

  Future<String> get kokoroDir async =>
      '${(await modelsDir()).path}/kokoro-int8-multi-lang-v1_1';
  Future<String> get vadPath async =>
      '${(await modelsDir()).path}/silero_vad.onnx';

  /// Downloads all three models, reporting (label, fraction) progress.
  Future<void> provision(
    void Function(String label, double fraction) onProgress,
  ) async {
    final d = await modelsDir();
    await _download(
      kokoroModelUrl,
      '${d.path}/kokoro.tar.bz2.part',
      'Kokoro voice',
      (f) => onProgress('Kokoro voice', f * 0.85),
    );
    onProgress('Kokoro voice', 0.87);
    final bytes = await File('${d.path}/kokoro.tar.bz2.part').readAsBytes();
    final archive = TarDecoder().decodeBytes(BZip2Decoder().decodeBytes(bytes));
    for (final file in archive) {
      final name = file.name.replaceAll('\\', '/');
      if (name.contains('..')) continue;
      final out = File('${d.path}/$name');
      if (file.isFile) {
        await out.parent.create(recursive: true);
        await out.writeAsBytes(file.content as List<int>);
      }
    }
    await File('${d.path}/kokoro.tar.bz2.part')
        .delete()
        .catchError((_) => File('${d.path}/kokoro.tar.bz2.part'));
    await _download(
      sileroVadModelUrl,
      '${d.path}/silero_vad.onnx',
      'Silero listening',
      (f) => onProgress('Silero listening', 0.9 + f * 0.06),
    );
    await _download(
      smartTurnModelUrl,
      '${d.path}/smart-turn-v3.2-int8.onnx',
      'Smart Turn',
      (f) => onProgress('Smart Turn', 0.96 + f * 0.04),
    ).catchError((_) {});
    for (final p in [
      '${d.path}/kokoro-int8-multi-lang-v1_1/model.int8.onnx',
      '${d.path}/kokoro-int8-multi-lang-v1_1/voices.bin',
      '${d.path}/kokoro-int8-multi-lang-v1_1/tokens.txt',
      '${d.path}/kokoro-int8-multi-lang-v1_1/lexicon-us-en.txt',
      '${d.path}/silero_vad.onnx',
    ]) {
      if (!await File(p).exists()) {
        throw StateError('A speech model file is missing after download: $p');
      }
    }
    await File('${d.path}/models.json').writeAsString(
      jsonEncode({
        'verified': true,
        'kokoro': kokoroModelUrl,
        'vad': sileroVadModelUrl,
        'installedAt': DateTime.now().toIso8601String(),
      }),
    );
    onProgress('Speech', 1);
  }

  Future<void> _download(
    String url,
    String dest,
    String label,
    void Function(double) onProgress,
  ) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url));
      final res = await client.send(req);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw StateError('Download failed for $label (${res.statusCode}).');
      }
      final total = res.contentLength ?? 0;
      var received = 0;
      final sink = File(dest).openWrite();
      await for (final chunk in res.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress(received / total);
      }
      await sink.close();
    } finally {
      client.close();
    }
  }
}
