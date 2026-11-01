import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../core/constants.dart';
import '../../../core/data/models.dart';
import 'model_store.dart';

/// Downloads and verifies the on-device speech models once.
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

  static const _kokoroDirName = 'kokoro-multi-lang-v1_0';

  /// The Kokoro files the TTS worker actually loads (see `tts_worker.dart`),
  /// downloaded individually from [kokoroBaseUrl] instead of extracting
  /// them from a `.tar.bz2` archive at runtime. The lexicon matches the
  /// worker's default `languageCode`.
  static const _kokoroFiles = [
    'model.onnx',
    'voices.bin',
    'tokens.txt',
    'lexicon-en-us.txt',
  ];

  static const _piperDirName = 'vits-piper-en_US-hfc_female-medium';

  /// The Piper files downloaded from [piperBaseUrl]. Piper reuses
  /// Kokoro's lexicon (see [_kokoroFiles]), so it is not listed here.
  static const _piperFiles = ['model.onnx', 'tokens.txt'];

  Future<bool> get _verified async {
    try {
      final meta = await _store.readBytes('models.json');
      if (meta == null) return false;
      final j = jsonDecode(utf8.decode(meta)) as Map<String, dynamic>;
      return j['verified'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Whether the models for [engine] (plus the shared VAD) are installed.
  Future<bool> isReadyFor(TtsEngine engine) async {
    if (!await _verified || !await _store.exists('silero_vad.onnx')) {
      return false;
    }
    return switch (engine) {
      TtsEngine.kokoro => _allExist(_kokoroDirName, _kokoroFiles),
      TtsEngine.piper =>
        await _allExist(_piperDirName, _piperFiles) &&
            await _store.exists('$_kokoroDirName/lexicon-en-us.txt'),
    };
  }

  Future<bool> _allExist(String dir, List<String> files) async {
    for (final file in files) {
      if (!await _store.exists('$dir/$file')) return false;
    }
    return true;
  }

  /// Whether the Silero VAD model is installed, regardless of which
  /// TTS engine is currently selected/downloaded.
  Future<bool> get isVadReady async =>
      await _verified && await _store.exists('silero_vad.onnx');

  Future<String> get kokoroDir async {
    await _store.activate();
    return _store.pathFor(_kokoroDirName);
  }

  Future<String> get piperDir async {
    await _store.activate();
    return _store.pathFor(_piperDirName);
  }

  /// Model file paths the TTS worker loads for [engine]. Piper's
  /// lexicon is the shared Kokoro one.
  Future<({String model, String? voices, String tokens, String lexicon})>
  ttsPathsFor(TtsEngine engine) async {
    await _store.activate();
    final lexicon = _store.pathFor('$_kokoroDirName/lexicon-en-us.txt');
    return switch (engine) {
      TtsEngine.kokoro => (
        model: _store.pathFor('$_kokoroDirName/model.onnx'),
        voices: _store.pathFor('$_kokoroDirName/voices.bin'),
        tokens: _store.pathFor('$_kokoroDirName/tokens.txt'),
        lexicon: lexicon,
      ),
      TtsEngine.piper => (
        model: _store.pathFor('$_piperDirName/model.onnx'),
        voices: null,
        tokens: _store.pathFor('$_piperDirName/tokens.txt'),
        lexicon: lexicon,
      ),
    };
  }

  Future<String> get vadPath async {
    await _store.activate();
    return _store.pathFor('silero_vad.onnx');
  }

  Future<String> get smartTurnPath async {
    await _store.activate();
    return _store.pathFor('smart-turn-v3.2-int8.onnx');
  }

  /// Downloads the speech models for [engine], reporting
  /// (label, fraction) progress. Only the selected engine's files are
  /// fetched (plus the shared lexicon/VAD), so switching engines in
  /// Settings downloads just the missing engine on first use.
  Future<void> provision(
    void Function(String label, double fraction) onProgress, {
    TtsEngine engine = TtsEngine.kokoro,
  }) async {
    await _store.activate();
    // (store path, download URL, label) for every file this engine needs.
    final downloads = switch (engine) {
      TtsEngine.kokoro => [
        for (final file in _kokoroFiles)
          (
            '$_kokoroDirName/$file',
            '${_base(kokoroBaseUrl)}$file',
            'Kokoro voice',
          ),
      ],
      TtsEngine.piper => [
        for (final file in _piperFiles)
          (
            '$_piperDirName/$file',
            '${_base(piperBaseUrl)}$file',
            'Piper voice',
          ),
        (
          '$_kokoroDirName/lexicon-en-us.txt',
          '${_base(kokoroBaseUrl)}lexicon-en-us.txt',
          'Piper voice',
        ),
      ],
    };
    for (var i = 0; i < downloads.length; i++) {
      final (path, url, label) = downloads[i];
      // Already-downloaded files (e.g. the shared lexicon) are kept.
      if (await _store.exists(path)) {
        onProgress(label, 0.9 * (i + 1) / downloads.length);
        continue;
      }
      await _store.writeBytes(
        path,
        await _download(
          url,
          label,
          (f) => onProgress(label, 0.9 * (i + f) / downloads.length),
        ),
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
      for (final (path, _, _) in downloads) path,
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
          'kokoro': _base(kokoroBaseUrl),
          'piper': _base(piperBaseUrl),
          'engine': engine.name,
          'vad': sileroVadModelUrl,
          'installedAt': DateTime.now().toIso8601String(),
        }),
      ),
    );
    onProgress('Speech', 1);
  }

  static String _base(String url) => url.endsWith('/') ? url : '$url/';

  Future<Uint8List> _download(
    String url,
    String label,
    void Function(double) onProgress,
  ) async {
    if (kDebugMode && defaultTargetPlatform == .android) {
      url = url.replaceFirst('localhost', '10.0.2.2');
    }

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
