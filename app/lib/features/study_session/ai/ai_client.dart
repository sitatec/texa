import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:texa/core/http_client/http_client.dart';
import 'package:texa/core/http_client/sse_client.dart';

import '../../../core/constants.dart';
import '../../../core/errors.dart';
import '../../../core/data/models.dart';
import 'ai_actions.dart';
import '../debug_log.dart';
import 'system_prompt.dart';
import 'video_transcription_prompt.dart';

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

/// A completed reasoning item, emitted as soon as it finishes so the
/// turn's ordered history (and its encrypted replay payload) can be
/// persisted before the rest of the response arrives.
class AiReasoningComplete extends AiEvent {
  AiReasoningComplete(this.item);

  /// Responses reasoning item: id, summary and encrypted_content.
  final Map<String, dynamic> item;
}

class AiStreamDone extends AiEvent {
  AiStreamDone(this.raw, this.fullText, {this.responseId});
  final Map<String, dynamic> raw;
  final String fullText;

  /// Always null: requests are stateless (`store: false`, no
  /// `previous_response_id`), so no response id is ever chained onto.
  /// Response ids are kept only in [raw]'s `responseIds` for
  /// diagnostics. Kept as a field for payload compatibility.
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
/// tools act on; [AiClient] starts it as soon as the call is complete
/// in the stream and collects its outcome for the round's single
/// follow-up request (see [AiClient.streamTurn]).
typedef AiToolExecutor = Future<AiToolResult> Function(
  String name,
  Map<String, dynamic> args,
);

/// One tool call started while its response is still streaming.
/// Execution needs only the name and arguments, so it begins as soon
/// as the call is complete; [callId] may still be empty at that point
/// (some streams only carry it on the terminal response event) and is
/// patched in once the round ends - it is only needed to build the
/// follow-up request, never to perform the action.
class _InFlightToolCall {
  _InFlightToolCall({
    required this.call,
    required this.entry,
    required this.outcome,
    required this.callId,
  });

  final AiToolCallComplete call;
  final Map<String, dynamic> entry;
  final Future<AiToolResult> outcome;
  String callId;
}

/// Internal terminal event of one streamed response; never leaves
/// [AiClient.streamTurn].
class _ResponseRound extends AiEvent {
  _ResponseRound({
    required this.responseId,
    required this.text,
    required this.calls,
    this.reasoning = const [],
  });
  final String? responseId;
  final String text;
  final List<({String callId, String name, Map<String, dynamic> args})> calls;
  final List<Map<String, dynamic>> reasoning;
}

/// Canonical JSON for comparing decoded tool arguments. Map key order
/// is insignificant (a provider may serialise the same call's arguments
/// in a different order on the terminal event than it streamed them),
/// so keys are sorted before encoding.
String _canonicalArgsJson(String raw) {
  dynamic sort(dynamic v) {
    // 80 and 80.0 are the same argument; providers mix them between
    // the streamed and terminal copies of a call.
    if (v is double && v.isFinite && v == v.truncateToDouble()) {
      return v.toInt();
    }
    if (v is Map) {
      final keys = v.keys.map((k) => k.toString()).toList()..sort();
      return {for (final k in keys) k: sort(v[k])};
    }
    if (v is List) return [for (final e in v) sort(e)];
    return v;
  }

  return jsonEncode(sort(decodeArgs(raw)));
}

/// Converts ordered persisted AI-turn items to Responses input items,
/// preserving round order (reasoning -> text -> calls -> outputs).
/// Reasoning without encrypted content cannot be replayed statelessly
/// and is skipped; a trailing reasoning item is followed by a minimal
/// assistant message, as the API requires.
List<Map<String, dynamic>> aiItemsToInput(List<dynamic> items, String idSeed) {
  final out = <Map<String, dynamic>>[];
  var callIndex = 0;
  final seenCallIds = <String>{};
  for (final raw in items) {
    if (raw is! Map) continue;
    final item = raw.cast<String, dynamic>();
    switch (item['kind']) {
      case 'reasoning':
        final enc = item['encrypted_content'];
        if (enc is String && enc.isNotEmpty) {
          out.add({
            'type': 'reasoning',
            if (item['id'] is String && (item['id'] as String).isNotEmpty)
              'id': item['id'],
            'summary': item['summary'] is List ? item['summary'] : const [],
            'encrypted_content': enc,
          });
        }
      case 'text':
        final t = (item['text'] as String? ?? '').trim();
        if (t.isNotEmpty) {
          out.add({
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': t},
            ],
          });
        }
      case 'toolCall':
        final callId = item['id'] as String? ?? 'call_${idSeed}_$callIndex';
        callIndex++;
        // A turn persisted while a duplicate-execution bug was live
        // can carry the same call twice; replaying both would send
        // duplicate function_call / function_call_output items, which
        // the API rejects. Keep the first occurrence only.
        if (!seenCallIds.add(callId)) {
          texaDiag(
            'ai',
            'replay SUPPRESSED duplicate persisted call callId=$callId name=${item['name']} seed=$idSeed',
          );
          continue;
        }
        out.add({
          'type': 'function_call',
          'call_id': callId,
          'name': item['name'],
          'arguments': jsonEncode(item['args'] ?? {}),
        });
        final o = item['output'];
        out.add({
          'type': 'function_call_output',
          'call_id': callId,
          'output': o is String && o.isNotEmpty
              ? o
              : const AiToolResult.success().wireOutput,
        });
    }
  }
  if (out.isNotEmpty && out.last['type'] == 'reasoning') {
    out.add({
      'role': 'assistant',
      'content': [
        {'type': 'output_text', 'text': ''},
      ],
    });
  }
  return out;
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

  /// Persisted shape, stored in the student message payload so the
  /// files a turn carried stay visible (attachments modal, history)
  /// and can be rebuilt if that turn is ever replayed.
  Map<String, dynamic> toJson() => {
    'name': name,
    'mimeType': mimeType,
    if (base64 != null) 'base64': base64,
    if (text != null) 'text': text,
  };

  factory AiUpload.fromJson(Map<String, dynamic> json) => AiUpload(
    name: json['name'] as String? ?? '',
    mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
    base64: json['base64'] as String?,
    text: json['text'] as String?,
  );
}

/// Direct streaming client to the fixed Meta AI (OpenAI Responses
/// API compatible) endpoint, talking to it over the shared
/// [SseClient]/[TexaHttpClient] transport instead of a third-party
/// OpenAI SDK.
///
/// One client serves a whole session: it owns one HTTP transport and
/// reuses it for every tutor turn, every tool-round follow-up and
/// every background transcription, keeping connections alive instead
/// of rebuilding them per turn. Interruption is therefore *not* done
/// by closing the client (that used to be the only abort handle, and
/// is why a client had to be created per turn): [cancelTurn] aborts
/// only the in-flight tutor turn, through that request's own
/// cancellation signal, and leaves the transport - and any background
/// transcription - untouched. [close] is reserved for the end of the
/// client's life (session disposed, settings test finished) and does
/// close the transport.
class AiClient {
  AiClient(this.apiKey, {http.Client? client})
    : _client = client ?? TexaHttpClient.create() {
    _sse = SseClient(client: _client);
  }

