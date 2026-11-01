import 'dart:async';
import 'dart:convert';

import 'package:dart_openai/dart_openai.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../core/constants.dart';
import '../../../core/errors.dart';
import '../../../core/data/models.dart';
import 'ai_actions.dart';
import 'system_prompt.dart';

/// One event from the streamed AI reply.
sealed class AiEvent {}

class AiTextDelta extends AiEvent {
  AiTextDelta(this.text);
  final String text;
}

class AiToolCallComplete extends AiEvent {
  AiToolCallComplete(this.name, this.args, {this.callId = ''});
  final String name;
  final Map<String, dynamic> args;

  /// The Responses API `call_id` this call must be answered with. It is
  /// not the stream item id; a `function_call_output` sent back with any
  /// other id is rejected by the API.
  final String callId;
}

class AiStreamDone extends AiEvent {
  AiStreamDone(this.raw, this.fullText, {this.responseId});
  final Map<String, dynamic> raw;
  final String fullText;

  /// Id of the final stored response of this turn. Persisted in the AI
  /// message payload (inside [raw] as `responseId`) so the next turn can
  /// chain onto it with `previous_response_id` instead of replaying the
  /// whole history.
  final String? responseId;
}

/// Outcome of performing one tool call, reported back to the model as a
/// plain-text `function_call_output` (never multimodal content).
class AiToolResult {
  const AiToolResult._(this.success, this.output);
  const AiToolResult.success([String output = '']) : this._(true, output);
  const AiToolResult.failure(String output) : this._(false, output);

  final bool success;
  final String output;

  /// Wire shape of the output: a small JSON status envelope so the model
  /// can tell a performed action from a failed one at a glance.
  String get wireOutput => jsonEncode({
    'status': success ? 'success' : 'error',
    if (output.isNotEmpty) 'detail': output,
  });
}

/// Performs one tool call the model asked for and reports its outcome.
/// Supplied by the session controller, which owns the board/playback the
/// tools act on; [AiClient] awaits it inside the agentic loop before the
/// result is sent back to the model.
typedef AiToolExecutor = Future<AiToolResult> Function(
  String name,
  Map<String, dynamic> args,
);

/// Internal terminal event of one streamed response inside the agentic
/// loop; never leaves [AiClient.streamTurn].
class _ResponseRound extends AiEvent {
  _ResponseRound({
    required this.responseId,
    required this.text,
    required this.calls,
  });
  final String? responseId;
  final String text;
  final List<({String callId, String name, Map<String, dynamic> args})> calls;
}

/// The media family of an [AiUpload], decided from its MIME type (falling
/// back to the file-name extension for generic/binary MIME types).
enum AiUploadKind { image, video, audio, document }

/// One file the student attached to a turn.
///
/// Exactly one payload should be set: [text] for text-like documents, whose
/// contents are inlined into the request as text, or [base64] for binary
/// media (image, video, audio and non-text documents), which is sent as a
/// media part whose shape depends on [kind]. With neither set, only the
/// file's name and MIME type are mentioned to the model.
class AiUpload {
  const AiUpload({
    required this.name,
    required this.mimeType,
    this.base64,
    this.text,
  });

  final String name;
  final String mimeType;
  final String? base64;
  final String? text;

  AiUploadKind get kind {
    final mime = mimeType.toLowerCase();
    if (mime.startsWith('image/')) return AiUploadKind.image;
    if (mime.startsWith('video/')) return AiUploadKind.video;
    if (mime.startsWith('audio/')) return AiUploadKind.audio;
    if (mime.startsWith('text/') ||
        mime == 'application/json' ||
        mime == 'application/pdf') {
      return AiUploadKind.document;
    }
    // Generic MIME (e.g. application/octet-stream): trust the extension.
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'png' ||
      'jpg' ||
      'jpeg' ||
      'gif' ||
      'webp' ||
      'bmp' ||
      'heic' => AiUploadKind.image,
      'mp4' || 'mov' || 'webm' || 'mkv' => AiUploadKind.video,
      'mp3' ||
      'wav' ||
      'm4a' ||
      'ogg' ||
      'flac' ||
      'mpeg' => AiUploadKind.audio,
      _ => AiUploadKind.document,
    };
  }

  bool get hasText => text != null && text!.isNotEmpty;
  bool get hasBase64 => base64 != null && base64!.isNotEmpty;

  /// Format token for an `input_audio` part (e.g. `mp3` for audio/mpeg).
  String get audioFormat {
    final subtype = mimeType.toLowerCase().split('/').last.split(';').first;
    return switch (subtype) {
      'mpeg' || 'mp3' => 'mp3',
      'wav' || 'x-wav' || 'wave' => 'wav',
      'mp4' || 'x-m4a' || 'm4a' => 'm4a',
      _ => subtype.replaceFirst('x-', ''),
    };
  }

  String get dataUri => 'data:$mimeType;base64,$base64';
}

