import 'package:fetch_client/fetch_client.dart';
import 'package:http/http.dart';

Future<void> setupInternal() async {}

Client createHttpClient({String? userAgent}) => _FetchClientWithDefaultHeaders(userAgent: userAgent);

class _FetchClientWithDefaultHeaders extends FetchClient {
  final String? userAgent;

  _FetchClientWithDefaultHeaders({this.userAgent}) : super(cache: RequestCache.byDefault, mode: RequestMode.cors);

  @override
  Future<FetchResponse> send(BaseRequest request) {
    if (userAgent != null) {
      request.headers['User-Agent'] = userAgent!;
    }
    return super.send(request);
  }
}
