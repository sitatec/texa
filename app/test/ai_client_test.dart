import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:texa/core/data/models.dart';
import 'package:texa/features/study_session/ai/ai_client.dart';

void main() {
  /// Mock transport that captures the last request body and replies with
  /// the given SSE chunks / status.
  ({MockClient client, Map<String, dynamic> Function() lastBody}) harness({
    int statusCode = 200,
    String sse = 'data: [DONE]\n\n',
    String jsonBody = '{"object":"list","data":[]}',
  }) {
    Map<String, dynamic>? captured;
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        captured = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          sse,
          statusCode,
          headers: {'content-type': 'text/event-stream'},
        );
      }
      return http.Response(jsonBody, statusCode);
    });
    return (client: client, lastBody: () => captured!);
  }

  ChatMessage message(String role, Map<String, dynamic> payload) => ChatMessage(
    id: 'm-$role',
    sessionId: 's1',
    role: role,
    kind: 'text',
    payloadJson: jsonEncode(payload),
    createdAt: DateTime(2026),
  );

  Stream<AiEvent> turn(
    AiClient client, {
    List<AiUpload> uploads = const [],
    String? videoBase64,
    List<ChatMessage> history = const [],
  }) => client.streamTurn(
    model: 'test-model',
    history: history,
    registry: const {},
    uploads: uploads,
    videoBase64: videoBase64,
  );

  group('upload request parts', () {
    test('image, video, audio and document use different parts', () async {
      final h = harness(
        sse: 'data: {"type":"response.output_text.delta","delta":"hi"}\n\ndata: [DONE]\n\n',
      );
      final client = AiClient('key', client: h.client);
      await turn(
        client,
        videoBase64: 'BOARDVIDEO',
        uploads: const [
          AiUpload(name: 'pic.png', mimeType: 'image/png', base64: 'IMG'),
          AiUpload(name: 'clip.mp4', mimeType: 'video/mp4', base64: 'VID'),
          AiUpload(name: 'note.mp3', mimeType: 'audio/mpeg', base64: 'AUD'),
          AiUpload(
            name: 'sheet.pdf',
            mimeType: 'application/pdf',
            base64: 'PDF',
          ),
          AiUpload(
            name: 'readme.txt',
            mimeType: 'text/plain',
            text: 'hello doc',
          ),
          AiUpload(name: 'mystery.pdf', mimeType: 'application/pdf'),
        ],
      ).toList();

      final body = h.lastBody();
      expect(body['model'], 'test-model');
      expect(body['instructions'], contains('You are Texa'));
      final tools = body['tools'] as List;
      expect(tools, isNotEmpty);
      // Responses tools are flat: no nested `function` wrapper.
      expect((tools.first as Map)['type'], 'function');
      expect((tools.first as Map)['name'], 'write_text');
      expect((tools.first as Map).containsKey('function'), isFalse);
      expect(body['tool_choice'], 'auto');
      final input = body['input'] as List;
      final content = (input.last as Map)['content'] as List;
      expect(content.first['type'], 'input_text');
      // Text documents are inlined, byte-less files only mentioned.
      expect(content.first['text'], contains('hello doc'));
      expect(content.first['text'], contains('mystery.pdf'));
      expect(content[1], {
        'type': 'input_image',
        'image_url': 'data:image/png;base64,IMG',
      });
      expect(content[2], {
        'type': 'input_video',
        'video_url': 'data:video/mp4;base64,VID',
      });
      expect(content[3], {
        'type': 'input_audio',
        'input_audio': {'data': 'AUD', 'format': 'mp3'},
      });
      expect(content[4], {
        'type': 'input_file',
        'filename': 'sheet.pdf',
        'file_data': 'data:application/pdf;base64,PDF',
      });
      // The board turn-video stays a video part, after the uploads.
      expect(content[5], {
        'type': 'input_video',
        'video_url': 'data:video/mp4;base64,BOARDVIDEO',
      });
      expect(content, hasLength(6));
    });

    test('kind is derived from MIME type, then extension', () {
      expect(
        const AiUpload(name: 'a', mimeType: 'video/quicktime').kind,
        AiUploadKind.video,
      );
      expect(
        const AiUpload(
          name: 'a.wav',
          mimeType: 'application/octet-stream',
        ).kind,
        AiUploadKind.audio,
      );
      expect(
        const AiUpload(
          name: 'a.pdf',
          mimeType: 'application/octet-stream',
        ).kind,
        AiUploadKind.document,
      );
      expect(
        const AiUpload(name: 'a', mimeType: 'audio/x-wav').audioFormat,
        'wav',
      );
    });

    test(
      'history replays assistant tool calls as function_call items',
      () async {
        final h = harness(
          sse: 'data: {"type":"response.output_text.delta","delta":"ok"}\n\ndata: [DONE]\n\n',
        );
        final client = AiClient('key', client: h.client);
        await turn(
          client,
          history: [
            message('ai', {
              'text': 'Let me draw.',
              'toolCalls': [
                {
                  'name': 'write_text',
                  'args': {'element_id': 'title'},
                },
              ],
            }),
            message('user', {'text': 'thanks'}),
          ],
        ).toList();
        final body = h.lastBody();
        // System prompt travels in `instructions`, not as an input item.
        expect(body.containsKey('instructions'), isTrue);
        final input = body['input'] as List;
        final assistant = input[0] as Map;
        expect(assistant['role'], 'assistant');
        expect(assistant['content'], [
          {'type': 'output_text', 'text': 'Let me draw.'},
        ]);
        expect(input[1], {
          'type': 'function_call',
          'call_id': 'call_write_text',
          'name': 'write_text',
          'arguments': '{"element_id":"title"}',
        });
        expect((input[2] as Map)['content'], 'thanks');
      },
    );
  });

  group('streaming', () {
    String evt(Map<String, dynamic> e) => 'data: ${jsonEncode(e)}\n\n';

    test('emits text and each tool call as soon as it completes', () async {
      final sse = [
        evt({'type': 'response.output_text.delta', 'delta': 'Hello '}),
        evt({
          'type': 'response.function_call_arguments.delta',
          'item_id': 'fc1',
          'output_index': 1,
          'delta': '{"a":',
        }),
        evt({
          'type': 'response.function_call_arguments.delta',
          'item_id': 'fc1',
          'output_index': 1,
          'delta': '1}',
        }),
        evt({
          'type': 'response.output_item.done',
          'item': {
            'type': 'function_call',
            'id': 'fc1',
            'call_id': 'call_1',
            'name': 'write_text',
            'arguments': '{"a":1}',
          },
        }),
        evt({
          'type': 'response.output_item.done',
          'item': {
            'type': 'function_call',
            'id': 'fc2',
            'call_id': 'call_2',
            'name': 'point_at',
            'arguments': '{}',
          },
        }),
        evt({
          'type': 'response.completed',
          'response': {'output': []},
        }),
        'data: [DONE]\n\n',
      ].join();
      final h = harness(sse: sse);
      final events = await turn(AiClient('key', client: h.client)).toList();
      expect(
        events[0],
        isA<AiTextDelta>().having((e) => e.text, 'text', 'Hello '),
      );
      expect(
        events[1],
        isA<AiToolCallComplete>()
            .having((e) => e.name, 'name', 'write_text')
            .having((e) => e.args, 'args', {'a': 1}),
      );
      expect(
        events[2],
        isA<AiToolCallComplete>().having((e) => e.name, 'name', 'point_at'),
      );
      final done = events[3] as AiStreamDone;
      expect(done.fullText, 'Hello ');
      expect(done.raw['toolCalls'], hasLength(2));
    });

    test('429 maps to the busy message', () async {
      final h = harness(
        statusCode: 429,
        sse: '{"error":{"message":"slow down"}}',
      );
      await expectLater(
        turn(AiClient('key', client: h.client)).toList(),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('busy'),
          ),
        ),
      );
    });

    test('empty stream maps to the empty-reply message', () async {
      final h = harness();
      await expectLater(
        turn(AiClient('key', client: h.client)).toList(),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('empty reply'),
          ),
        ),
      );
    });
  });

  group('testConnection', () {
    test('succeeds on a 2xx models reply', () async {
      final h = harness();
      await AiClient('key', client: h.client).testConnection();
    });

    test('401 maps to the rejected-key message', () async {
      final h = harness(
        statusCode: 401,
        jsonBody: '{"error":{"message":"bad key"}}',
      );
      await expectLater(
        AiClient('key', client: h.client).testConnection(),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('not accepted'),
          ),
        ),
      );
    });
  });
}
