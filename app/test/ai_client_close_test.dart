import 'dart:async';
import 'dart:convert';

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
  var closed = false;

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
  void close() => closed = true;
}

/// Transport that, like a real `http.Client`, refuses to send once
/// closed - and counts how often it was closed.
class ReuseClient extends http.BaseClient {
  var closed = false;
  var sends = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (closed) {
      throw http.ClientException('Client is already closed.', request.url);
    }
    sends++;
    // Drain the request body like a real transport would.
    await request.finalize().toList();
    const sse =
        'data: {"type":"response.output_text.delta","delta":"hi"}\n\n'
        'data: [DONE]\n\n';
    return http.StreamedResponse(
      Stream.fromIterable([utf8.encode(sse)]),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }

  @override
  void close() => closed = true;
}

void main() {
  test('cancelTurn ends a turn blocked awaiting the first response, '
      'without closing the client', () async {
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
    // AbortSignal equivalent), wired to this turn's cancellation.
    expect(transport.lastRequest, isA<http.Abortable>());
    client.cancelTurn();
    // Must end promptly, not when the server eventually responds.
    await done.timeout(const Duration(seconds: 2));
    expect(events, isEmpty);
    // Interruption is not disposal: the transport stays open.
    expect(transport.closed, isFalse);
    transport.release.complete();
    client.close();
    expect(transport.closed, isTrue);
  });

  test('one client serves turn after turn, including after a '
      'cancelled turn', () async {
    final transport = ReuseClient();
    final client = AiClient('key', client: transport);

    for (var i = 0; i < 2; i++) {
      final events = await client
          .streamTurn(model: 'm', history: const [], videoBase64: 'V')
          .toList();
      expect(events.whereType<AiTextDelta>().single.text, 'hi');
      expect(events.last, isA<AiStreamDone>());
    }
    expect(transport.sends, 2);
    expect(transport.closed, isFalse);

    // A cancelled turn must not poison the next one.
    final cancelled = client
        .streamTurn(model: 'm', history: const [], videoBase64: 'V')
        .toList();
    client.cancelTurn();
    // The mock answers instantly, so the turn may legitimately have
    // finished before the cancel landed; either way, the next turn
    // must work on the same client.
    await cancelled;
    final events = await client
        .streamTurn(model: 'm', history: const [], videoBase64: 'V')
        .toList();
    expect(events.last, isA<AiStreamDone>());
    expect(transport.closed, isFalse);
    client.close();
  });

  test('cancelTurn does not cancel a background transcription', () async {
    final release = Completer<void>();
    var sends = 0;
    final transport = _TranscriptionGateClient(release);
    final client = AiClient('key', client: transport);

    final transcription = client.transcribeVideo(model: 'm', videoBase64: 'V');
    // Wait until the transcription request is actually in flight.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(transport.sends, greaterThan(0));
    sends = transport.sends;
    client.cancelTurn();
    release.complete();
    await expectLater(transcription, completion('SPEECH: hi'));
    expect(sends, greaterThan(0));
    client.close();
  });
}

class _TranscriptionGateClient extends http.BaseClient {
  _TranscriptionGateClient(this.release);
  final Completer<void> release;
  var sends = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sends++;
    await request.finalize().toList();
    await release.future;
    final body = jsonEncode({
      'type': 'response.output_text.delta',
      'delta': '```transcript\nSPEECH: hi\n```',
    });
    return http.StreamedResponse(
      Stream.fromIterable([utf8.encode('data: $body\n\ndata: [DONE]\n\n')]),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }

  @override
  void close() {}
}
