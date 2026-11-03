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
    uploads: uploads,
    videoBase64: videoBase64 ?? '',
  );

  group('turn contract', () {
    test('prior (superseded) videos precede the current board video', () async {
      final h = harness(
        sse: 'data: {"type":"response.output_text.delta","delta":"hi"}\n\ndata: [DONE]\n\n',
      );
      final client = AiClient('key', client: h.client);
      await client
          .streamTurn(
            model: 'test-model',
            history: const [],
            videoBase64: 'BOARDVIDEO',
            priorVideosBase64: const ['OLDVIDEO'],
          )
          .toList();
      final input = h.lastBody()['input'] as List;
      final content = (input.last as Map)['content'] as List;
      final videos = content
          .where((c) => c['type'] == 'input_video')
          .map((c) => c['video_url'])
          .toList();
      expect(videos, [
        'data:video/mp4;base64,OLDVIDEO',
        'data:video/mp4;base64,BOARDVIDEO',
      ]);
    });
  });

  group('video window and transcription', () {
    ChatMessage videoTurn(int n, {String? transcript}) {
      return ChatMessage(
        id: 's$n',
        sessionId: 's1',
        role: 'student',
        kind: 'video-turn',
        payloadJson: jsonEncode({
          'hasVideo': true,
          'videoBase64': 'V$n',
          'transcript': ?transcript,
          'transcriptionStatus': ?(transcript == null ? null : 'done'),
        }),
        createdAt: DateTime(2026, 1, n),
      );
    }

    ChatMessage aiTurn(int n) => ChatMessage(
      id: 'a$n',
      sessionId: 's1',
      role: 'ai',
      kind: 'text',
      payloadJson: jsonEncode({
        'text': 'Reply $n',
        if (n == 5) 'responseId': 'resp_old',
      }),
      createdAt: DateTime(2026, 1, n),
    );

    List<Map<String, dynamic>> userParts(Map<String, dynamic> body) => [
      for (final item in body['input'] as List)
        if (item is Map && item['role'] == 'user')
          ...(item['content'] is List
              ? (item['content'] as List).cast<Map<String, dynamic>>()
              : [
                  {'type': 'input_text', 'text': item['content'].toString()},
                ]),
    ];

    test('past four video turns the chain is broken and older turns are '
        'sent as transcripts', () async {
      final h = harness(
        sse: 'data: {"type":"response.output_text.delta","delta":"hi"}\n\ndata: [DONE]\n\n',
      );
      final client = AiClient('key', client: h.client);
      final history = <ChatMessage>[
        for (var n = 1; n <= 5; n++) ...[
          videoTurn(n, transcript: n <= 2 ? 'Transcript $n' : null),
          if (n < 6) aiTurn(n),
        ],
        videoTurn(6, transcript: null),
      ];
      // Six video turns in total: current is V6, so V1-V2 are
      // transcripts and V3-V6 are the four retained videos - despite
      // a stored response id being available.
      final events = await client
          .streamTurn(model: 'test-model', history: history, videoBase64: 'V6')
          .toList();
      final body = h.lastBody();
      expect(body.containsKey('previous_response_id'), isFalse);
      // Replay has taken over for good past the window: nothing is
      // stored, and no (non-stored) response id is handed back to
      // persist as a future chain link.
      expect(body['store'], isFalse);
      expect((events.last as AiStreamDone).responseId, isNull);
      expect(body['instructions'], contains('TRANSCRIPTS'));
      final parts = userParts(body);
      expect(
        parts
            .where((c) => c['type'] == 'input_video')
            .map((c) => c['video_url']),
        [
          'data:video/mp4;base64,V3',
          'data:video/mp4;base64,V4',
          'data:video/mp4;base64,V5',
          'data:video/mp4;base64,V6',
        ],
      );
      final texts = parts
          .where((c) => c['type'] == 'input_text')
          .map((c) => c['text'])
          .join('\n');
      expect(texts, contains('Transcript 1'));
      expect(texts, contains('Transcript 2'));
      expect(texts, contains('Transcript of an earlier student turn'));
    });

    test('an aged-out turn without a transcript degrades to a marker, '
        'never back to video', () async {
      final h = harness(
        sse: 'data: {"type":"response.output_text.delta","delta":"hi"}\n\ndata: [DONE]\n\n',
      );
      final client = AiClient('key', client: h.client);
      await client
          .streamTurn(
            model: 'test-model',
            history: [
              for (var n = 1; n <= 6; n++)
                videoTurn(n, transcript: n == 1 ? 'Transcript 1' : null),
            ],
            videoBase64: 'V6',
          )
          .toList();
      final parts = userParts(h.lastBody());
      expect(parts.where((c) => c['type'] == 'input_video'), hasLength(4));
      expect(
        parts
            .where((c) => c['type'] == 'input_text')
            .map((c) => c['text'])
            .join('\n'),
        contains('transcript is unavailable'),
      );
    });

    test('transcribeVideo sends one tool-less, non-stored video', () async {
      final h = harness(
        sse: 'data: {"type":"response.output_text.delta","delta":"SPEECH: hello"}\n\ndata: [DONE]\n\n',
      );
      final client = AiClient('key', client: h.client);
      final transcript = await client.transcribeVideo(
        model: 'test-model',
        videoBase64: 'ONLYVIDEO',
      );
      expect(transcript, 'SPEECH: hello');
      final body = h.lastBody();
      expect(body['store'], isFalse);
      expect(body.containsKey('previous_response_id'), isFalse);
      expect(body.containsKey('tools'), isFalse);
      expect(body['instructions'], contains('DEIXIS'));
      expect(body['instructions'], contains('from here to here'));
      expect(body['instructions'], contains('```transcript'));
      final input = body['input'] as List;
      expect(input, hasLength(1));
      expect((input.single as Map)['content'], [
        {'type': 'input_video', 'video_url': 'data:video/mp4;base64,ONLYVIDEO'},
      ]);
    });

    test('extractTranscript keeps only the transcript block', () {
      expect(
        AiClient.extractTranscript(
          'Here is a detailed transcription:\n\n'
          '```transcript\nSPEECH:\nhello\n```\n\nLet me know if you need more.',
        ),
        'SPEECH:\nhello',
      );
      // An unterminated block still yields everything after its fence.
      expect(
        AiClient.extractTranscript('```transcript\nSPEECH:\nhello'),
        'SPEECH:\nhello',
      );
      // No fence at all: the whole reply is the fallback transcript.
      expect(
        AiClient.extractTranscript('  SPEECH:\nhello  '),
        'SPEECH:\nhello',
      );
      expect(AiClient.extractTranscript('  '), '');
    });

    test('transcribeVideo discards text outside the block', () async {
      String evt(Map<String, dynamic> e) => 'data: ${jsonEncode(e)}\n\n';
      final h = harness(
        sse: [
          evt({
            'type': 'response.output_text.delta',
            'delta': 'Here is a detailed transcription:\n```transcript\nSPEECH: hi\n```\nDone.',
          }),
          evt({
            'type': 'response.completed',
            'response': {'id': 'resp_t', 'output': []},
          }),
          'data: [DONE]\n\n',
        ].join(),
      );
      final transcript = await AiClient(
        'key',
        client: h.client,
      ).transcribeVideo(model: 'test-model', videoBase64: 'V');
      expect(transcript, 'SPEECH: hi');
    });
  });

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
      // The built-in web search tool is sent first, as its own
      // top-level Responses tool (not a function).
      expect(tools.first, {'type': 'web_search', 'search_context_size': 'low'});
      // Function tools are flat: no nested `function` wrapper.
      final firstFunction = tools.whereType<Map>().firstWhere(
        (t) => t['type'] == 'function',
      );
      expect(firstFunction['name'], 'write_text');
      expect(firstFunction.containsKey('function'), isFalse);
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

    test('uploads of an earlier turn are replayed with that turn', () async {
      final h = harness(
        sse: 'data: {"type":"response.output_text.delta","delta":"hi"}\n\ndata: [DONE]\n\n',
      );
      final client = AiClient('key', client: h.client);
      await turn(
        client,
        videoBase64: 'BOARDVIDEO',
        history: [
          message('student', {
            'hasVideo': true,
            'videoBase64': 'OLDVIDEO',
            'uploads': [
              const AiUpload(
                name: 'pic.png',
                mimeType: 'image/png',
                base64: 'IMG',
              ).toJson(),
              const AiUpload(
                name: 'notes.txt',
                mimeType: 'text/plain',
                text: 'old doc',
              ).toJson(),
            ],
          }),
        ],
      ).toList();

      final body = h.lastBody();
      // A replay (no stored response to chain onto yet) is stored so
      // the next turn can chain; only past-window replays are not.
      expect(body['store'], isTrue);
      final input = body['input'] as List;
      final earlier = (input.first as Map)['content'] as List;
      expect(earlier.first['text'], contains('old doc'));
      expect(earlier.where((c) => c['type'] == 'input_image').single, {
        'type': 'input_image',
        'image_url': 'data:image/png;base64,IMG',
      });
      expect(earlier.last, {
        'type': 'input_video',
        'video_url': 'data:video/mp4;base64,OLDVIDEO',
      });
      // ...and the current turn carries only its own board video.
      final current = (input.last as Map)['content'] as List;
      expect(current, [
        {
          'type': 'input_video',
          'video_url': 'data:video/mp4;base64,BOARDVIDEO',
        },
      ]);
    });

    test('uploads round-trip through the persisted message payload', () {
      final student = message('student', {
        'uploads': [
          const AiUpload(
            name: 'pic.png',
            mimeType: 'image/png',
            base64: 'IMG',
          ).toJson(),
          const AiUpload(
            name: 'notes.txt',
            mimeType: 'text/plain',
            text: 'hello',
          ).toJson(),
        ],
      });
      final uploads = AiClient.uploadsOf(student);
      expect(uploads.map((u) => u.name), ['pic.png', 'notes.txt']);
      expect(uploads.first.base64, 'IMG');
      expect(uploads.last.text, 'hello');
      expect(AiClient.uploadsOf(message('student', const {})), isEmpty);
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
          'call_id': 'call_write_text_0',
          'name': 'write_text',
          'arguments': '{"element_id":"title"}',
        });
        // Every replayed call is answered, or the API rejects the turn
        // with "No tool output found for function call ...".
        expect(input[2], {
          'type': 'function_call_output',
          'call_id': 'call_write_text_0',
          'output': '{"status":"success"}',
        });
        expect((input[3] as Map)['content'], 'thanks');
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

  group('stored responses and tool results', () {
    String evt(Map<String, dynamic> e) => 'data: ${jsonEncode(e)}\n\n';

    /// Mock transport that answers POSTs in order and records bodies.
    ({MockClient client, List<Map<String, dynamic>> bodies}) sequence(
      List<String> responses,
    ) {
      final bodies = <Map<String, dynamic>>[];
      var postCount = 0;
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          final sse = responses[postCount.clamp(0, responses.length - 1)];
          postCount++;
          return http.Response(
            sse,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        return http.Response('{"object":"list","data":[]}', 200);
      });
      return (client: client, bodies: bodies);
    }

    String toolRound() => [
      evt({
        'type': 'response.created',
        'response': {'id': 'resp_1'},
      }),
      evt({
        'type': 'response.output_item.done',
        'item': {
          'type': 'function_call',
          'id': 'fc1',
          'call_id': 'call_write_math',
          'name': 'write_math',
          'arguments': '{"latex":"x^2"}',
        },
      }),
      evt({
        'type': 'response.completed',
        'response': {'id': 'resp_1', 'output': []},
      }),
      'data: [DONE]\n\n',
    ].join();

    String textRound(String id, String text) => [
      evt({'type': 'response.output_text.delta', 'delta': text}),
      evt({
        'type': 'response.completed',
        'response': {'id': id, 'output': []},
      }),
      'data: [DONE]\n\n',
    ].join();

    test('sends only previous_response_id + new input when stored', () async {
      final h = sequence([textRound('resp_9', 'hi')]);
      final client = AiClient('key', client: h.client);
      await turn(
        client,
        history: [
          message('ai', {
            'text': 'Earlier reply',
            'responseId': 'resp_8',
            'toolCalls': [
              {'id': 'call_old', 'name': 'write_text', 'args': {}},
            ],
          }),
          message('user', {'text': 'earlier question'}),
        ],
      ).toList();

      expect(h.bodies, hasLength(1));
      final body = h.bodies.single;
      expect(body['store'], isTrue);
      expect(body['previous_response_id'], 'resp_8');
      // No history replay: the single input item is this turn's context.
      final input = body['input'] as List;
      expect(input, hasLength(1));
      expect((input.single as Map)['role'], 'user');
      // The new response id is surfaced for the caller to persist.
      final done = await turn(
        AiClient('key', client: sequence([textRound('resp_9', 'hi')]).client),
        history: [
          message('ai', {'text': 'x', 'responseId': 'resp_8'}),
        ],
      ).toList().then((e) => e.last);
      expect((done as AiStreamDone).responseId, 'resp_9');
    });

    test('successful tool results are persisted, not sent back, and '
        'the turn ends after one request', () async {
      final h = sequence([toolRound(), textRound('resp_2', 'Done')]);
      final executed = <String>[];
      final events = await AiClient('key', client: h.client)
          .streamTurn(
            videoBase64: '',
            model: 'test-model',
            history: const [],
            executeToolCall: (name, args) async {
              executed.add(name);
              return const AiToolResult.success('write_math performed.');
            },
          )
          .toList();

      expect(executed, ['write_math']);
      // No follow-up request: the model never sees the success result
      // in this turn, so it cannot continue with a next step.
      expect(h.bodies, hasLength(1));
      expect(
        events.whereType<AiToolCallComplete>().single.callId,
        'call_write_math',
      );
      final done = events.last as AiStreamDone;
      expect(done.fullText, '');
      expect(done.responseId, 'resp_1');
      expect(done.raw['responseId'], 'resp_1');
      // The outcome is still recorded on the persisted call, for the
      // history sheet and for replay in a later turn's request.
      final savedCall = (done.raw['toolCalls'] as List).single as Map;
      expect(savedCall['id'], 'call_write_math');
      expect(savedCall['status'], 'success');
      expect(savedCall['output'], contains('write_math performed.'));
      expect(done.raw['toolOutputsPending'], isTrue);
    });

    test('a turn after pending tool outputs replays history (with the '
        'persisted outputs) instead of chaining', () async {
      final h = sequence([textRound('resp_9', 'hi')]);
      final client = AiClient('key', client: h.client);
      await turn(
        client,
        history: [
          message('ai', {
            'text': 'Let me draw.',
            'responseId': 'resp_8',
            'toolOutputsPending': true,
            'toolCalls': [
              {
                'id': 'call_1',
                'name': 'write_text',
                'args': {'element_id': 'title'},
                'status': 'success',
                'output': '{"status":"success","detail":"done"}',
              },
            ],
          }),
          message('user', {'text': 'earlier question'}),
        ],
      ).toList();

      expect(h.bodies, hasLength(1));
      final body = h.bodies.single;
      // The stored response's function calls were never answered on
      // the server, so chaining onto it is unsafe; the replay answers
      // them locally with their persisted outputs instead.
      expect(body['previous_response_id'], isNull);
      final input = body['input'] as List;
      final call = input.firstWhere(
        (item) => item is Map && item['type'] == 'function_call',
      ) as Map;
      expect(call['call_id'], 'call_1');
      final output = input.firstWhere(
        (item) => item is Map && item['type'] == 'function_call_output',
      ) as Map;
      expect(output['call_id'], 'call_1');
      expect(output['output'], contains('done'));
    });

    // Regression (real API event order): the call_id only appears on
    // the output item, which arrives *after* function_call_arguments
    // .done. Finishing the call at arguments.done used to lock in an
    // empty id, and a failure follow-up would then have sent an
    // invented 'call_write_text', which the server rejects with a 400
    // ("function_call_output call_id ... does not match any
    // function_call in the request or its previous_response_id chain").
    test('call_id from the output item, arriving after arguments, is '
        'used for the tool result', () async {
      String realisticToolRound() => [
        evt({
          'type': 'response.created',
          'response': {'id': 'resp_1'},
        }),
        evt({
          'type': 'response.output_item.added',
          'item': {
            'type': 'function_call',
            'id': 'fc1',
            'call_id': 'call_write_text',
            'name': 'write_text',
            'arguments': '',
          },
        }),
        evt({
          'type': 'response.function_call_arguments.delta',
          'item_id': 'fc1',
          'delta': '{"text":"Functions"}',
        }),
        evt({
          'type': 'response.function_call_arguments.done',
          'item_id': 'fc1',
          'name': 'write_text',
          'arguments': '{"text":"Functions"}',
        }),
        evt({
          'type': 'response.output_item.done',
          'item': {
            'type': 'function_call',
            'id': 'fc1',
            'call_id': 'call_write_text',
            'name': 'write_text',
            'arguments': '{"text":"Functions"}',
          },
        }),
        evt({
          'type': 'response.completed',
          'response': {
            'id': 'resp_1',
            'output': [
              {
                'type': 'function_call',
                'id': 'fc1',
                'call_id': 'call_write_text',
                'name': 'write_text',
                'arguments': '{"text":"Functions"}',
              },
            ],
          },
        }),
        'data: [DONE]\n\n',
      ].join();

      final h = sequence([realisticToolRound(), textRound('resp_2', 'Done')]);
      final executed = <String>[];
      final events = await AiClient('key', client: h.client)
          .streamTurn(
            videoBase64: '',
            model: 'test-model',
            history: const [],
            executeToolCall: (name, args) async {
              executed.add(name);
              return const AiToolResult.success('performed');
            },
          )
          .toList();

      expect(executed, ['write_text']);
      expect(
        events.whereType<AiToolCallComplete>().single.callId,
        'call_write_text',
      );
      // The call succeeded, so no result is sent back in this turn;
      // the real call_id is still the one persisted with the call.
      expect(h.bodies, hasLength(1));
      final savedCall =
          ((events.last as AiStreamDone).raw['toolCalls'] as List).single
              as Map;
      expect(savedCall['id'], 'call_write_text');
    });

    test('a failing tool call that never receives a call_id fails '
        'instead of inventing one', () async {
      final noIdRound = [
        evt({
          'type': 'response.created',
          'response': {'id': 'resp_1'},
        }),
        evt({
          'type': 'response.function_call_arguments.done',
          'item_id': 'fc1',
          'name': 'write_text',
          'arguments': '{"text":"Functions"}',
        }),
        evt({
          'type': 'response.completed',
          'response': {'id': 'resp_1', 'output': []},
        }),
        'data: [DONE]\n\n',
      ].join();
      final h = sequence([noIdRound, textRound('resp_2', 'Done')]);
      var executed = 0;
      await expectLater(
        AiClient('key', client: h.client)
            .streamTurn(
              videoBase64: '',
              model: 'test-model',
              history: const [],
              executeToolCall: (name, args) async {
                executed++;
                return const AiToolResult.failure('no such element');
              },
            )
            .toList(),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('call id'),
          ),
        ),
      );
      // The call was performed (that is how its failure is known), but
      // no follow-up request was sent with an invented id.
      expect(executed, 1);
      expect(h.bodies, hasLength(1));
    });

    test('a successful tool call without a call_id ends the turn '
        'normally', () async {
      final noIdRound = [
        evt({
          'type': 'response.created',
          'response': {'id': 'resp_1'},
        }),
        evt({
          'type': 'response.function_call_arguments.done',
          'item_id': 'fc1',
          'name': 'write_text',
          'arguments': '{"text":"Functions"}',
        }),
        evt({
          'type': 'response.completed',
          'response': {'id': 'resp_1', 'output': []},
        }),
        'data: [DONE]\n\n',
      ].join();
      final h = sequence([noIdRound]);
      final events = await AiClient('key', client: h.client)
          .streamTurn(
            videoBase64: '',
            model: 'test-model',
            history: const [],
            executeToolCall: (name, args) async =>
                const AiToolResult.success('performed'),
          )
          .toList();
      // Nothing is sent back on success, so the missing id never
      // reaches the API.
      expect(h.bodies, hasLength(1));
      expect(events.last, isA<AiStreamDone>());
    });

    test(
      'a failing tool is reported as an error and the loop continues',
      () async {
        final h = sequence([toolRound(), textRound('resp_2', 'Recovered')]);
        final events = await AiClient('key', client: h.client)
            .streamTurn(
              videoBase64: '',
              model: 'test-model',
              history: const [],
              executeToolCall: (name, args) async =>
                  throw StateError('no such element'),
            )
            .toList();

        final followUp = h.bodies[1];
        final output =
            ((followUp['input'] as List).single as Map)['output'] as String;
        expect(output, contains('"status":"error"'));
        expect(output, contains('no such element'));
        expect((events.last as AiStreamDone).fullText, 'Recovered');
      },
    );

    // Regression: dart_openai closes the client handed to createStream
    // when the stream ends. With a real (close-sensitive) transport the
    // function_call_output round used to fail with "Client is already
    // closed"; MockClient hides that because its close() is a no-op.
    test('failure follow-up survives a transport that refuses reuse '
        'after close', () async {
      final h = sequence([toolRound(), textRound('resp_2', 'Done')]);
      final events =
          await AiClient('key', client: _CloseSensitiveClient(h.client))
              .streamTurn(
                videoBase64: '',
                model: 'test-model',
                history: const [],
                executeToolCall: (name, args) async =>
                    const AiToolResult.failure('no such element'),
              )
              .toList();

      expect(h.bodies, hasLength(2));
      expect((events.last as AiStreamDone).fullText, 'Done');
    });

    test('sequential failing rounds keep chaining on the newest '
        'response id', () async {
      final h = sequence([
        toolRound(),
        toolRound().replaceAll('resp_1', 'resp_2'),
        textRound('resp_3', 'All steps done'),
      ]);
      var calls = 0;
      final events = await AiClient('key', client: h.client)
          .streamTurn(
            videoBase64: '',
            model: 'test-model',
            history: const [],
            executeToolCall: (name, args) async {
              calls++;
              return AiToolResult.failure('step $calls failed');
            },
          )
          .toList();

      expect(calls, 2);
      expect(h.bodies, hasLength(3));
      expect(h.bodies[1]['previous_response_id'], 'resp_1');
      expect(h.bodies[2]['previous_response_id'], 'resp_2');
      expect((events.last as AiStreamDone).responseId, 'resp_3');
    });

    test('past the video window a failing tool is answered with a '
        'self-contained, non-stored follow-up', () async {
      final h = sequence([toolRound(), textRound('resp_2', 'Recovered')]);
      // Five saved student video turns plus the current one: replay
      // mode, past the window.
      final history = [
        for (var n = 1; n <= 5; n++)
          message('student', {'hasVideo': true, 'videoBase64': 'V$n'}),
      ];
      final events = await AiClient('key', client: h.client)
          .streamTurn(
            videoBase64: 'V6',
            model: 'test-model',
            history: history,
            executeToolCall: (name, args) async =>
                const AiToolResult.failure('no such element'),
          )
          .toList();

      expect(h.bodies, hasLength(2));
      for (final body in h.bodies) {
        expect(body['store'], isFalse);
        expect(body.containsKey('previous_response_id'), isFalse);
      }
      // The follow-up resends the turn (replayed history included)
      // plus the call and its output, since there is no stored
      // response to chain the output onto.
      final followUpInput = h.bodies[1]['input'] as List;
      expect(
        followUpInput.any((item) => item is Map && item['role'] == 'user'),
        isTrue,
      );
      final call = followUpInput.firstWhere(
        (item) => item is Map && item['type'] == 'function_call',
      ) as Map;
      expect(call['call_id'], 'call_write_math');
      final output = followUpInput.firstWhere(
        (item) => item is Map && item['type'] == 'function_call_output',
      ) as Map;
      expect(output['call_id'], 'call_write_math');
      expect(output['output'], contains('no such element'));
      final done = events.last as AiStreamDone;
      expect(done.fullText, 'Recovered');
      expect(done.responseId, isNull);
      expect(done.raw['responseId'], isNull);
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

/// A transport with the real `http.Client` contract: once [close] has
/// been called, [send] throws. (package:http's MockClient does not
/// enforce this, which is how the "client already closed" bug shipped.)
class _CloseSensitiveClient extends http.BaseClient {
  _CloseSensitiveClient(this._inner);

  final http.Client _inner;
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (_closed) {
      throw http.ClientException(
        'HTTP request failed. Client is already closed.',
        request.url,
      );
    }
    return _inner.send(request);
  }

  @override
  void close() => _closed = true;
}
