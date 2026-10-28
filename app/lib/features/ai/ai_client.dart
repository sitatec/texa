import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../data/models.dart';
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

/// Direct streaming client to the fixed Meta AI endpoint.
class AiClient {
  AiClient(this.apiKey, {http.Client? client})
    : _client = client ?? http.Client();
  final String apiKey;
  final http.Client _client;
  Map<String, String> get _headers => {
    'Authorization': 'Bearer $apiKey',
    'Content-Type': 'application/json',
  };
  void close() => _client.close();

  /// Minimal authenticated request used by Test connection.
  Future<void> testConnection() async {
    try {
      final r = await _client
          .get(Uri.parse('$apiBaseUrl/models'), headers: _headers)
          .timeout(const Duration(seconds: connectTimeoutSeconds));
      if (r.statusCode >= 200 && r.statusCode < 300) return;
      if (r.statusCode == 401 || r.statusCode == 403) {
        throw const AppError(
          'That API key was not accepted. Check it and try again.',
        );
      }
      throw AppError(
        'Connection failed (${r.statusCode}). Check your connection and try again.',
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

  /// Fetches available model ids for the picker.
  Future<List<String>> listModels() async {
    final r = await _client
        .get(Uri.parse('$apiBaseUrl/models'), headers: _headers)
        .timeout(const Duration(seconds: connectTimeoutSeconds));
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw AppError(
        'Could not load models (${r.statusCode}). You can type a model name instead.',
      );
    }
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return ((j['data'] as List?) ?? [])
        .map((e) => (e as Map<String, dynamic>)['id'].toString())
        .toList();
  }

  Map<String, dynamic> _requestBody({
    required String model,
    required List<ChatMessage> history,
    required Map<String, AiElementInfo> registry,
    String? videoBase64,
    String? typedText,
    Map<String, dynamic>? interruptionContext,
    String? subject,
    required bool stream,
    String studentMemory = '',
    List<SessionObservation> recentObservations = const [],
    String currentObservation = '',
    List<({String name, String mimeType, String? base64, String? text})>
        uploads =
        const [],
    String? extraContext,
  }) {
    final system = StringBuffer(kSystemPrompt);
    if (studentMemory.trim().isNotEmpty) {
      system.write(
        '\n\nWhat you remember about this student: ${studentMemory.trim()}',
      );
    }
    if (recentObservations.isNotEmpty) {
      system.write('\n\nObservations from recent sessions (newest first):');
      for (final o in recentObservations) {
        system.write(
          '\n[${o.date.toIso8601String().substring(0, 10)}] ${o.content}',
        );
      }
    }
    if (currentObservation.trim().isNotEmpty) {
      system.write(
        '\n\nThis session\'s observation so far: ${currentObservation.trim()}',
      );
    }
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': system.toString()},
    ];
    for (final m in history) {
      if (m.role == 'ai') {
        final p = m.payload;
        final msg = <String, dynamic>{
          'role': 'assistant',
          'content': p['text'] ?? '',
        };
        final calls = p['toolCalls'];
        if (calls is List && calls.isNotEmpty) {
          msg['tool_calls'] = calls.map((c) {
            final cm = c as Map<String, dynamic>;
            return {
              'id': cm['id'] ?? 'call_${cm['name']}',
              'type': 'function',
              'function': {
                'name': cm['name'],
                'arguments': jsonEncode(cm['args'] ?? {}),
              },
            };
          }).toList();
        }
        messages.add(msg);
      } else if ((m.payload['text'] as String?)?.isNotEmpty == true) {
        messages.add({'role': 'user', 'content': m.payload['text']});
      }
    }
    final regText = registry.isEmpty
        ? 'You have not drawn anything yet in this session.'
        : 'Your existing board elements (id, type, x, y, width, height): ${registry.values.map((e) => '${e.id} ${e.kind} ${e.rect.left.round()},${e.rect.top.round()} ${e.rect.width.round()}x${e.rect.height.round()}').join('; ')}';
    final context = StringBuffer(
      'Board: 1200x1600. ${subject != null ? 'Subject: $subject. ' : ''}$regText',
    );
    if (interruptionContext != null) {
      context.write(
        ' Interruption context: ${jsonEncode(interruptionContext)}',
      );
    }
    if (typedText != null && typedText.isNotEmpty) {
      context.write(' The student typed: $typedText');
    }
    if (extraContext != null && extraContext.isNotEmpty) {
      context.write(' $extraContext');
    }
    for (final u in uploads) {
      if (u.text != null && u.text!.isNotEmpty) {
        context.write(
          '\nThe student uploaded a file named ${u.name}:\n${u.text}',
        );
      } else if (u.base64 == null) {
        context.write(
          '\nThe student attached a file named ${u.name} (${u.mimeType}).',
        );
      }
    }
    final content = <Map<String, dynamic>>[
      {'type': 'text', 'text': context.toString()},
      ...uploads
          .where((u) => u.base64 != null)
          .map(
            (u) => {
              'type': 'image_url',
              'image_url': {'url': 'data:${u.mimeType};base64,${u.base64}'},
            },
          ),
      if (videoBase64 != null)
        {
          'type': 'video_url',
          'video_url': {'url': 'data:video/mp4;base64,$videoBase64'},
        },
    ];
    messages.add({'role': 'user', 'content': content});
    return {
      'model': model,
      'messages': messages,
      'tools': toolSchemas(),
      'tool_choice': 'auto',
      'stream': stream,
    };
  }

  /// Streams one turn: text deltas and completed tool calls are emitted as
  /// soon as they arrive; [AiStreamDone] carries the full raw reply for saving.
  Stream<AiEvent> streamTurn({
    required String model,
    required List<ChatMessage> history,
    required Map<String, AiElementInfo> registry,
    String? videoBase64,
    String? typedText,
    Map<String, dynamic>? interruptionContext,
    String? subject,
    String studentMemory = '',
    List<SessionObservation> recentObservations = const [],
    String currentObservation = '',
    List<({String name, String mimeType, String? base64, String? text})>
        uploads =
        const [],
    String? extraContext,
  }) async* {
    final request =
        http.Request('POST', Uri.parse('$apiBaseUrl/chat/completions'))
          ..headers.addAll(_headers)
          ..body = jsonEncode(
            _requestBody(
              model: model,
              history: history,
              registry: registry,
              videoBase64: videoBase64,
              typedText: typedText,
              interruptionContext: interruptionContext,
              subject: subject,
              stream: true,
              studentMemory: studentMemory,
              recentObservations: recentObservations,
              currentObservation: currentObservation,
              uploads: uploads,
              extraContext: extraContext,
            ),
          );
    http.StreamedResponse response;
    try {
      response = await _client
          .send(request)
          .timeout(const Duration(seconds: connectTimeoutSeconds));
    } catch (e) {
      throw AppError(
        'Could not reach Meta AI. Check your connection and retry your turn.',
        cause: e,
      );
    }
    if (response.statusCode == 429) {
      throw const AppError(
        'Meta AI is busy right now. Wait a moment, then retry your turn.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.stream.bytesToString();
      throw AppError(
        'Meta AI rejected that turn (${response.statusCode}). ${body.length > 140 ? '' : body} Your work is safe on the board.',
      );
    }
    final fullText = StringBuffer();
    final toolBuffers = <int, ({String name, StringBuffer args})>{};
    final completedCalls = <({String name, Map<String, dynamic> args})>[];
    final emittedTools = <int>{};
    var sawEvent = false;
    await for (final chunk
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .timeout(const Duration(seconds: responseTimeoutSeconds))) {
      if (!chunk.startsWith('data:')) continue;
      final data = chunk.substring(5).trim();
      if (data.isEmpty || data == '[DONE]') continue;
      Map<String, dynamic> j;
      try {
        j = jsonDecode(data) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      sawEvent = true;
      final choices = j['choices'] as List? ?? [];
      if (choices.isEmpty) continue;
      final delta =
          (choices.first as Map<String, dynamic>)['delta']
              as Map<String, dynamic>? ??
          {};
      final text = delta['content'] as String?;
      if (text != null && text.isNotEmpty) {
        fullText.write(text);
        yield AiTextDelta(text);
      }
      for (final c in (delta['tool_calls'] as List? ?? [])) {
        final cm = c as Map<String, dynamic>;
        final index = (cm['index'] as num?)?.toInt() ?? toolBuffers.length;
        // A new tool index means every earlier call is complete: emit it now
        // so drawing can start while the rest of the reply still streams.
        for (final prev
            in toolBuffers.entries
                .where((e) => e.key < index && !emittedTools.contains(e.key))
                .toList()
              ..sort((a, b) => a.key.compareTo(b.key))) {
          if (prev.value.name.isEmpty) continue;
          emittedTools.add(prev.key);
          final a = decodeArgs(prev.value.args.toString());
          completedCalls.add((name: prev.value.name, args: a));
          yield AiToolCallComplete(prev.value.name, a);
        }
        final fn = cm['function'] as Map<String, dynamic>? ?? {};
        final buf = toolBuffers.putIfAbsent(
          index,
          () => (name: '', args: StringBuffer()),
        );
        final name = (fn['name'] as String?) ?? '';
        final merged = (
          name: name.isNotEmpty ? name : buf.name,
          args: buf.args,
        );
        toolBuffers[index] = merged;
        final argsFrag = fn['arguments'] as String?;
        if (argsFrag != null) merged.args.write(argsFrag);
      }
      final finish =
          (choices.first as Map<String, dynamic>)['finish_reason'] as String?;
      if (finish == 'tool_calls' || finish == 'stop') {
        // Tool calls are complete at finish; emit any not yet emitted below.
      }
    }
    if (!sawEvent) {
      throw const AppError(
        'Meta AI returned an empty reply. Please retry your turn.',
      );
    }
    final sorted = toolBuffers.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    for (final e in sorted) {
      if (e.value.name.isEmpty || emittedTools.contains(e.key)) continue;
      final args = decodeArgs(e.value.args.toString());
      completedCalls.add((name: e.value.name, args: args));
      yield AiToolCallComplete(e.value.name, args);
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
