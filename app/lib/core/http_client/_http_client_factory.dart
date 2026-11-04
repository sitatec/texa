import 'dart:io';

import 'package:cronet_http/cronet_http.dart';
import 'package:cupertino_http/cupertino_http.dart';
import 'package:http/http.dart';
import 'package:http/io_client.dart';
import 'package:path_provider/path_provider.dart';

const _diskCacheMaxSize = 100 * 1024 * 1024; // 100 MB
Directory? _cacheDir;

Future<void> setupInternal() async {
  if (Platform.isAndroid) {
    _cacheDir = await getApplicationCacheDirectory();
  }
}

Client createHttpClient({String? userAgent}) {
  // We disable cache for the client, we will used a dedicated cache library to have more control instead.
  if (Platform.isAndroid) {
    if (_cacheDir == null) {
      throw StateError(
        "Httpp client not setup properly, please call TexaHttpClient.setup first",
      );
    }

    final cronetPath = Directory('${_cacheDir!.path}/cronet_cache')
      ..createSync(recursive: true);

    final engine = CronetEngine.build(
      cacheMode: CacheMode.disk,
      storagePath: cronetPath.path,
      cacheMaxSize: _diskCacheMaxSize,
      enableQuic: true,
      enableHttp2: true,
      enableBrotli: true,
      userAgent: userAgent,
    );
    return CronetClient.fromCronetEngine(engine, closeEngine: true);
  }

  if (Platform.isIOS || Platform.isMacOS) {
    final config = URLSessionConfiguration.defaultSessionConfiguration()
      ..cache = URLCache.withCapacity(
        diskCapacity: _diskCacheMaxSize,
        memoryCapacity: 2 * 1024 * 1024,
      )
      // dart http client doesn't have default timeout and the only way to set timeout is by using the timeout() method
      // from the Future returned by the http client. Since the cupertino client has a default timeout of 60s we increase it
      // So that we will set timeout following the http package way.
      ..timeoutIntervalForRequest = const Duration(minutes: 10)
      ..httpAdditionalHeaders = userAgent != null
          ? {'User-Agent': userAgent}
          : null;
    return CupertinoClient.fromSessionConfiguration(config);
  }

  final client = HttpClient()
    ..userAgent = userAgent
    // Same reason as for the cupertino client above
    ..idleTimeout = Duration(minutes: 10);
  return IOClient(client);
}
