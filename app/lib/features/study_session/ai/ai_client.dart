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
      previousResponseId: null,
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
    final text = completed?.text.trim() ?? '';
    if (text.isEmpty) {
      throw const AppError('Transcription returned an empty record.');
    }
    return text;
  }

  /// Set by [close]. A closed client must never start another round of
  /// the agentic loop: after an interrupt the tool outputs of the round
  /// that was in flight are stale and must not be sent to the model.
  bool _closed = false;

  /// Completed by [close] so a stream blocked waiting for the model's
  /// first token (e.g. while it is still thinking) ends immediately,
  /// instead of whenever the transport gets around to noticing the
  /// close - on web a closed client may not abort an in-flight fetch
  /// at all, which used to make thinking turns un-interruptible.
  final Completer<void> _closeSignal = Completer<void>();

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

  /// Closes the underlying transport, aborting any request in flight.
  ///
  /// This is the session controller's abort handle for the current turn.
  /// A turn interrupted this way ends silently (no error is surfaced for
  /// a cancellation the app itself requested); see the `_closed` guards
  /// in [streamTurn] and [_streamOneResponse].
  void close() {
    _closed = true;
    if (!_closeSignal.isCompleted) _closeSignal.complete();
    _client.close();
  }

  /// Races [source] against [close]: when the client is closed the
  /// returned stream ends promptly (cancelling the source) even if the
  /// source is blocked waiting for its first event - e.g. while the
  /// model is still thinking, where closing the transport alone may
  /// not unblock the await (notably on web). Ending without an error
  /// is deliberate: callers treat a closed client as a silent abort.
  Stream<T> _untilClosed<T>(Stream<T> source) {
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
        _closeSignal.future.then((_) {
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
        // source suspended in `await client.send()` (still awaiting
        // response headers / first token) only completes when that
        // await does, and returning that future from onCancel holds
        // this controller's done event hostage until then - which is
        // exactly the abort we are trying to perform. (Found by
        // reproduction: with the await, close() during the
        // awaiting-headers phase never ended the stream.)
        if (sub != null) unawaited(sub.cancel().catchError((_) {}));
      },
    );
    return controller.stream;
  }

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
          .list(
            client: _NonClosingClient(
              _client,
              abortTrigger: _closeSignal.future,
            ),
          )
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
    final retainedVideoIndices = retainedVideoBudget <= 0
        ? const <int>{}
        : earlierVideoIndices
              .skip(
                earlierVideoIndices.length > retainedVideoBudget
                    ? earlierVideoIndices.length - retainedVideoBudget
                    : 0,
              )
              .toSet();
    // With a stored previous response the server already holds the whole
    // conversation, so only this turn's new input is sent. The full
    // replay below is the bootstrap for sessions that have no stored
    // response id yet (new or legacy sessions) and - once the video
    // window is active - the only way to replace older videos with
    // transcripts, since a chained request keeps every video the
    // server has ever stored for the chain (see [streamTurn]).
    if (includeHistory) {
      for (var index = 0; index < history.length; index++) {
        final m = history[index];
        if (index == currentIndex) continue;
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
        } else if (isStudentVideoTurn(m)) {
          final video = m.payload['videoBase64'] as String;
          if (retainedVideoIndices.contains(index)) {
            input.add({
              'role': 'user',
              'content': [
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
                  'text': transcript != null
                      ? '[Transcript of an earlier student turn - originally a board-and-voice video, transcribed because only the newest turns are sent as video. The quoted words are the student\'s own; the surrounding descriptions record what was on the board and what the student pointed at or did.]\n$transcript'
                      : '[An earlier student turn was given as a board-and-voice video. Its transcript is unavailable, so its exact content could not be included here. Rely on the surrounding conversation and the current board, and ask the student if that turn matters.]',
                },
              ],
            });
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
      // Inputs of earlier turns that were cancelled before the model
      // produced anything (interrupted while thinking): they were
      // never answered, so they ride along *before* this turn's own
      // content and the model answers them together with it.
      for (final prior in effectivePriorVideos)
        {'type': 'input_video', 'video_url': 'data:video/mp4;base64,$prior'},
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
  /// Every tutor request is sent with `store: true`. When a previous
  /// stored response is known (passed explicitly or found in the saved
  /// AI messages in [history]) only this turn's new input plus
  /// `previous_response_id` is sent - the history itself is never
  /// replayed. That chaining is only used while the whole session fits
  /// in the video window ([maxVideoTurnsPerRequest] student videos):
  /// a chained request keeps every video ever stored on the chain, so
  /// past the window every turn instead replays the local history -
  /// transcripts for older student turns, videos for the newest ones -
  /// with no `previous_response_id`, and the fresh response becomes
  /// the (unchained-from) record of that turn. Each response that asks for tool calls has every call
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
    List<String> priorVideosBase64 = const [],
  }) async* {
    final currentInHistory = history.any(
      (m) => isStudentVideoTurn(m) && m.payload['videoBase64'] == videoBase64,
    );
    final videoTurnCount =
        studentVideoTurns(history).length + (currentInHistory ? 0 : 1);
    final chainedId = previousResponseId ?? latestResponseId(history);
    final useChain =
        chainedId != null && videoTurnCount <= maxVideoTurnsPerRequest;
    var previousId = useChain ? chainedId : null;
    final request = _requestInput(
      history: history,
      videoBase64: videoBase64,
      interruptionContext: interruptionContext,
      studentMemory: studentMemory,
      recentObservations: recentObservations,
      currentObservation: currentObservation,
      uploads: uploads,
      extraContext: extraContext,
      includeHistory: !useChain,
      priorVideosBase64: priorVideosBase64,
    );

    final fullText = StringBuffer();
    final allCalls = <Map<String, dynamic>>[];
    final responseIds = <String>[];
    List<Map<String, dynamic>> nextInput = request.input;
    var wrapUpNext = false;

    for (var round = 0; ; round++) {
      // Closed while the previous round (or its tool calls) was in
      // flight: the turn was interrupted, so do not send anything else.
      if (_closed) return;
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
      // Null (or closed) means the round was aborted by [close]; end
      // the turn without emitting a done event or a bogus error.
      final result = completed;
      if (result == null || _closed) return;
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

      // Every call must be answered under the exact call_id the API
      // issued for it. A missing id can never be repaired locally -
      // a synthesised one (call_<name>) is rejected with a 400
      // ("function_call_output call_id ... does not match any
      // function_call in the request or its previous_response_id
      // chain") - so fail the turn before performing any of the
      // round's calls instead of sending a doomed follow-up.
      for (final call in result.calls) {
        if (call.callId.isEmpty) {
          throw AppError(
            'Meta AI asked for an action (${call.name}) without a call '
            'id, so its result could not be sent back. Your work is '
            'safe on the board.',
          );
        }
      }

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
          final detail = e.toString();
          outcome = AiToolResult.failure(
            'The action failed: '
            '${detail.length > 200 ? detail.substring(0, 200) : detail}',
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
          'call_id': call.callId,
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
    bool storeResponse = true,
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

    AiToolCallComplete? finishCall(
      String key, {
      bool allowMissingCallId = false,
    }) {
      if (emittedTools.contains(key)) return null;
      final name = callNames[key] ?? '';
      if (name.isEmpty) return null;
      final callId = callIds[key] ?? '';
      // function_call_arguments.done fires *before* the output item
      // that carries the call_id, so finishing there would lock the
      // call in with an empty id. Wait for the id; the output-item and
      // response-completed events that follow supply it, and the
      // end-of-stream flush (allowMissingCallId) is the last resort.
      if (callId.isEmpty && !allowMissingCallId) return null;
      emittedTools.add(key);
      final args = decodeArgs(argBuffers[key]?.toString() ?? '');
      completedIndexByKey[key] = completedCalls.length;
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
      await for (final event in _untilClosed(
        _openAi.responses
            .createStream(
              model: model,
              instructions: instructions,
              input: input,
              store: storeResponse,
              previousResponseId: previousResponseId,
              tools: includeTools ? toolSchemas() : null,
              toolChoice: includeTools ? (allowTools ? 'auto' : 'none') : null,
              reasoning: reasoningEffort == null
                  ? null
                  : {'effort': reasoningEffort},
              // Never hand dart_openai the owned client directly: its
              // streaming pipeline unconditionally closes whatever
              // client it is given when the stream ends, so the first
              // round used to kill the transport and every follow-up
              // request (starting with the function_call_output round)
              // failed with "Client is already closed". The wrapper
              // absorbs that close; [_client] stays alive for every
              // round of the loop and is only closed by [close].
              client: _NonClosingClient(
                _client,
                abortTrigger: _closeSignal.future,
              ),
            )
            .timeout(const Duration(seconds: responseTimeoutSeconds)),
      )) {
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
          case 'response.output_item.added':
            // The earliest event carrying the call_id (and name) for a
            // function call - well before its arguments finish. Only
            // register it here; the call completes on arguments.done /
            // output_item.done once its arguments are whole.
            final item = event['item'];
            if (item is Map && item['type'] == 'function_call') {
              final key = (item['id'] ?? item['call_id'] ?? '').toString();
              registerCall(
                key,
                item['name'] as String?,
                item['call_id'] as String?,
              );
            }
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
      if (_closed) return;
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
      if (_closed) return;
      throw AppError(
        'Meta AI took too long to reply. Please retry your turn.',
        cause: e,
      );
    } on AppError {
      if (_closed) return;
      rethrow;
    } catch (e) {
      if (_closed) return;
      debugPrint("Meta AI API call failed: $e");
      throw AppError(
        'Could not reach Meta AI. Check your connection and retry your turn.',
        cause: e,
      );
    }
    // The transport was closed mid-stream and the stream simply ended:
    // that is an abort, not a reply, so emit no round at all.
    if (_closed) return;
    if (!sawEvent) {
      throw const AppError(
        'Meta AI returned an empty reply. Please retry your turn.',
      );
    }
    for (final key in callOrder) {
      // Last resort for a stream that ended without an output item:
      // surface the call even without an id. streamTurn refuses to
      // answer such a call (see there) rather than inventing an id.
      final done = finishCall(key, allowMissingCallId: true);
      if (done != null) yield done;
    }
    yield _ResponseRound(
      responseId: responseId,
      text: fullText.toString(),
      calls: completedCalls,
    );
  }
}

/// Delegates to [AiClient]'s owned client but ignores [close].
///
/// `dart_openai` closes the client passed to a streaming request in a
/// `finally` block, whether it created that client or the caller did.
/// Handing it this wrapper per request keeps ownership (and the actual
/// close) with [AiClient], so one client can serve every round of a
/// turn - including the `function_call_output` follow-ups.
/// Wraps the AiClient's owned transport for handing to dart_openai.
///
/// Two jobs:
///
///  * Absorb dart_openai's close: its streaming pipeline
///    unconditionally closes whatever client it is given when the
///    stream ends, which used to kill the transport after the first
///    round so every `function_call_output` follow-up failed with
///    "Client is already closed". [close] is a no-op here; the owned
///    client is only closed by `AiClient.close`.
///
///  * Give the request a real abort trigger. dart_openai has no
///    cancellation API (no `AbortSignal`-equivalent parameter; it
///    builds a plain `http.Request` internally), so the only lever is
///    the transport: package:http clients (BrowserClient/IOClient)
///    honour `AbortableRequest.abortTrigger` at every phase - before
///    the request is sent, while awaiting response headers, and while
///    streaming - exactly like the JS SDK's AbortSignal. Rewriting the
///    request here, with the trigger wired to the owner's close
///    signal, makes `AiClient.close()` abort the in-flight request at
///    the socket/fetch level instead of merely abandoning it locally.
class _NonClosingClient extends http.BaseClient {
  _NonClosingClient(this._inner, {this._abortTrigger});

  final http.Client _inner;
  final Future<void>? _abortTrigger;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final trigger = _abortTrigger;
    if (trigger == null ||
        request is http.MultipartRequest ||
        request is http.Abortable) {
      return _inner.send(request);
    }
    final bodyBytes = await request.finalize().toBytes();
    final abortable =
        http.AbortableRequest(
            request.method,
            request.url,
            abortTrigger: trigger,
          )
          ..headers.addAll(request.headers)
          ..bodyBytes = bodyBytes
          ..followRedirects = request.followRedirects
          ..maxRedirects = request.maxRedirects
          ..persistentConnection = request.persistentConnection;
    return _inner.send(abortable);
  }

  @override
  void close() {}
}
