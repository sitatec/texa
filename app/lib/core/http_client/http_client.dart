import 'dart:async';

import 'package:http/http.dart';

import '_http_client_factory.dart'
    if (dart.library.js_interop) '_http_client_factory_web.dart';

/// A singleton instance of [Client] that is used to make HTTP requests.
abstract class TexaHttpClient {
  static Future<void> setup() => setupInternal();

  static Client create() => createHttpClient();
}