  final String apiKey;
  final http.Client _client;
  late final SseClient _sse;

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $apiKey',
    'Content-Type': 'application/json',
  };

  static const String _responsesUrl = '$apiBaseUrl/responses';
  static const String _modelsUrl = '$apiBaseUrl/models';

  /// Whether [message] is a saved student turn that was sent (or is to
  /// be sent) as a turn-video. Such messages keep their video bytes in
  /// `videoBase64` for local history playback forever; whether the
  /// video or its transcript goes on the wire is decided per request.
  static bool isStudentVideoTurn(ChatMessage message) =>
      message.role != 'ai' &&
      (message.payload['videoBase64'] as String?)?.isNotEmpty == true;

  /// All student video turns in [history], oldest first.
  static List<ChatMessage> studentVideoTurns(List<ChatMessage> history) =>
      history.where(isStudentVideoTurn).toList();

  /// The persisted transcript of a student video turn, or null when it
  /// has not been transcribed (yet / successfully).
  static String? transcriptOf(ChatMessage message) {
    final transcript = message.payload['transcript'];
    return transcript is String && transcript.trim().isNotEmpty
        ? transcript.trim()
        : null;
  }

  /// Uploads persisted with a saved student turn (see
  /// [AiUpload.toJson]), oldest first; empty for turns sent without
  /// attachments or saved before uploads were persisted.
  static List<AiUpload> uploadsOf(ChatMessage message) {
    final uploads = message.payload['uploads'];
    if (uploads is! List) return const [];
    return [
      for (final upload in uploads)
        if (upload is Map) AiUpload.fromJson(upload.cast<String, dynamic>()),
    ];
  }

  /// Extracts the transcript from a transcription model's raw reply.
  ///
  /// The prompt asks for exactly one ```` ```transcript ```` fenced
  /// block and nothing else, so the block's content is the transcript
  /// and anything around it (a stray "Here is the transcription…", a
  /// sign-off) is discarded. Fallbacks, in order: a closed fenced
  /// block with another (or no) tag, an unterminated `transcript`
  /// block (take everything after its opening fence), and finally the
  /// whole reply trimmed - a model that ignored the format still
  /// yields its record instead of failing the transcription.
  static String extractTranscript(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return '';
    final tagged = RegExp(
      r'```transcript[^\S\r\n]*\r?\n([\s\S]*?)(?:\r?\n```|\s*$)',
    ).firstMatch(text);
    final taggedText = tagged?.group(1)?.trim();
    if (taggedText != null && taggedText.isNotEmpty) return taggedText;
    final fenced = RegExp(r'```[A-Za-z0-9_-]*[^\S\r\n]*\r?\n([\s\S]*?)\r?\n```')
        .firstMatch(text);
    final fencedText = fenced?.group(1)?.trim();
    if (fencedText != null && fencedText.isNotEmpty) return fencedText;
    return text;
  }

  /// Transcribes one student turn-video with [model] into the
  /// self-contained written record described by
  /// [kVideoTranscriptionPrompt]. A single, tool-less, non-stored
  /// request carrying exactly one video: it never touches the tutor
  /// conversation chain. Throws [AppError] on failure or empty output;
  /// callers that transcribe in the background must catch it.
  Future<String> transcribeVideo({
    required String model,
    required String videoBase64,
  }) async {
    _ResponseRound? completed;
    await for (final event in _streamOneResponse(
      cancellation: _disposeCancellation,
      model: model,
      instructions: kVideoTranscriptionPrompt,
      input: [
        {
          'role': 'user',
          'content': [
            {
              'type': 'input_video',
              'video_url': 'data:video/mp4;base64,$videoBase64',
            },
          ],
        },
      ],
      reasoningEffort: null,
      allowTools: false,
      storeResponse: false,
      includeTools: false,
    )) {
      if (event is _ResponseRound) completed = event;
    }
    if (_closed) {
      throw const AppError('Transcription was cancelled.');
    }
    final text = extractTranscript(completed?.text ?? '');
    if (text.isEmpty) {
      throw const AppError('Transcription returned an empty record.');
    }
    return text;
  }

  /// Set by [close]. A closed client must never start another request:
  /// after an interrupt the tool outputs of the round that was in
  /// flight are stale and must not be sent to the model.
  bool _closed = false;

  /// Fired by [close]; aborts every request this client has in flight.
  final _RequestCancellation _disposeCancellation = _RequestCancellation();

  /// Cancellation for the tutor turn currently streaming, if any.
  /// Kept separate from [_disposeCancellation] so [cancelTurn] kills
  /// the turn the student interrupted without touching a background
  /// transcription running on the same client (those used to be safe
  /// only because each ran on its own client).
  _RequestCancellation? _turnCancellation;

  bool _isCancelled(_RequestCancellation cancellation) =>
      _closed || cancellation.isCancelled;

  /// Aborts the in-flight tutor turn, if any: its stream ends promptly
  /// and silently (a cancellation the app itself requested is not an
  /// error), and the in-flight HTTP request is aborted at the
  /// transport via its abort trigger. The client - its transport,
  /// connection pool and any background transcription - stays usable,
  /// so the next turn reuses them.
  void cancelTurn() => _turnCancellation?.cancel();

  /// Closes the underlying transport, aborting every request in
  /// flight. Terminal: once closed, this client starts no new
  /// requests. Use [cancelTurn] to interrupt a single turn.
  void close() {
    if (_closed) return;
    _closed = true;
    _turnCancellation?.cancel();
    _disposeCancellation.cancel();
    _client.close();
  }

  /// Races [source] against [cancellation]: when it fires the returned
  /// stream ends promptly (cancelling the source) even if the source
  /// is blocked waiting for its first event - e.g. while the model is
  /// still thinking, where aborting the transport alone may not
  /// unblock the await (notably on web). Ending without an error is
  /// deliberate: callers treat a cancelled request as a silent abort.
  Stream<T> _untilCancelled<T>(
    Stream<T> source,
    _RequestCancellation cancellation,
  ) {
    late StreamController<T> controller;
    StreamSubscription<T>? subscription;
    var finished = false;
    controller = StreamController<T>(
      onListen: () {
        subscription = source.listen(
          (event) {
            if (!finished && !controller.isClosed) controller.add(event);
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!finished && !controller.isClosed) {
              controller.addError(error, stackTrace);
            }
          },
          onDone: () {
            if (finished) return;
            finished = true;
            if (!controller.isClosed) controller.close();
          },
        );
        cancellation.signal.then((_) {
          if (finished) return;
          finished = true;
          final sub = subscription;
          subscription = null;
          if (sub != null) unawaited(sub.cancel().catchError((_) {}));
          if (!controller.isClosed) controller.close();
        });
      },
      onCancel: () {
        finished = true;
        final sub = subscription;
        subscription = null;
        // Fire-and-forget, deliberately NOT awaited: cancelling a
        // source suspended awaiting response headers only completes
        // when that await does, and returning that future from
        // onCancel holds this controller's done event hostage until
        // then - which is exactly the abort we are trying to perform.
        if (sub != null) unawaited(sub.cancel().catchError((_) {}));
      },
    );
    return controller.stream;
  }

  /// Minimal authenticated request used by Test connection.
  Future<void> testConnection() async {
    try {
      final request = http.AbortableRequest(
        'GET',
        Uri.parse(_modelsUrl),
        abortTrigger: _disposeCancellation.signal,
      )..headers.addAll(_headers);
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: connectTimeoutSeconds));
      // Drain (bounded) so the connection can be reused / released.
      final body = await response.stream.bytesToString();
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const AppError(
          'That API key was not accepted. Check it and try again.',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AppError(
          'Connection failed (${response.statusCode}). Check your connection and try again.',
          cause: SseHttpException(response.statusCode, body),
        );
      }
    } on AppError {
      rethrow;
    } catch (e) {
      if (_closed) return;
      throw AppError(
        'Could not reach Meta AI. Check your connection and try again.',
        cause: e,
      );
    }
  }

  /// Media parts for [uploads] (image/video/audio/document), in order.
  List<Map<String, dynamic>> _uploadMediaParts(List<AiUpload> uploads) => [
    for (final u in uploads.where((u) => u.hasBase64 && !u.hasText))
      switch (u.kind) {
        AiUploadKind.image => {'type': 'input_image', 'image_url': u.dataUri},
        AiUploadKind.video => {'type': 'input_video', 'video_url': u.dataUri},
        AiUploadKind.audio => {
          'type': 'input_audio',
          'input_audio': {'data': u.base64, 'format': u.audioFormat},
        },
        AiUploadKind.document => {
          'type': 'input_file',
          'filename': u.name,
          'file_data': u.dataUri,
        },
      },
  ];

  /// Text context for [uploads]: text-like files inlined, byte-less
  /// files mentioned by name. Empty when every upload is a media part.
  String _uploadTextContext(List<AiUpload> uploads) {
    final buffer = StringBuffer();
    for (final u in uploads) {
      if (u.hasText) {
        buffer.write(
          '\nThe student uploaded a file named ${u.name}:\n${u.text}',
        );
      } else if (!u.hasBase64) {
        buffer.write(
          '\nThe student attached a file named ${u.name} (${u.mimeType}).',
        );
      }
    }
    return buffer.toString();
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
    List<String> priorVideosBase64 = const [],
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
    // Superseded-turn videos that are already saved in [history] are
    // replayed below as their own turns; only ones the history does
    // not know about ride along inside this turn's message.
    final historyVideoBytes = {
      for (final m in history.where(isStudentVideoTurn))
        m.payload['videoBase64'] as String,
    };
    final effectivePriorVideos = includeHistory
        ? priorVideosBase64
              .where((v) => !historyVideoBytes.contains(v))
              .toList()
        : priorVideosBase64;
    // This turn's message always carries one board video (plus any
    // superseded videos the history does not hold and any uploaded
    // videos); the remaining video budget is spent on the newest
    // earlier turns. Every older video turn is sent as its transcript.
    final videosInCurrentMessage =
        1 +
        effectivePriorVideos.length +
        uploads
            .where(
              (u) => u.hasBase64 && !u.hasText && u.kind == AiUploadKind.video,
            )
            .length;
    final retainedVideoBudget =
        maxVideoTurnsPerRequest - videosInCurrentMessage;
    // Index (into [history]) of this turn's own saved message: it is
    // sent once, as the final message below, not again in the replay.
    var currentIndex = -1;
    for (var i = history.length - 1; i >= 0; i--) {
      if (isStudentVideoTurn(history[i]) &&
          history[i].payload['videoBase64'] == videoBase64) {
        currentIndex = i;
        break;
      }
    }
    final earlierVideoIndices = [
      for (var i = 0; i < history.length; i++)
        if (i != currentIndex && isStudentVideoTurn(history[i])) i,
    ];
    // Uploaded videos replayed with earlier turns (below) are videos
    // in this request too, so they spend the same budget.
    final historicalUploadVideos = includeHistory
        ? earlierVideoIndices
              .expand((i) => uploadsOf(history[i]))
              .where(
                (u) =>
                    u.hasBase64 && !u.hasText && u.kind == AiUploadKind.video,
              )
              .length
        : 0;
    final boardVideoBudget = retainedVideoBudget - historicalUploadVideos;
    final retainedVideoIndices = boardVideoBudget <= 0
        ? const <int>{}
        : earlierVideoIndices
              .skip(
                earlierVideoIndices.length > boardVideoBudget
                    ? earlierVideoIndices.length - boardVideoBudget
                    : 0,
              )
              .toSet();
    // Stateless: the full local history is replayed on every request
    // (older student videos as transcripts, newest as video).
    if (includeHistory) {
      for (var index = 0; index < history.length; index++) {
        final m = history[index];
        if (index == currentIndex) continue;
        if (m.role == 'ai') {
          final p = m.payload;
          final items = p['items'];
          if (items is List && items.isNotEmpty) {
            input.addAll(aiItemsToInput(items, m.id));
          } else {
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
                final callId = cm['id'] as String? ?? 'call_${m.id}_$i';
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
          }
        } else if (isStudentVideoTurn(m)) {
          final video = m.payload['videoBase64'] as String;
          // Files this turn carried are replayed with it: the model
          // is stateless, so a replayed turn without its attachments
          // is a turn it never saw the files in.
          final turnUploads = uploadsOf(m);
          final uploadText = _uploadTextContext(turnUploads).trim();
          final uploadParts = _uploadMediaParts(turnUploads);
          if (retainedVideoIndices.contains(index)) {
            input.add({
              'role': 'user',
              'content': [
                if (uploadText.isNotEmpty)
                  {'type': 'input_text', 'text': uploadText},
                ...uploadParts,
                {
                  'type': 'input_video',
                  'video_url': 'data:video/mp4;base64,$video',
                },
              ],
            });
          } else {
            // Aged out of the video window: only its transcript is
            // sent. The session controller transcribes ahead of this
            // moment; a missing transcript (failed transcription, or a
            // caller that never ran one) degrades to an explicit
            // marker instead of silently re-sending the video and
            // breaking the per-request video limit.
            final transcript = transcriptOf(m);
            input.add({
              'role': 'user',
              'content': [
                {
                  'type': 'input_text',
                  'text':
                      (transcript != null
                          ? '[Transcript of an earlier student turn - originally a board-and-voice video, transcribed because only the newest turns are sent as video. The quoted words are the student\'s own; the surrounding descriptions record what was on the board and what the student pointed at or did.]\n$transcript'
                          : '[An earlier student turn was given as a board-and-voice video. Its transcript is unavailable, so its exact content could not be included here. Rely on the surrounding conversation and the current board, and ask the student if that turn matters.]') +
                      (uploadText.isEmpty ? '' : '\n$uploadText'),
                },
                ...uploadParts,
              ],
            });
          }
        } else if ((m.payload['text'] as String?)?.isNotEmpty == true ||
            uploadsOf(m).isNotEmpty) {
          final text = (m.payload['text'] as String? ?? '').trim();
          final turnUploads = uploadsOf(m);
          if (turnUploads.isEmpty) {
            input.add({'role': 'user', 'content': text});
          } else {
            final combined = (text + _uploadTextContext(turnUploads)).trim();
            input.add({
              'role': 'user',
              'content': [
                if (combined.isNotEmpty)
                  {'type': 'input_text', 'text': combined},
                ..._uploadMediaParts(turnUploads),
              ],
            });
          }
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
    context.write(_uploadTextContext(uploads));

    final parts = <Map<String, dynamic>>[
      // Inputs of earlier turns that were cancelled before the model
      // produced anything (interrupted while thinking): they were
      // never answered, so they ride along *before* this turn's own
      // content and the model answers them together with it.
      for (final prior in effectivePriorVideos)
        {'type': 'input_video', 'video_url': 'data:video/mp4;base64,$prior'},
      if (context.isNotEmpty)
        {'type': 'input_text', 'text': context.toString()},
    ];
    parts.addAll(_uploadMediaParts(uploads));
    // The board turn-video is a video, not an image.
    parts.add({
      'type': 'input_video',
      'video_url': 'data:video/mp4;base64,$videoBase64',
    });
    input.add({'role': 'user', 'content': parts});
    return (instructions: instructions.toString(), input: input);
  }

  /// Streams one turn.
  ///
  /// Every request is stateless from the start: `store: false`, no
  /// `previous_response_id`, and `include:
  /// ["reasoning.encrypted_content"]` on every request. The full local
  /// history - including each turn's ordered reasoning (encrypted),
  /// text, function calls, outputs and attachments - is replayed on
  /// every request, and tool-result follow-ups resend the turn input
  /// plus all rounds' ordered items and outputs so far, self-contained.
  /// Within the video window the newest student turns replay as video;
  /// older ones replay as transcripts (see [maxVideoTurnsPerRequest]).
  ///
  /// The agentic loop: a response's tool calls are performed through
  /// [executeToolCall] and every outcome - success or failure - is
  /// sent back to the model, which may then call more tools or answer
  /// in words, until a response arrives with no further calls.
  /// Streaming stays realtime: text deltas are forwarded as they
  /// arrive, and each tool call starts executing as soon as it is
  /// complete in the stream (after the consumer has had its chance to
  /// queue any preceding text), not when the whole response ends.
  /// Execution therefore overlaps the rest of the response, but the
  /// results are still collected and sent in ONE follow-up request
  /// per round - a response asking for three actions gets a single
  /// request carrying all three `function_call_output` items, in call
  /// order, so the stored/replayed history stays well-formed. Rounds
  /// are bounded by [maxToolRounds], after which one last tool-less
  /// request lets the model wrap up in words. Without an executor the
  /// turn stays a single request, as before. [AiStreamDone] is
  /// emitted once, at the very end, and carries the final response id
  /// for the caller to persist with the AI message.
  /// Streams one tutor turn. Concurrent turns are not supported:
  /// [cancelTurn] aborts whichever turn is currently streaming.
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
    AiToolExecutor? executeToolCall,
    int maxToolRounds = 10,
    List<String> priorVideosBase64 = const [],
  }) async* {
    if (_closed) return;
    // A new turn supersedes the cancellation of the one it replaces:
    // each turn gets a fresh signal, so cancelling turn N can never
    // leak into turn N+1, which is what makes one long-lived client
    // safe where a fresh client per turn used to provide isolation.
    final cancellation = _RequestCancellation();
    _turnCancellation = cancellation;
    try {
      yield* _streamTurn(
        cancellation: cancellation,
        model: model,
        history: history,
        videoBase64: videoBase64,
        interruptionContext: interruptionContext,
        studentMemory: studentMemory,
        recentObservations: recentObservations,
        currentObservation: currentObservation,
        uploads: uploads,
        extraContext: extraContext,
        reasoningEffort: reasoningEffort,
        executeToolCall: executeToolCall,
        maxToolRounds: maxToolRounds,
        priorVideosBase64: priorVideosBase64,
      );
    } finally {
      if (identical(_turnCancellation, cancellation)) {
        _turnCancellation = null;
      }
    }
  }

  Stream<AiEvent> _streamTurn({
    required _RequestCancellation cancellation,
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
    AiToolExecutor? executeToolCall,
    int maxToolRounds = 10,
    List<String> priorVideosBase64 = const [],
  }) async* {
    final request = _requestInput(
      history: history,
      videoBase64: videoBase64,
      interruptionContext: interruptionContext,
      studentMemory: studentMemory,
      recentObservations: recentObservations,
      currentObservation: currentObservation,
      uploads: uploads,
      extraContext: extraContext,
      includeHistory: true,
      priorVideosBase64: priorVideosBase64,
    );

    final fullText = StringBuffer();
    final allCalls = <Map<String, dynamic>>[];
    final responseIds = <String>[];
    List<Map<String, dynamic>> nextInput = request.input;
    // Stateless follow-ups cannot chain on the previous round's
    // response, so each resends this input plus every round's ordered
    // items and function_call_output items so far.
    var replayFollowUpInput = request.input;
    // Ordered pieces of the whole turn (reasoning/text/toolCall maps),
    // persisted as `items` so replay reproduces the original round
    // order instead of flattening text before every call. Tool-call
    // entries are shared with allCalls, so status/output/id patches
    // land in both.
    final allItems = <Map<String, dynamic>>[];
    var wrapUpNext = false;
    // True when the final round's tool calls were performed but their
    // outputs were never sent back (only possible without an
    // executor); persisted on the AI message for diagnostics - replay
    // always answers calls with their persisted outputs anyway. A
    // completed agentic loop always answers its calls, so it leaves
    // this false.
    var toolOutputsPending = false;

    // Performs one call, converting a throw into a failure outcome so
    // the future can safely run un-awaited while the rest of the
    // response is still streaming.
    Future<AiToolResult> runToolCall(AiToolCallComplete call) async {
      try {
        return await executeToolCall!(call.name, call.args);
      } catch (e) {
        debugPrint('Failed to execute tool call $call: $e');
        final detail = e.toString();
        return AiToolResult.failure(
          'The action failed: '
          '${detail.length > 200 ? detail.substring(0, 200) : detail}',
        );
      }
    }

    if (kDebugMode) {
      texaDiag(
        'ai',
        'turn start history=${history.length} uploads=${uploads.length} input=${diagInputSummary(request.input)}',
      );
    }
    for (final m in history.where((m) => m.role == 'ai')) {
      final items = m.payload['items'];
      if (kDebugMode) {
        texaDiag(
          'ai',
          'history ai id=${m.id} kind=${m.kind} items=${items is List ? items.map((i) => i is Map ? (i['kind'] == 'toolCall'
                          ? 'call(${i['name']}:${i['id'] ?? 'MISSING'}:${i['status'] ?? 'nostatus'}:${diagJson(i['args'])})'
                          : i['kind'] == 'text'
                          ? 'text(${diagText(i['text']?.toString() ?? '')})'
                          : 'reasoning(${i['id'] ?? 'noid'}:${((i['encrypted_content'] ?? '') as String).isEmpty ? 'NOENC' : 'enc'})') : '?').join(',') : 'legacy'} text=${diagText(m.payload['text']?.toString() ?? '')} calls=${diagJson(m.payload['toolCalls'])}',
        );
      }
    }
    for (var round = 0; ; round++) {
      // Cancelled while the previous round (or its tool calls) was in
      // flight: the turn was interrupted, so do not send anything else.
      if (_isCancelled(cancellation)) return;
      final allowTools = !wrapUpNext;
      if (kDebugMode) {
        texaDiag(
          'ai',
          'round $round request allowTools=$allowTools wrapUp=$wrapUpNext input=${diagInputSummary(nextInput)}',
        );
      }
      _ResponseRound? completed;
      // Tool calls of this round, started the moment each one is
      // complete in the stream; their outcome futures are collected
      // here and awaited only once the round has ended.
      final inFlight = <_InFlightToolCall>[];
      final roundItems = <Map<String, dynamic>>[];
      final roundStreamedText = StringBuffer();
      void flushRoundText() {
        final segment = roundStreamedText.toString();
        if (segment.trim().isNotEmpty) {
          final item = {'kind': 'text', 'text': segment};
          roundItems.add(item);
          allItems.add(item);
        }
        roundStreamedText.clear();
      }

      await for (final event in _streamOneResponse(
        cancellation: cancellation,
        model: model,
        instructions: request.instructions,
        input: nextInput,
        reasoningEffort: reasoningEffort,
        allowTools: allowTools,
        storeResponse: false,
      )) {
        if (event is _ResponseRound) {
          completed = event;
        } else {
          if (event is AiTextDelta) roundStreamedText.write(event.text);
          if (event is AiReasoningComplete) {
            flushRoundText();
            final item = <String, dynamic>{
              'kind': 'reasoning',
              if (event.item['id'] != null) 'id': event.item['id'],
              'summary': event.item['summary'] is List
                  ? event.item['summary']
                  : const [],
              if (event.item['encrypted_content'] != null)
                'encrypted_content': event.item['encrypted_content'],
            };
            // Insert at the round's reasoning position (its start),
            // in case the item only arrived on the terminal event,
            // after text/tool pieces had already been recorded.
            final roundStart = allItems.length - roundItems.length;
            final reasoningCount = roundItems
                .where((i) => i['kind'] == 'reasoning')
                .length;
            // Upgrade of an already-recorded item (same id) replaces
            // it instead of duplicating it.
            final existingAt = roundItems.indexWhere(
              (i) =>
                  i['kind'] == 'reasoning' &&
                  item['id'] != null &&
                  i['id'] == item['id'],
            );
            if (existingAt >= 0) {
              roundItems[existingAt] = item;
              allItems[roundStart + existingAt] = item;
            } else {
              roundItems.insert(reasoningCount, item);
              allItems.insert(roundStart + reasoningCount, item);
            }
          }
          if (event is AiToolCallComplete) flushRoundText();
          // Execution-layer idempotency guard: if this call is
          // already in flight for this round - same call_id, or (id
          // not yet known on either copy) same name + same normalised
          // arguments - it is the same physical call reported twice,
          // and it must neither be yielded (the caller would persist
          // it twice) nor executed again. Two legitimate calls with
          // distinct call_ids are never merged by this check.
          if (event is AiToolCallComplete && executeToolCall != null) {
            final duplicate = inFlight.any(
              (f) =>
                  (event.callId.isNotEmpty && f.callId == event.callId) ||
                  ((f.callId.isEmpty || event.callId.isEmpty) &&
                      f.call.name == event.name &&
                      _canonicalArgsJson(jsonEncode(f.call.args)) ==
                          _canonicalArgsJson(jsonEncode(event.args))),
            );
            if (duplicate) {
              texaDiag(
                'ai',
                'round $round call event SUPPRESSED (already in flight) name=${event.name} callId=${event.callId.isEmpty ? 'MISSING' : event.callId} args=${diagJson(event.args)}',
              );
              continue;
            }
          }
          // Text deltas and completed tool calls reach the consumer
          // immediately; nothing waits for the response to finish.
          yield event;
          // Resuming after a yield means the consumer has handled
          // the event (queueing any text that preceded the call), so
          // it is safe - and correctly ordered - to start the call
          // now, while the model may still be streaming the rest of
          // this response.
          if (event is AiToolCallComplete && executeToolCall != null) {
            final entry = <String, dynamic>{
              'kind': 'toolCall',
              if (event.callId.isNotEmpty) 'id': event.callId,
              'name': event.name,
              'args': event.args,
            };
            allCalls.add(entry);
            // Same map in all three lists: id/status/output patches
            // below land in the persisted toolCalls and items alike.
            roundItems.add(entry);
            allItems.add(entry);
            // Execute now, call_id or not: performing the action
            // needs only its name and arguments. The id is resolved
            // when the round ends, before the follow-up is built.
            if (kDebugMode) {
              texaDiag(
                'ai',
                'round $round tool START (streaming) name=${event.name} callId=${event.callId.isEmpty ? 'MISSING' : event.callId} args=${diagJson(event.args)} inFlight=${inFlight.length + 1}',
              );
            }
            inFlight.add(
              _InFlightToolCall(
                call: event,
                entry: entry,
                outcome: runToolCall(event),
                callId: event.callId,
              ),
            );
          }
        }
      }
      // Null (or closed) means the round was aborted by [close]; end
      // the turn without emitting a done event or a bogus error.
      final result = completed;
      if (kDebugMode) {
        texaDiag(
          'ai',
          'round $round stream-end completed=${result != null} closed=${_isCancelled(cancellation)} inFlight=${inFlight.map((f) => '${f.call.name}:${f.callId.isEmpty ? 'MISSING' : f.callId}').join(',')} streamedText=${diagText(roundStreamedText.toString())}',
        );
      }
      if (result == null || _isCancelled(cancellation)) return;
      if (kDebugMode) {
        texaDiag(
          'ai',
          'round $round completed responseId=${result.responseId} text=${diagText(result.text)} calls=${result.calls.map((c) => '${c.name}:${c.callId.isEmpty ? 'MISSING' : c.callId}:${diagJson(c.args)}').join(' | ')} reasoning=${result.reasoning.map((r) => '${r['id']}:${((r['encrypted_content'] ?? '') as String).isEmpty ? 'NOENC' : diagText(r['encrypted_content'] as String)}').join(',')}',
        );
      }
      if (result.responseId != null && result.responseId!.isNotEmpty) {
        // Diagnostics only: stateless requests are never chained onto.
        responseIds.add(result.responseId!);
      }
      fullText.write(result.text);
      flushRoundText();
      if (result.calls.isEmpty || wrapUpNext) break;
      // No executor: keep the old single-request behaviour. The calls
      // were still streamed above so the caller can perform them;
      // their unanswered outputs keep the next turn off the chain.
      if (executeToolCall == null) {
        flushRoundText();
        // Reasoning captured in the round but never streamed (e.g.
        // only on the terminal event) still belongs in the order.
        for (final call in result.calls) {
          final entry = <String, dynamic>{
            'kind': 'toolCall',
            if (call.callId.isNotEmpty) 'id': call.callId,
            'name': call.name,
            'args': call.args,
          };
          allCalls.add(entry);
          allItems.add(entry);
        }
        toolOutputsPending = true;
        break;
      }

      // Defensive: any call the round reports that was not already
      // started as it streamed (the stream normally emits every one)
      // is started now, before its result is needed.
      //
      // Matching is POSITIONAL, and deliberately nothing else:
      // result.calls is _streamOneResponse's completedCalls, built in
      // exactly the order its AiToolCallComplete events were yielded
      // - and therefore exactly the order calls were started into
      // inFlight. So result.calls[i] is already running iff
      // i < inFlight.length. The previous identity matching (call_id,
      // else name+arguments) broke in release builds: streamed copies
      // often carry no call_id yet, and their argument JSON differs
      // cosmetically from the terminal copy (80 vs 80.0, key order),
      // so EVERY call failed to match and was executed a second time.
      final identityMatched = <int>{};
      for (var callIndex = 0; callIndex < result.calls.length; callIndex++) {
        final call = result.calls[callIndex];
        if (callIndex < inFlight.length) {
          continue;
        }
        // Belt-and-braces for a terminal list that contains a copy
        // the stream layer already suppressed at yield time (so it
        // never entered inFlight): never start a call whose call_id,
        // or normalised name+arguments, is already in flight.
        var alreadyRunning = false;
        for (var i = 0; i < inFlight.length; i++) {
          if (identityMatched.contains(i)) continue;
          final f = inFlight[i];
          if ((call.callId.isNotEmpty && f.callId == call.callId) ||
              ((f.callId.isEmpty || call.callId.isEmpty) &&
                  f.call.name == call.name &&
                  _canonicalArgsJson(jsonEncode(f.call.args)) ==
                      _canonicalArgsJson(jsonEncode(call.args)))) {
            identityMatched.add(i);
            alreadyRunning = true;
            break;
          }
        }
        if (alreadyRunning) continue;
        texaDiag(
          'ai',
          'round $round terminal call NOT streamed - starting now name=${call.name} callId=${call.callId} args=${diagJson(call.args)}',
        );
        final complete = AiToolCallComplete(
          call.name,
          call.args,
          callId: call.callId,
        );
        final entry = <String, dynamic>{
          'kind': 'toolCall',
          if (call.callId.isNotEmpty) 'id': call.callId,
          'name': call.name,
          'args': call.args,
        };
        allCalls.add(entry);
        roundItems.add(entry);
        allItems.add(entry);
        inFlight.add(
          _InFlightToolCall(
            call: complete,
            entry: entry,
            outcome: runToolCall(complete),
            callId: call.callId,
          ),
        );
      }

      // Patch in call_ids that only arrived with the completed
      // response. In-flight calls are in completion order, matching
      // result.calls; fall back to the first unresolved same-name
      // call when positions have shifted.
      final resolvedIndices = <int>{};
      for (var i = 0; i < inFlight.length; i++) {
        final pending = inFlight[i];
        if (pending.callId.isNotEmpty) continue;
        int? match;
        if (i < result.calls.length &&
            !resolvedIndices.contains(i) &&
            result.calls[i].name == pending.call.name &&
            result.calls[i].callId.isNotEmpty) {
          match = i;
        } else {
          for (var j = 0; j < result.calls.length; j++) {
            if (!resolvedIndices.contains(j) &&
                result.calls[j].name == pending.call.name &&
                result.calls[j].callId.isNotEmpty) {
              match = j;
              break;
            }
          }
        }
        if (match != null) {
          resolvedIndices.add(match);
          pending.callId = result.calls[match].callId;
          pending.entry['id'] = pending.callId;
        }
      }

      // Every call must be answered under the exact call_id the API
      // issued for it. A missing id can never be repaired locally -
      // a synthesised one (call_<name>) is rejected with a 400
      // ("function_call_output call_id ... does not match any
      // function_call in the request or its previous_response_id
      // chain") - so fail the turn rather than send a doomed
      // follow-up.
      for (final pending in inFlight) {
        if (pending.callId.isEmpty) {
          throw AppError(
            'Meta AI asked for an action (${pending.call.name}) without '
            'a call id, so its result could not be sent back. Your '
            'work is safe on the board.',
          );
        }
      }

      // Collect every outcome of the round (most already finished
      // while the response was streaming) and answer ALL of them in
      // the single follow-up request made by the next round - never
      // one request per call, which would break the history.
      final outputs = <Map<String, dynamic>>[];
      final answeredCallIds = <String>{};
      final firstOutcomeByCallId = <String, AiToolResult>{};
      for (final pending in inFlight) {
        if (pending.callId.isNotEmpty && !answeredCallIds.add(pending.callId)) {
          // Exactly one function_call_output per call_id, always -
          // a duplicate is a hard API rejection, not a retryable
          // error. Skip the second copy's output entirely.
          texaDiag(
            'ai',
            'round $round output SUPPRESSED duplicate callId=${pending.callId} name=${pending.call.name}',
          );
          final first = firstOutcomeByCallId[pending.callId];
          if (first != null) {
            pending.entry['status'] = first.success ? 'success' : 'error';
            pending.entry['output'] = first.wireOutput;
          }
          continue;
        }
        texaDiag(
          'ai',
          'round $round await outcome name=${pending.call.name} callId=${pending.callId.isEmpty ? 'MISSING' : pending.callId}',
        );
        // Race the outcome against cancellation: an interrupted
        // turn must end even if the action in flight never reports
        // back (its result is stale by then and must not be sent).
        final outcome = await Future.any<AiToolResult>([
          pending.outcome,
          cancellation.signal.then(
            (_) => const AiToolResult.failure('Turn was interrupted.'),
          ),
        ]);
        texaDiag(
          'ai',
          'round $round outcome name=${pending.call.name} callId=${pending.callId} success=${outcome.success} output=${diagText(outcome.wireOutput)}',
        );
        if (_isCancelled(cancellation)) return;
        pending.entry['status'] = outcome.success ? 'success' : 'error';
        pending.entry['output'] = outcome.wireOutput;
        if (pending.callId.isNotEmpty) {
          firstOutcomeByCallId[pending.callId] = outcome;
        }
        outputs.add({
          'type': 'function_call_output',
          'call_id': pending.callId,
          'output': outcome.wireOutput,
        });
      }
      // Safety valve: after too many tool rounds, one last request
      // with tools disabled lets the model wrap up in words instead
      // of looping (or leaving its last calls unanswered) forever.
      if (round >= maxToolRounds) wrapUpNext = true;
      {
        // Self-contained follow-up: the whole turn input, then this
        // round's calls and their outputs, with no stored response
        // to chain on.
        // Ordered round items (reasoning, text, calls) then all
        // outputs together - aiItemsToInput would interleave each
        // output after its call, so build calls from roundItems and
        // append the batched outputs after them.
        nextInput = [
          ...replayFollowUpInput,
          for (final item in aiItemsToInput(roundItems, 'round'))
            if (item['type'] != 'function_call_output') item,
          ...outputs,
        ];
        replayFollowUpInput = nextInput;
        texaDiag(
          'ai',
          'round $round followup outputs=${outputs.map((o) => o['call_id']).join(',')} nextInput=${diagInputSummary(nextInput)} allItems=${allItems.map((i) => i['kind'] == 'toolCall'
              ? 'call(${i['name']}:${i['id'] ?? 'MISSING'})'
              : i['kind'] == 'text'
              ? 'text(${diagText(i['text'] as String? ?? '')})'
              : 'reasoning(${i['id'] ?? 'noid'})').join(',')}',
        );
      }
    }

    final raw = <String, dynamic>{
      'text': fullText.toString(),
      'items': allItems,
      'toolCalls': allCalls,
      'toolOutputsPending': toolOutputsPending,
      'responseId': null,
      'responseIds': responseIds,
    };
    texaDiag(
      'ai',
      'turn done text=${diagText(fullText.toString())} calls=${allCalls.map((c) => '${c['name']}:${c['id'] ?? 'MISSING'}:${c['status'] ?? 'nostatus'}').join(' | ')} items=${allItems.map((i) => i['kind']).join(',')} responseIds=$responseIds',
    );
    yield AiStreamDone(raw, fullText.toString(), responseId: null);
  }

  /// Streams a single stateless Responses API request (`store:
  /// false` unless [storeResponse] is set) and finishes with a
  /// [_ResponseRound] describing the completed response: its id, its
  /// full text and every function call it asked for, with real call ids.
  Stream<AiEvent> _streamOneResponse({
    required _RequestCancellation cancellation,
    required String model,
    required String instructions,
    required List<Map<String, dynamic>> input,
    required String? reasoningEffort,
    required bool allowTools,
    bool storeResponse = false,
    bool includeTools = true,
  }) async* {
    final fullText = StringBuffer();
    final argBuffers = <String, StringBuffer>{};
    final callNames = <String, String>{};
    final callIds = <String, String>{};
    final callOrder = <String>[];
    final completedCalls =
        <({String callId, String name, Map<String, dynamic> args})>[];
    final emittedTools = <String>{};
    final reasoningItems = <Map<String, dynamic>>[];
    final seenReasoning = <String>{};
    bool captureReasoning(dynamic item) {
      if (item is! Map || item['type'] != 'reasoning') return false;
      final map = item.cast<String, dynamic>();
      final id = (map['id'] ?? '').toString();
      final enc = (map['encrypted_content'] ?? '').toString();
      for (var i = 0; i < reasoningItems.length; i++) {
        final existing = reasoningItems[i];
        final sameId = id.isNotEmpty && existing['id']?.toString() == id;
        final sameEnc =
            enc.isNotEmpty && existing['encrypted_content']?.toString() == enc;
        if (sameId || sameEnc) {
          // Same reasoning item reported again (e.g. only the terminal
          // copy carries encrypted_content): upgrade the stored copy
          // so the encrypted payload is not lost to the first, poorer
          // copy. Report it again only if it actually gained the
          // encrypted payload.
          final hadEnc = (existing['encrypted_content'] ?? '')
              .toString()
              .isNotEmpty;
          if (!hadEnc && enc.isNotEmpty) {
            reasoningItems[i] = {...existing, ...map};
            texaDiag(
              'ai',
              'reasoning upgraded with encrypted id=$id enc=${diagText(enc)}',
            );
            return true;
          }
          return false;
        }
      }
      final key = id.isNotEmpty ? id : enc;
      if (key.isNotEmpty && !seenReasoning.add(key)) {
        texaDiag(
          'ai',
          'reasoning duplicate skipped id=$id enc=${diagText(enc)}',
        );
        return false;
      }
      reasoningItems.add(map);
      texaDiag(
        'ai',
        'reasoning captured id=${id.isEmpty ? 'none' : id} enc=${enc.isEmpty ? 'MISSING' : diagText(enc)} count=${reasoningItems.length}',
      );
      return true;
    }

    final completedIndexByKey = <String, int>{};
    String? responseId;
    var sawEvent = false;

    void registerCall(String key, String? name, String? callId) {
      if (!argBuffers.containsKey(key)) {
        argBuffers[key] = StringBuffer();
        callOrder.add(key);
      }
      if (name != null && name.isNotEmpty) callNames[key] = name;
      if (callId != null && callId.isNotEmpty) {
        callIds[key] = callId;
        // A call completed before its id arrived (the arguments events
        // carry no call_id; it only appears on the output item) gets
        // the real id patched in - never a synthesised substitute.
        final index = completedIndexByKey[key];
        if (index != null && completedCalls[index].callId.isEmpty) {
          final done = completedCalls[index];
          completedCalls[index] = (
            callId: callId,
            name: done.name,
            args: done.args,
          );
        }
      }
    }

    /// Every identifier ever seen for one physical call, mapped to
    /// the key that call is tracked under. Stream events for the same
    /// call variously carry `output_index`, the item `id`, and the
    /// `call_id` - and not consistently from one event to the next
    /// (in release builds against the real provider, the arguments
    /// events may key by output_index while the item/terminal events
    /// key by item id, with call_id only on the last of them). Any
    /// identifier that has been bound once resolves the call forever
    /// after, regardless of which identifier a later event carries.
    final callKeyAliases = <String, String>{};

    String bindCallKey({
      Object? outputIndex,
      String? itemId,
      String? callId,
      String? name,
      String? arguments,
    }) {
      final identifiers = <String>[
        if (outputIndex != null) 'idx:$outputIndex',
        if (itemId != null && itemId.isNotEmpty) 'item:$itemId',
        if (callId != null && callId.isNotEmpty) 'call:$callId',
      ];
      for (final id in identifiers) {
        final bound = callKeyAliases[id];
        if (bound != null) {
          for (final other in identifiers) {
            callKeyAliases[other] = bound;
          }
          return bound;
        }
      }
      // Known call_id carried under a key bound before the id arrived.
      if (callId != null && callId.isNotEmpty) {
        for (final key in callOrder) {
          if (callIds[key] == callId) {
            for (final id in identifiers) {
              callKeyAliases[id] = key;
            }
            return key;
          }
        }
      }
      // A call announced by output_item.added (which may carry no
      // output_index) and still waiting for its arguments: the
      // arguments events for it key by output_index alone, so bind
      // them to that pending call instead of minting a second one.
      if (name != null && name.isNotEmpty) {
        for (final key in callOrder) {
          if (callNames[key] == name &&
              !emittedTools.contains(key) &&
              (argBuffers[key]?.isEmpty ?? true)) {
            for (final id in identifiers) {
              callKeyAliases[id] = key;
            }
            return key;
          }
        }
      }
      // Last resort before minting a new key: same name + canonical
      // arguments as a call already tracked.
      if (name != null && arguments != null && arguments.isNotEmpty) {
        final wanted = _canonicalArgsJson(arguments);
        for (final key in callOrder) {
          final knownId = callIds[key];
          if (knownId != null && knownId.isNotEmpty && knownId != callId) {
            continue;
          }
          if (callNames[key] == name &&
              _canonicalArgsJson(argBuffers[key].toString()) == wanted) {
            for (final id in identifiers) {
              callKeyAliases[id] = key;
            }
            return key;
          }
        }
      }
      final primary = identifiers.isNotEmpty
          ? identifiers.first
          : 'anon:${callOrder.length}';
      for (final id in identifiers) {
        callKeyAliases[id] = primary;
      }
      return primary;
    }

    AiToolCallComplete? finishCall(String key) {
      if (emittedTools.contains(key)) {
        texaDiag(
          'ai',
          'call SUPPRESSED duplicate key=$key name=${callNames[key]} callId=${callIds[key]} args=${diagText(argBuffers[key]?.toString() ?? '')} completed=${completedCalls.length}',
        );
        return null;
      }
      final name = callNames[key] ?? '';
      if (name.isEmpty) {
        texaDiag('ai', 'call skipped no-name key=$key');
        return null;
      }
      // Emit as soon as the arguments are whole, even when the
      // call_id has not appeared yet: execution needs only name and
      // arguments. When the id does arrive (output item, or the
      // terminal response), registerCall patches it into
      // [completedCalls] below - never a synthesised substitute.
      final callId = callIds[key] ?? '';
      emittedTools.add(key);
      final args = decodeArgs(argBuffers[key]?.toString() ?? '');
      completedIndexByKey[key] = completedCalls.length;
      completedCalls.add((callId: callId, name: name, args: args));
      texaDiag(
        'ai',
        'call EMIT key=$key name=$name callId=${callId.isEmpty ? 'MISSING' : callId} args=${diagJson(args)} completed=${completedCalls.length}',
      );
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
      // One POST to the Responses endpoint, streamed back as SSE.
      // No retries: a failed turn is surfaced (and retried by the
      // student) instead of silently resent.
      final sseStream = await _sse.subscribe(
        method: SseRequestType.post,
        url: _responsesUrl,
        header: {..._headers, 'Accept': 'text/event-stream'},
        body: {
          'model': model,
          'instructions': instructions,
          'input': input,
          'parallel_tool_calls': true,
          'store': storeResponse,
          // Stateless reasoning replay (Meta docs): always request
          // encrypted reasoning; there is no previous_response_id it
          // could conflict with.
          'include': const ['reasoning.encrypted_content'],
          if (includeTools) 'tools': toolSchemas(),
          if (includeTools) 'tool_choice': allowTools ? 'auto' : 'none',
          if (reasoningEffort != null) 'reasoning': {'effort': reasoningEffort},
          'stream': true,
        },
        abortTrigger: cancellation.signal,
      );
      if (_isCancelled(cancellation)) return;
      await for (final sseEvent in _untilCancelled(
        sseStream
            .map((sseEvent) {
              final data = sseEvent.data?.trim() ?? '';
              if (data.isEmpty || data == '[DONE]') return null;
              try {
                final decoded = jsonDecode(data);
                return decoded is Map<String, dynamic> ? decoded : null;
              } on FormatException {
                // Partial/garbled event: skip it, the next one may
                // still complete the response.
                return null;
              }
            })
            .where((event) => event != null)
            .cast<Map<String, dynamic>>()
            // Idle timeout: fires only when no event has arrived for
            // this long, not over the life of a healthy stream.
            .timeout(const Duration(seconds: responseTimeoutSeconds)),
        cancellation,
      )) {
        final event = sseEvent;
        sawEvent = true;
        if (event['type'] == null && event['error'] != null) {
          final error = event['error'];
          final message = error is Map
              ? (error['message'] as String? ?? '')
              : '';
          throw AppError(
            'Meta AI rejected that turn. ${message.length > 140 ? '' : message} Your work is safe on the board.',
          );
        }
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
            final key = bindCallKey(
              outputIndex: event['output_index'],
              itemId: event['item_id'] as String?,
              callId: event['call_id'] as String?,
            );
            registerCall(key, null, event['call_id'] as String?);
            final delta = event['delta'];
            if (delta is String) argBuffers[key]!.write(delta);
          case 'response.function_call_arguments.done':
            final key = bindCallKey(
              outputIndex: event['output_index'],
              itemId: event['item_id'] as String?,
              callId: event['call_id'] as String?,
              name: event['name'] as String?,
              arguments: event['arguments'] as String?,
            );
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
          case 'response.output_item.added':
            // The earliest event carrying the call_id (and name) for a
            // function call - well before its arguments finish. Only
            // register it here; the call completes on arguments.done /
            // output_item.done once its arguments are whole.
            final item = event['item'];
            if (item is Map && item['type'] == 'function_call') {
              final key = bindCallKey(
                outputIndex: event['output_index'],
                itemId: item['id'] as String?,
                callId: item['call_id'] as String?,
                name: item['name'] as String?,
              );
              registerCall(
                key,
                item['name'] as String?,
                item['call_id'] as String?,
              );
            }
          case 'response.output_item.done':
            final item = event['item'];
            if (item is Map && item['type'] == 'reasoning') {
              if (captureReasoning(item)) {
                yield AiReasoningComplete(reasoningItems.last);
              }
            }
            if (item is Map && item['type'] == 'function_call') {
              final key = bindCallKey(
                outputIndex: event['output_index'],
                itemId: item['id'] as String?,
                callId: item['call_id'] as String?,
                name: item['name'] as String?,
                arguments: item['arguments'] as String?,
              );
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
            {
              final r = event['response'];
              final o = r is Map ? r['output'] : null;
              texaDiag(
                'ai',
                'response.completed id=$responseId output=${o is List ? o.map((i) => i is Map ? '${i['type']}:${i['id'] ?? i['call_id'] ?? ''}:${i['name'] ?? ''}' : '?').join(' | ') : 'none'} textSoFar=${diagText(fullText.toString())} callsSoFar=${completedCalls.map((c) => '${c.name}:${c.callId.isEmpty ? 'MISSING' : c.callId}').join(' | ')}',
              );
            }
            // Fallback: emit any function calls the terminal event carries
            // that were not already completed mid-stream.
            final response = event['response'];
            final output = response is Map ? response['output'] : null;
            if (output is List) {
              for (var outIndex = 0; outIndex < output.length; outIndex++) {
                final item = output[outIndex];
                if (item is Map && item['type'] == 'reasoning') {
                  if (captureReasoning(item)) {
                    yield AiReasoningComplete(reasoningItems.last);
                  }
                }
                if (item is Map && item['type'] == 'function_call') {
                  // The item's position in the terminal output is its
                  // output_index - the same identity the streaming
                  // events for this call were keyed by.
                  final key = bindCallKey(
                    outputIndex: outIndex,
                    itemId: item['id'] as String?,
                    callId: item['call_id'] as String?,
                    name: item['name'] as String?,
                    arguments: item['arguments'] as String?,
                  );
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
    } on SseHttpException catch (e) {
      if (_isCancelled(cancellation)) return;
      debugPrint(e.message);
      if (e.statusCode == 429) {
        throw const AppError(
          'Meta AI is busy right now. Wait a moment, then retry your turn.',
        );
      }
      final message = e.message;
      throw AppError(
        'Meta AI rejected that turn (${e.statusCode}). ${message.length > 140 ? '' : message} Your work is safe on the board.',
        cause: e,
      );
    } on TimeoutException catch (e) {
      if (_isCancelled(cancellation)) return;
      throw AppError(
        'Meta AI took too long to reply. Please retry your turn.',
        cause: e,
      );
    } on AppError {
      if (_isCancelled(cancellation)) return;
      rethrow;
    } catch (e) {
      if (_isCancelled(cancellation)) return;
      debugPrint("Meta AI API call failed: $e");
      throw AppError(
        'Could not reach Meta AI. Check your connection and retry your turn.',
        cause: e,
      );
    }
    // Cancelled mid-stream and the stream simply ended: that is an
    // abort, not a reply, so emit no round at all.
    if (_isCancelled(cancellation)) return;
    if (!sawEvent) {
      throw const AppError(
        'Meta AI returned an empty reply. Please retry your turn.',
      );
    }
    for (final key in callOrder) {
      // Last resort for a stream that ended without an output item:
      // surface the call even without an id. streamTurn refuses to
      // answer such a call (see there) rather than inventing an id.
      final done = finishCall(key);
      if (done != null) yield done;
    }
    yield _ResponseRound(
      responseId: responseId,
      text: fullText.toString(),
      calls: completedCalls,
      reasoning: reasoningItems,
    );
  }
}

/// One request/turn's cancellation signal: completing it aborts the
/// in-flight HTTP request (via its abort trigger) and promptly ends
/// the locally-awaited stream. A fresh instance per turn is what lets
/// one long-lived [AiClient] offer the isolation a fresh client per
/// turn used to provide.
class _RequestCancellation {
  final Completer<void> _completer = Completer<void>();

  bool get isCancelled => _completer.isCompleted;
  Future<void> get signal => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}
