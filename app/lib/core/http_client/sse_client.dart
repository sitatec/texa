import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';

import 'package:http/http.dart' as http;
import 'package:texa/core/http_client/http_client.dart';

/// Error thrown when an SSE endpoint answers with a non-200 status.
/// Carries the status and body so callers can map them to their own
/// user-facing errors instead of parsing an exception message.
class SseHttpException implements Exception {
  SseHttpException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  /// The `error.message` of a JSON error body, or the raw body.
  String get message {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map && error['message'] is String) {
          return error['message'] as String;
        }
        if (error is String && error.isNotEmpty) return error;
      }
    } catch (_) {
      // Not JSON: fall through to the raw body.
    }
    return body;
  }

  @override
  String toString() => 'HTTP $statusCode: $message';
}

/// A client for subscribing to Server-Sent Events (SSE).
///
/// Inspired by: https://github.com/sitatec/flutter_client_sse/blob/master/lib/flutter_client_sse.dart
///
/// The client never owns the transport: pass a shared `http.Client`
/// (e.g. one created by [TexaHttpClient.create]) and close that client
/// when it is no longer needed. Cancelling the returned stream's
/// subscription cancels the underlying response stream, and an
/// [abortTrigger] additionally rewrites the request as an
/// [http.AbortableRequest] so the transport itself can abort a request
/// that is still awaiting its first byte.
class SseClient {
  static final _logger = Logger('SseClient');
  final http.Client _client;
  final RegExp _sseLineRegex;

  SseClient({http.Client? client})
    : _client = client ?? TexaHttpClient.create(),
      _sseLineRegex = RegExp(r'^([^:]*)(?::)?(?: )?(.*)?$');

  /// Subscribe to Server-Sent Events.
  ///
  /// [method] is the request method (GET or POST).
  /// [url] is the URL of the SSE endpoint.
  /// [header] is a map of request headers.
  /// [body] is an optional request body for POST requests.
  /// [abortTrigger], when completed, aborts the in-flight request
  /// (where the transport honours [http.AbortableRequest]) and ends
  /// the stream without an event.
  ///
  /// Returns a [Stream] of [SseEvent] representing the SSE events.
  /// The request is only sent once the stream is listened to.
  Future<Stream<SseEvent>> subscribe({
    required SseRequestType method,
    required String url,
    Map<String, String>? header,
    Map<String, dynamic>? body,
    Future<void>? abortTrigger,
  }) async {
    late StreamController<SseEvent> streamController;
    StreamSubscription<String>? subscription;
    var cancelled = false;

    Future<void> cancelSubscription() async {
      final sub = subscription;
      subscription = null;
      try {
        await sub?.cancel();
      } catch (_) {
        // Tearing down an already-broken response stream must not
        // surface as a new error to the (former) listener.
      }
    }

    streamController = StreamController<SseEvent>(
      onListen: () async {
        http.BaseRequest request;
        if (abortTrigger != null) {
          request =
              http.AbortableRequest(
                  method == SseRequestType.get ? 'GET' : 'POST',
                  Uri.parse(url),
                  abortTrigger: abortTrigger,
                )
                ..headers.addAll(header ?? const {})
                ..bodyBytes = body == null
                    ? const []
                    : utf8.encode(jsonEncode(body));
        } else {
          final plain = http.Request(
            method == SseRequestType.get ? 'GET' : 'POST',
            Uri.parse(url),
          );
          header?.forEach((key, value) => plain.headers[key] = value);
          if (body != null) plain.body = jsonEncode(body);
          request = plain;
        }

        final http.StreamedResponse response;
        try {
          response = await _client.send(request);
        } catch (error, stackTrace) {
          // An abort surfaces here as an exception from the transport;
          // a cancelled listener neither needs nor can receive it.
          if (!cancelled && !streamController.isClosed) {
            streamController.addError(error, stackTrace);
            await streamController.close();
          }
          return;
        }
        if (cancelled) {
          // The listener went away while awaiting headers: drop the
          // response instead of streaming it into a dead controller.
          unawaited(response.stream.listen((_) {}).cancel().catchError((_) {}));
          return;
        }
        if (response.statusCode != 200) {
          final errorBody = await response.stream.bytesToString();
          if (!streamController.isClosed) {
            streamController.addError(
              SseHttpException(response.statusCode, errorBody),
            );
            await streamController.close();
          }
          return;
        }

        var currentSSEModel = SseEvent(data: '', id: '', event: '');
        subscription = response.stream
            .transform(const Utf8Decoder())
            .transform(const LineSplitter())
            .listen(
              (dataLine) {
                if (dataLine.isEmpty) {
                  // A blank line ends one event set: emit it.
                  if (currentSSEModel.data != null &&
                      currentSSEModel.data!.isNotEmpty) {
                    if (!streamController.isClosed) {
                      streamController.add(currentSSEModel);
                    }
                  }
                  currentSSEModel = SseEvent(data: '', id: '', event: '');
                  return;
                }
                _parseEvent(dataLine, currentSSEModel);
              },
              onDone: () {
                if (currentSSEModel.data != null &&
                    currentSSEModel.data!.isNotEmpty &&
                    !streamController.isClosed) {
                  streamController.add(currentSSEModel);
                }
                if (!streamController.isClosed) {
                  streamController.close();
                }
              },
              onError: (Object error, StackTrace stackTrace) {
                if (!streamController.isClosed) {
                  streamController.addError(error, stackTrace);
                  streamController.close();
                }
              },
            );
      },
      onCancel: () {
        cancelled = true;
        // Fire-and-forget, deliberately NOT awaited: if the request is
        // still awaiting response headers the subscription does not
        // exist yet, and returning that future would hold the
        // controller's done event hostage until it does.
        unawaited(cancelSubscription());
      },
    );

    return streamController.stream;
  }

  void _parseEvent(String dataLine, SseEvent currentSSEModel) {
    if (dataLine == ':keep-alive') {
      _logger.finest('Keep-alive event received');
      return;
    }
    final match = _sseLineRegex.firstMatch(dataLine);
    if (match == null) return;
    final field = match.group(1);
    if (field == null || field.isEmpty) return;

    final String value;
    if (field == 'data') {
      // `data:` is five characters; a following space is framing, not
      // content, and a bare `data` line carries no content at all.
      var rest = dataLine.length > 5 ? dataLine.substring(5) : '';
      if (rest.startsWith(' ')) rest = rest.substring(1);
      value = rest;
    } else {
      value = match.group(2) ?? '';
    }
    switch (field) {
      case 'event':
        currentSSEModel.event = value;
      case 'data':
        currentSSEModel.data = '${currentSSEModel.data ?? ''}$value\n';
      case 'id':
        currentSSEModel.id = value;
      default:
        _logger.warning('Unsupported field: $field');
    }
  }
}

enum SseRequestType { get, post }

/// Model for representing an SSE event.
class SseEvent {
  /// ID of the event.
  String? id = '';

  /// Event name.
  String? event = '';

  /// Event data.
  String? data = '';

  /// Constructor for SSE event.
  SseEvent({this.data, this.id, this.event});

  @override
  String toString() {
    return 'SseEvent{\n  id: $id, \n  event: $event, \n  data: $data\n}';
  }
}
