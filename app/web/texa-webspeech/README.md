# texa-webspeech

Web speech for Texa, used instead of sherpa-onnx on web (native keeps
Sherpa). Two dedicated workers, because VAD/barge-in must stay
responsive while TTS is generating:

| Output | Worker | Contents |
|---|---|---|
| `../speech_worker.js` | realtime | Silero VAD v6.2 (raw `onnxruntime-web`, Sherpa-equivalent state machine) + Smart Turn v3 (soniqo int8, raw-waveform input — preprocessing is baked into the graph) |
| `../speech_tts_worker.js` | TTS | Kokoro via `kokoro-js` (fp32, WebGPU first, threaded-WASM fallback, voice `af_heart`) or Piper via `@mintplex-labs/piper-tts-web` (self-provisions into OPFS). One engine alive at a time. |
| `../ort-wasm/` | — | Single `onnxruntime-web` wasm set shared by both workers (`env.wasm.wasmPaths`) |

Transformers.js is pinned to 4.3.2 and forced into `kokoro-js` via
`overrides` in `package.json`.

## Build

```sh
npm install
npm run build   # writes ../speech_worker.js, ../speech_tts_worker.js, ../ort-wasm/
```

Run this before `flutter build web`. The built outputs are checked in
so a plain Flutter build works without Node.

Web Kokoro source: `KOKORO_WEB_BASE_URL` (Dart `--dart-define`,
default `https://huggingface.co/sitatech/Kokoro-82M-v1.0-ONNX/resolve/main/`).
For a local mirror, download that repo under
`<models-dir>/sitatech/Kokoro-82M-v1.0-ONNX/` and pass e.g.
`--dart-define=KOKORO_WEB_BASE_URL=http://localhost:8765/sitatech/Kokoro-82M-v1.0-ONNX/`.
Download progress from kokoro-js/Piper is forwarded to the Flutter
setup/settings progress bars (indeterminate until the first byte count).

Notes:
- Multi-threaded WASM (and the Kokoro WASM fallback) needs
  `crossOriginIsolated` (COOP/COEP response headers); otherwise ORT
  silently uses 1 thread. WebGPU needs none of this.
- After a production Flutter web build, the sherpa-onnx web plugin
  assets under `build/web/assets/packages/sherpa_onnx_web/` can be
  deleted — no Dart code imports sherpa on web anymore (conditional
  imports in `speech_engine.dart` / `model_store_web.dart`).
- Piper's phonemizer wasm/data use the library's CDN defaults
  (`wasmPaths` is all-or-nothing there); only its model download/OPFS
  caching is relied upon.
