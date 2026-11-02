import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:texa/features/study_session/ai/ai_client.dart';

/// Transport whose [send] (awaiting response headers: the request is
/// still reaching the server, or the model is still thinking and has
/// produced nothing) only completes when [release] fires.
class BlockingClient extends http.BaseClient {
  final Completer<void> release = Completer<void>();
  http.BaseRequest? lastRequest;
  var sendCalled = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sendCalled = true;
    lastRequest = request;
    await release.future;
    return http.StreamedResponse(
      Stream.fromIterable([
        'data: {"type":"response.output_text.delta","delta":"hi"}\n\n'
            .codeUnits,
      ]),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }

  @override
  void close() {}
}

void main() {
  test('close ends a turn blocked awaiting the first response', () async {
    final transport = BlockingClient();
    final client = AiClient('key', client: transport);
    final events = <AiEvent>[];
    final done = client
        .streamTurn(model: 'm', history: const [], videoBase64: 'V')
        .listen(events.add)
        .asFuture<void>();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(transport.sendCalled, isTrue);
    // The in-flight request must be abortable (package:http's
    // AbortSignal equivalent), wired to this client's close.
    expect(transport.lastRequest, isA<http.Abortable>());
    client.close();
    // Must end promptly, not when the server eventually responds.
    await done.timeout(const Duration(seconds: 2));
    expect(events, isEmpty);
    transport.release.complete();
  });
}