/// Direct streaming client to the fixed Meta AI endpoint, backed by the
/// fully-typed `dart_openai` client ([OpenAIClient]).
class AiClient {
  AiClient(this.apiKey, {http.Client? client})
    : _client = client ?? http.Client(),
      _openAi = OpenAIClient(
        apiKey: apiKey,
        baseUrl: _baseUrl.baseUrl,
        version: _baseUrl.version,
        requestsTimeOut: const Duration(seconds: connectTimeoutSeconds),
        // Preserve the previous single-attempt behaviour: a failed turn is
        // surfaced (and retried by the student) instead of silently resent.
        retryPolicy: OpenAIRetryPolicy.none,
      );

  final String apiKey;
  final http.Client _client;
  final OpenAIClient _openAi;

  /// `dart_openai` joins `baseUrl/version/endpoint`, while [apiBaseUrl]
  /// already contains the version segment (`https://api.meta.ai/v1`).
  static ({String baseUrl, String version}) get _baseUrl {
    final uri = Uri.parse(apiBaseUrl);
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return (baseUrl: apiBaseUrl, version: 'v1');
    final origin = Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    ).toString();
    return (baseUrl: origin, version: segments.last);
  }

  void close() => _client.close();

  /// The id of the most recent stored response in [history], or null when
  /// no AI message carries one (a brand-new or pre-`store` session). The
  /// id only ever lives in the saved AI messages' payloads; it is read
  /// back from there so it survives restarts with the rest of the history.
  static String? latestResponseId(List<ChatMessage> history) {
    for (final m in history.reversed) {
      if (m.role != 'ai') continue;
      final id = m.payload['responseId'];
      if (id is String && id.isNotEmpty) return id;
    }
    return null;
  }

  /// Minimal authenticated request used by Test connection.
  Future<void> testConnection() async {
    try {
      await _openAi.model
          .list(client: _client)
          .timeout(const Duration(seconds: connectTimeoutSeconds));
    } on RequestFailedException catch (e) {
      if (e.statusCode == 401 || e.statusCode == 403) {
        throw const AppError(
          'That API key was not accepted. Check it and try again.',
        );
      }
      throw AppError(
        'Connection failed (${e.statusCode}). Check your connection and try again.',
        cause: e,
      );
    } on AppError {
      rethrow;
    } catch (e) {
      throw AppError(
        'Could not reach Meta AI. Check your connection and try again.',
        cause: e,
      );
    }
  }

  /// Builds the Responses API request payload for one turn: the system
  /// prompt becomes `instructions`, the history and this turn's uploads
  /// become `input` items. Media parts use the Responses content shapes:
  /// `input_image` (data URI), `input_video` (data URI), `input_audio`
  /// (base64 + format) and `input_file` (filename + base64 data URI).
  ({String instructions, List<Map<String, dynamic>> input}) _requestInput({
    required List<ChatMessage> history,
    required String videoBase64,
    bool includeHistory = true,
    Map<String, dynamic>? interruptionContext,
    String studentMemory = '',
    List<SessionObservation> recentObservations = const [],
    String currentObservation = '',
    List<AiUpload> uploads = const [],
    String? extraContext,
  }) {
    final instructions = StringBuffer(kSystemPrompt);
    if (studentMemory.trim().isNotEmpty) {
      instructions.write(
        '\n\nWhat you remember about this student: ${studentMemory.trim()}',
      );
    }
    if (recentObservations.isNotEmpty) {
      instructions.write(
        '\n\nObservations from recent sessions (newest first):',
      );
      for (final o in recentObservations) {
        instructions.write(
          '\n[${o.date.toIso8601String().substring(0, 10)}] ${o.content}',
        );
      }
    }
    if (currentObservation.trim().isNotEmpty) {
      instructions.write(
        '\n\nThis session\'s observation so far: ${currentObservation.trim()}',
      );
    }

    final input = <Map<String, dynamic>>[];
    // With a stored previous response the server already holds the whole
    // conversation, so only this turn's new input is sent. The full
    // replay below is only the bootstrap for sessions that have no
    // stored response id yet (new or legacy sessions).
    if (includeHistory) {
      for (final m in history) {
        if (m.role == 'ai') {
          final p = m.payload;
          final text = (p['text'] as String? ?? '').trim();
          if (text.isNotEmpty) {
            input.add({
              'role': 'assistant',
              'content': [
                {'type': 'output_text', 'text': text},
              ],
            });
          }
          final calls = p['toolCalls'];
          if (calls is List) {
            for (var i = 0; i < calls.length; i++) {
              final cm = calls[i] as Map<String, dynamic>;
              // Every replayed function_call must be answered by a
              // matching function_call_output, or the API rejects the
              // whole request ("No tool output found for function call
              // ..."). Legacy messages saved no result, so a stored
              // outcome is replayed when present and a plain success is
              // synthesised otherwise - the action did happen on the
              // board back then. Call ids also have to be unique, hence
              // the index on the synthesised fallback.
              final callId = cm['id'] as String? ?? 'call_${cm['name']}_$i';
              input.add({
                'type': 'function_call',
                'call_id': callId,
                'name': cm['name'],
                'arguments': jsonEncode(cm['args'] ?? {}),
              });
              final storedOutput = cm['output'];
              input.add({
                'type': 'function_call_output',
                'call_id': callId,
                'output': storedOutput is String && storedOutput.isNotEmpty
                    ? storedOutput
                    : const AiToolResult.success().wireOutput,
              });
            }
          }
        } else if ((m.payload['text'] as String?)?.isNotEmpty == true) {
          input.add({'role': 'user', 'content': m.payload['text'] as String});
        }
      }
    }

    final context = StringBuffer();
    if (interruptionContext != null) {
      context.write(
        ' Interruption context: ${jsonEncode(interruptionContext)}',
      );
    }
    if (extraContext != null && extraContext.isNotEmpty) {
      context.write(' $extraContext');
    }
    for (final u in uploads) {
      if (u.hasText) {
        context.write(
          '\nThe student uploaded a file named ${u.name}:\n${u.text}',
        );
      } else if (!u.hasBase64) {
        context.write(
          '\nThe student attached a file named ${u.name} (${u.mimeType}).',
        );
      }
    }

    final parts = <Map<String, dynamic>>[
      if (context.isNotEmpty)
        {'type': 'input_text', 'text': context.toString()},
    ];
    for (final u in uploads.where((u) => u.hasBase64 && !u.hasText)) {
      switch (u.kind) {
        case AiUploadKind.image:
          parts.add({'type': 'input_image', 'image_url': u.dataUri});
        case AiUploadKind.video:
          parts.add({'type': 'input_video', 'video_url': u.dataUri});
        case AiUploadKind.audio:
          parts.add({
            'type': 'input_audio',
            'input_audio': {'data': u.base64, 'format': u.audioFormat},
          });
        case AiUploadKind.document:
          parts.add({
            'type': 'input_file',
            'filename': u.name,
            'file_data': u.dataUri,
          });
      }
    }
    // The board turn-video is a video, not an image.
    parts.add({
      'type': 'input_video',
      'video_url': 'data:video/mp4;base64,$videoBase64',
    });
    input.add({'role': 'user', 'content': parts});
    return (instructions: instructions.toString(), input: input);
  }

  /// Streams one turn, running the agentic tool loop when
  /// [executeToolCall] is given.
  ///
  /// Every request is sent with `store: true`. When a previous stored
  /// response is known (passed explicitly or found in the saved AI
  /// messages in [history]) only this turn's new input plus
  /// `previous_response_id` is sent - the history itself is never
  /// replayed. Each response that asks for tool calls has every call
  /// performed through [executeToolCall] and its outcome sent straight
  /// back as a `function_call_output` chained on that response's id, so
  /// the model can keep calling tools step by step (draw, look at the
  /// result, explain, draw more) until it answers with no further calls.
  /// Without an executor the turn stays a single request, as before.
  /// [AiStreamDone] is emitted once, at the very end, and carries the
  /// final response id for the caller to persist with the AI message.
  Stream<AiEvent> streamTurn({
    required String model,
    required List<ChatMessage> history,
    required String videoBase64,
    Map<String, dynamic>? interruptionContext,
    String studentMemory = '',
    List<SessionObservation> recentObservations = const [],
    String currentObservation = '',
    List<AiUpload> uploads = const [],
    String? extraContext,
    String? reasoningEffort,
    String? previousResponseId,
    AiToolExecutor? executeToolCall,
    int maxToolRounds = 10,
  }) async* {
    var previousId = previousResponseId ?? latestResponseId(history);
    final request = _requestInput(
      history: history,
      videoBase64: videoBase64,
      interruptionContext: interruptionContext,
      studentMemory: studentMemory,
      recentObservations: recentObservations,
      currentObservation: currentObservation,
      uploads: uploads,
      extraContext: extraContext,
      includeHistory: previousId == null,
    );

    final fullText = StringBuffer();
    final allCalls = <Map<String, dynamic>>[];
    final responseIds = <String>[];
    List<Map<String, dynamic>> nextInput = request.input;
    var wrapUpNext = false;

    for (var round = 0; ; round++) {
      final allowTools = !wrapUpNext;
      _ResponseRound? completed;
      await for (final event in _streamOneResponse(
        model: model,
        instructions: request.instructions,
        input: nextInput,
        previousResponseId: previousId,
        reasoningEffort: reasoningEffort,
        allowTools: allowTools,
      )) {
        if (event is _ResponseRound) {
          completed = event;
        } else {
          yield event;
        }
      }
      final result = completed!;
      if (result.responseId != null && result.responseId!.isNotEmpty) {
        previousId = result.responseId;
        responseIds.add(result.responseId!);
      }
      fullText.write(result.text);
      if (result.calls.isEmpty || wrapUpNext) break;

      final roundCalls = <Map<String, dynamic>>[];
      for (final call in result.calls) {
        final entry = <String, dynamic>{
          if (call.callId.isNotEmpty) 'id': call.callId,
          'name': call.name,
          'args': call.args,
        };
        roundCalls.add(entry);
        allCalls.add(entry);
      }
      // No executor: keep the old single-request behaviour. The calls
      // were still streamed above so the caller can perform them; only
      // the chained follow-up request is skipped.
      if (executeToolCall == null) break;

      // Perform every call in the order the model issued it and answer
      // each one before the next request goes out. Outcomes are plain
      // text only - no board screenshots or other multimodal payloads.
      final outputs = <Map<String, dynamic>>[];
      for (final call in result.calls) {
        AiToolResult outcome;
        try {
          outcome = await executeToolCall(call.name, call.args);
        } catch (e) {
          debugPrint('Failed to execute tool call $call: $e');
          outcome = AiToolResult.failure(
            'The action failed: ${e.toString().substring(0, 200)}',
          );
        }
        final entry = roundCalls.firstWhere(
          (c) => call.callId.isNotEmpty
              ? c['id'] == call.callId
              : c['name'] == call.name && !c.containsKey('output'),
        );
        entry['status'] = outcome.success ? 'success' : 'error';
        entry['output'] = outcome.wireOutput;
        outputs.add({
          'type': 'function_call_output',
          'call_id': call.callId.isNotEmpty ? call.callId : 'call_${call.name}',
          'output': outcome.wireOutput,
        });
      }
      // Safety valve: after too many tool rounds, one last request with
      // tools disabled lets the model wrap up in words instead of
      // looping (or leaving its last calls unanswered) forever.
      if (round >= maxToolRounds) wrapUpNext = true;
      nextInput = outputs;
    }

    final raw = <String, dynamic>{
      'text': fullText.toString(),
      'toolCalls': allCalls,
      'responseId': previousId,
      'responseIds': responseIds,
    };
    yield AiStreamDone(raw, fullText.toString(), responseId: previousId);
  }

  /// Streams a single Responses API request (`store: true`, chained on
  /// [previousResponseId] when given) and finishes with a
  /// [_ResponseRound] describing the completed response: its id, its
  /// full text and every function call it asked for, with real call ids.
  Stream<AiEvent> _streamOneResponse({
    required String model,
    required String instructions,
    required List<Map<String, dynamic>> input,
    required String? previousResponseId,
    required String? reasoningEffort,
    required bool allowTools,
  }) async* {
    final fullText = StringBuffer();
    final argBuffers = <String, StringBuffer>{};
    final callNames = <String, String>{};
    final callIds = <String, String>{};
    final callOrder = <String>[];
    final completedCalls =
        <({String callId, String name, Map<String, dynamic> args})>[];
    final emittedTools = <String>{};
    String? responseId;
    var sawEvent = false;

    void registerCall(String key, String? name, String? callId) {
      if (!argBuffers.containsKey(key)) {
        argBuffers[key] = StringBuffer();
        callOrder.add(key);
      }
      if (name != null && name.isNotEmpty) callNames[key] = name;
      if (callId != null && callId.isNotEmpty) callIds[key] = callId;
    }

    AiToolCallComplete? finishCall(String key) {
      if (emittedTools.contains(key)) return null;
      final name = callNames[key] ?? '';
      if (name.isEmpty) return null;
      emittedTools.add(key);
      final args = decodeArgs(argBuffers[key]?.toString() ?? '');
      final callId = callIds[key] ?? '';
      completedCalls.add((callId: callId, name: name, args: args));
      return AiToolCallComplete(name, args, callId: callId);
    }

    void captureResponseId(dynamic event) {
      final response = event is Map ? event['response'] : null;
      if (response is Map) {
        final id = response['id'];
        if (id is String && id.isNotEmpty) responseId = id;
      }
    }

    try {
      await for (final event
          in _openAi.responses
              .createStream(
                model: model,
                instructions: instructions,
                input: input,
                store: true,
                previousResponseId: previousResponseId,
                tools: toolSchemas(),
                toolChoice: allowTools ? 'auto' : 'none',
                reasoning: reasoningEffort == null
                    ? null
                    : {'effort': reasoningEffort},
                client: _client,
              )
              .timeout(const Duration(seconds: responseTimeoutSeconds))) {
        sawEvent = true;
        switch (event['type']) {
          case 'response.created' || 'response.in_progress':
            captureResponseId(event);
          case 'response.output_text.delta':
            final delta = event['delta'];
            if (delta is String && delta.isNotEmpty) {
              fullText.write(delta);
              yield AiTextDelta(delta);
            }
          case 'response.function_call_arguments.delta':
            final key = (event['item_id'] ?? event['output_index'] ?? '')
                .toString();
            registerCall(key, null, event['call_id'] as String?);
            final delta = event['delta'];
            if (delta is String) argBuffers[key]!.write(delta);
          case 'response.function_call_arguments.done':
            final key = (event['item_id'] ?? event['output_index'] ?? '')
                .toString();
            registerCall(
              key,
              event['name'] as String?,
              event['call_id'] as String?,
            );
            final args = event['arguments'];
            if (args is String && args.isNotEmpty) {
              argBuffers[key]
                ?..clear()
                ..write(args);
            }
            final done = finishCall(key);
            if (done != null) yield done;
          case 'response.output_item.done':
            final item = event['item'];
            if (item is Map && item['type'] == 'function_call') {
              final key = (item['id'] ?? item['call_id'] ?? '').toString();
              registerCall(
                key,
                item['name'] as String?,
                item['call_id'] as String?,
              );
              final args = item['arguments'];
              if (args is String && args.isNotEmpty) {
                argBuffers[key]
                  ?..clear()
                  ..write(args);
              }
              final done = finishCall(key);
              if (done != null) yield done;
            }
          case 'response.completed':
            captureResponseId(event);
            // Fallback: emit any function calls the terminal event carries
            // that were not already completed mid-stream.
            final response = event['response'];
            final output = response is Map ? response['output'] : null;
            if (output is List) {
              for (final item in output) {
                if (item is Map && item['type'] == 'function_call') {
                  final key = (item['id'] ?? item['call_id'] ?? '').toString();
                  registerCall(
                    key,
                    item['name'] as String?,
                    item['call_id'] as String?,
                  );
                  final args = item['arguments'];
                  if (args is String && args.isNotEmpty) {
                    argBuffers[key]
                      ?..clear()
                      ..write(args);
                  }
                  final done = finishCall(key);
                  if (done != null) yield done;
                }
              }
            }
          case 'response.failed' || 'error':
            final error = event['response'] is Map
                ? (event['response'] as Map)['error']
                : event['error'];
            final message = error is Map
                ? (error['message'] as String? ?? '')
                : '';
            throw AppError(
              'Meta AI rejected that turn. ${message.length > 140 ? '' : message} Your work is safe on the board.',
            );
        }
      }
    } on RequestFailedException catch (e) {
      debugPrint(e.message);
      if (e.statusCode == 429) {
        throw const AppError(
          'Meta AI is busy right now. Wait a moment, then retry your turn.',
        );
      }
      throw AppError(
        'Meta AI rejected that turn (${e.statusCode}). ${e.message.length > 140 ? '' : e.message} Your work is safe on the board.',
        cause: e,
      );
    } on TimeoutException catch (e) {
      throw AppError(
        'Meta AI took too long to reply. Please retry your turn.',
        cause: e,
      );
    } on AppError {
      rethrow;
    } catch (e) {
      debugPrint("Meta AI API call failed: $e");
      throw AppError(
        'Could not reach Meta AI. Check your connection and retry your turn.',
        cause: e,
      );
    }
    if (!sawEvent) {
      throw const AppError(
        'Meta AI returned an empty reply. Please retry your turn.',
      );
    }
    for (final key in callOrder) {
      final done = finishCall(key);
      if (done != null) yield done;
    }
    yield _ResponseRound(
      responseId: responseId,
      text: fullText.toString(),
      calls: completedCalls,
    );
  }
}
