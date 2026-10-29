import 'dart:async';
import 'dart:convert';

import 'package:dart_openai/dart_openai.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../core/constants.dart';
import '../../../core/errors.dart';
import '../../../core/data/models.dart';
import '../board/board_models.dart';
import 'ai_actions.dart';
import 'system_prompt.dart';

/// One event from the streamed AI reply.
sealed class AiEvent {}

class AiTextDelta extends AiEvent {
  AiTextDelta(this.text);
  final String text;
}

class AiToolCallComplete extends AiEvent {
  AiToolCallComplete(this.name, this.args);
  final String name;
  final Map<String, dynamic> args;
}

class AiStreamDone extends AiEvent {
  AiStreamDone(this.raw, this.fullText);
  final Map<String, dynamic> raw;
  final String fullText;
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
    required Map<String, AiElementInfo> registry,
    String? videoBase64,
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
          for (final c in calls) {
            final cm = c as Map<String, dynamic>;
            input.add({
              'type': 'function_call',
              'call_id': cm['id'] ?? 'call_${cm['name']}',
              'name': cm['name'],
              'arguments': jsonEncode(cm['args'] ?? {}),
            });
          }
        }
      } else if ((m.payload['text'] as String?)?.isNotEmpty == true) {
        input.add({'role': 'user', 'content': m.payload['text'] as String});
      }
    }

    final regText = registry.isEmpty
        ? 'You have not drawn anything yet in this session.'
        : 'Your existing board elements (id, type, x, y, width, height): ${registry.values.map((e) => '${e.id} ${e.kind} ${e.rect.left.round()},${e.rect.top.round()} ${e.rect.width.round()}x${e.rect.height.round()}').join('; ')}';
    final context = StringBuffer(
      'Board: ${boardWidth.toInt()}x${boardHeight.toInt()}. $regText',
    );
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
    if (videoBase64 != null) {
      // The board turn-video is a video, not an image.
      parts.add({
        'type': 'input_video',
        'video_url': 'data:video/mp4;base64,$videoBase64',
      });
    }
    input.add({'role': 'user', 'content': parts});
    return (instructions: instructions.toString(), input: input);
  }

  /// Streams one turn: text deltas and completed tool calls are emitted as
  /// soon as they arrive; [AiStreamDone] carries the full raw reply for saving.
  Stream<AiEvent> streamTurn({
    required String model,
    required List<ChatMessage> history,
    required Map<String, AiElementInfo> registry,
    String? videoBase64,
    Map<String, dynamic>? interruptionContext,
    String studentMemory = '',
    List<SessionObservation> recentObservations = const [],
    String currentObservation = '',
    List<AiUpload> uploads = const [],
    String? extraContext,
    String? reasoningEffort,
  }) async* {
    final request = _requestInput(
      history: history,
      registry: registry,
      videoBase64: videoBase64,
      interruptionContext: interruptionContext,
      studentMemory: studentMemory,
      recentObservations: recentObservations,
      currentObservation: currentObservation,
      uploads: uploads,
      extraContext: extraContext,
    );
    final fullText = StringBuffer();
    final argBuffers = <String, StringBuffer>{};
    final callNames = <String, String>{};
    final callOrder = <String>[];
    final completedCalls = <({String name, Map<String, dynamic> args})>[];
    final emittedTools = <String>{};
    var sawEvent = false;

    void registerCall(String key, String? name) {
      if (!argBuffers.containsKey(key)) {
        argBuffers[key] = StringBuffer();
        callOrder.add(key);
      }
      if (name != null && name.isNotEmpty) callNames[key] = name;
    }

    AiToolCallComplete? finishCall(String key) {
      if (emittedTools.contains(key)) return null;
      final name = callNames[key] ?? '';
      if (name.isEmpty) return null;
      emittedTools.add(key);
      final args = decodeArgs(argBuffers[key]?.toString() ?? '');
      completedCalls.add((name: name, args: args));
      return AiToolCallComplete(name, args);
    }

    try {
      await for (final event
          in _openAi.responses
              .createStream(
                model: model,
                instructions: request.instructions,
                input: request.input,
                tools: toolSchemas(),
                toolChoice: 'auto',
                reasoning: reasoningEffort == null
                    ? null
                    : {'effort': reasoningEffort},
                client: _client,
              )
              .timeout(const Duration(seconds: responseTimeoutSeconds))) {
        sawEvent = true;
        switch (event['type']) {
          case 'response.output_text.delta':
            final delta = event['delta'];
            if (delta is String && delta.isNotEmpty) {
              fullText.write(delta);
              yield AiTextDelta(delta);
            }
          case 'response.function_call_arguments.delta':
            final key = (event['item_id'] ?? event['output_index'] ?? '')
                .toString();
            registerCall(key, null);
            final delta = event['delta'];
            if (delta is String) argBuffers[key]!.write(delta);
          case 'response.function_call_arguments.done':
            final key = (event['item_id'] ?? event['output_index'] ?? '')
                .toString();
            registerCall(key, event['name'] as String?);
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
              registerCall(key, item['name'] as String?);
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
            // Fallback: emit any function calls the terminal event carries
            // that were not already completed mid-stream.
            final response = event['response'];
            final output = response is Map ? response['output'] : null;
            if (output is List) {
              for (final item in output) {
                if (item is Map && item['type'] == 'function_call') {
                  final key = (item['id'] ?? item['call_id'] ?? '').toString();
                  registerCall(key, item['name'] as String?);
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
    final raw = <String, dynamic>{
      'text': fullText.toString(),
      'toolCalls': completedCalls
          .map((c) => {'name': c.name, 'args': c.args})
          .toList(),
    };
    yield AiStreamDone(raw, fullText.toString());
  }
}
