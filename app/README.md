# Texa

The personal AI tutor for everyone — a shared 1200×1600 whiteboard with a voice tutor.

## Run it

1. Start the local speech-model server (from this folder): `bash models/startserver.sh` from this folder (serves `models/` on port 8765).
2. Launch the **App (dev debug)** config in `.vscode/launch.json`, or run with the same dart-defines for `KOKORO_MODEL_URL`, `SILERO_VAD_MODEL_URL` and `SMART_TURN_MODEL_URL`. Without defines, builds download the production models on first launch.
3. First launch: paste a Meta AI API key and tap **Test connection**, allow (or skip) the microphone, and wait for the speech models to download and verify — setup completes only once Kokoro and Silero are initialised.
4. Create a session (pick its model — it is fixed for that session), draw your problem, and either talk while drawing or type a question and tap **Ask Texa**.

## How it works

- **Streaming end to end:** the Meta AI reply is consumed as a server-sent event stream. Text flows through an incremental sentence splitter (`StreamingSpeechSplitter`) that emits a chunk the moment a sentence terminator arrives; that chunk is synthesised and queued for playback while the next one is being made (prefetch depth 1). Completed tool calls start drawing as soon as they finish, without waiting for the whole reply.
- The `<[IGNORE_TURN]>` sentinel is honoured before anything is spoken or drawn: a first sentence is held until the reply can no longer be the sentinel (a tool call, a second sentence, or end of stream).
- Board, messages and settings persist locally (tostore). Every turn — spoken or typed — is encoded the same way on every platform (Android, iOS, macOS, Web): one MP4 at 1 FPS, 540×720, with embedded 16 kHz audio (silence-padded for typed turns). If encoding fails, the turn is not sent and the student is asked to try again; the board is never touched.
- Speaking (detected by Silero VAD, the single voice detector on every platform), drawing or tapping **Stop** interrupts the tutor. A brief noise (<300 ms) resumes from the interrupted sentence; a real interruption becomes the next turn with interruption context, and the model may call `resume_explanation`.

## Checks

- `flutter analyze` — clean
- `flutter test` — unit tests (splitter, WAV, sentinel, plotter, suspend/resume, registry) and the Home widget test
- Regenerate strings after editing `lib/i18n/en.i18n.json`: `dart run slang`
