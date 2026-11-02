import { KokoroTTS, TextSplitterStream } from "kokoro-js";
import { env as hfEnv } from "@huggingface/transformers";
import * as piper from "@mintplex-labs/piper-tts-web";
import { floatToWav } from "./wav.js";
import { configureKokoroSource } from "./kokoro-source.js";

// One TTS engine/session alive at a time (mirrors native behaviour).
let engine = null;
let kokoro = null;
let kokoroDevice = null;
let piperSession = null;
const cancelled = new Set();

function configureHfWasm(wasmBaseUrl) {
  try {
    const wasm = hfEnv?.backends?.onnx?.wasm;
    if (wasm) {
      if (wasmBaseUrl) wasm.wasmPaths = wasmBaseUrl;
      wasm.numThreads = self.crossOriginIsolated
        ? Math.min(4, navigator.hardwareConcurrency || 1)
        : 1;
    }
  } catch (_) {}
}

async function initKokoro(msg) {
  configureHfWasm(msg.wasmBaseUrl);
  const modelId = configureKokoroSource(hfEnv, msg.kokoroBaseUrl);
  const progress_callback = (e) => {
    if (e && (e.status === "download" || e.status === "progress") && e.total > 0) {
      self.postMessage({ type: "progress", id: msg.id, file: e.file, loaded: e.loaded ?? 0, total: e.total });
    }
  };
  // Probe for a working WebGPU adapter up front: transformers.js only
  // checks `'gpu' in navigator`, so without this the failure (no adapter)
  // would only surface after the model download. The try/catch remains as
  // a safety net for session-creation failures on adapter-present GPUs.
  let adapter = null;
  try {
    adapter = (await navigator.gpu?.requestAdapter()) ?? null;
  } catch (_) {}
  const preferred = adapter ? "webgpu" : "wasm";
  console.info(`[tts-worker] Kokoro: using ${preferred}${preferred === "wasm" && self.crossOriginIsolated ? " (threaded)" : ""}`);
  try {
    kokoro = await KokoroTTS.from_pretrained(modelId, { dtype: "fp32", device: preferred, progress_callback });
    kokoroDevice = preferred;
  } catch (e) {
    console.warn(`[tts-worker] Kokoro ${preferred} init failed, falling back to wasm`, e);
    kokoro = await KokoroTTS.from_pretrained(modelId, { dtype: "fp32", device: "wasm", progress_callback });
    kokoroDevice = "wasm";
  }
  console.info(`[tts-worker] Kokoro ready on ${kokoroDevice}`);
  engine = "kokoro";
}

async function initPiper(msg) {
  // Piper self-provisions its model into OPFS on first use; no Dart-side
  // download for Piper on web. Local ORT wasm is used when provided, the
  // phonemizer wasm/data fall back to the library defaults (CDN download).
  const options = {
    voiceId: msg.voiceId ?? "en_US-amy-medium",
    progress: (e) => {
      if (e && e.total > 0) self.postMessage({ type: "progress", id: msg.id, file: e.url, loaded: e.loaded ?? 0, total: e.total });
    },
  };
  // wasmPaths is all-or-nothing in piper-tts-web: passing only a local
  // ORT path would leave the phonemizer wasm/data undefined. Only set it
  // when the caller supplied every path; otherwise the library defaults
  // (CDN phonemizer + ORT) apply.
  if (msg.wasmBaseUrl && msg.piperDataUrl && msg.piperWasmUrl) {
    options.wasmPaths = {
      onnxWasm: msg.wasmBaseUrl,
      piperData: msg.piperDataUrl,
      piperWasm: msg.piperWasmUrl,
    };
  }
  piperSession = await piper.TtsSession.create(options);
  engine = "piper";
}

self.onmessage = async (e) => {
  const msg = e.data;
  try {
    if (msg.type === "init") {
      if (engine === msg.engine) {
        self.postMessage({
          type: "ready",
          id: msg.id,
          engine,
          device: kokoroDevice,
        });
        return;
      }
      kokoro = null;
      piperSession = null;
      engine = null;
      if (msg.engine === "kokoro") await initKokoro(msg);
      else if (msg.engine === "piper") await initPiper(msg);
      else throw new Error(`Unknown engine ${msg.engine}`);
      self.postMessage({
        type: "ready",
        id: msg.id,
        engine,
        device: kokoroDevice,
      });
    } else if (msg.type === "cancel") {
      cancelled.add(msg.requestId);
    } else if (msg.type === "synthesise") {
      if (!engine) throw new Error("TTS not initialised");
      if (engine === "kokoro") {
        // Stream sentence-by-sentence like native (maxNumSentences=1);
        // Dart already sentence-splits, kokoro.stream refines further.
        // The splitter must be closed: without close() its final (here:
        // usually only) sentence stays buffered and stream() never yields.
        const splitter = new TextSplitterStream();
        splitter.push(msg.text);
        splitter.close();
        for await (const part of kokoro.stream(splitter, {
          voice: msg.voice ?? "af_heart",
        })) {
          if (cancelled.has(msg.id)) break;
          const audio = part.audio;
          console.info(`[tts-worker] Kokoro segment: ${audio.audio.length} samples @ ${audio.sampling_rate}Hz`);
          const wav = floatToWav(audio.audio, audio.sampling_rate);
          self.postMessage({ type: "audio", id: msg.id, wav: wav.buffer }, [
            wav.buffer,
          ]);
        }
      } else {
        const blob = await piperSession.predict(msg.text);
        if (!cancelled.has(msg.id)) {
          const buf = await blob.arrayBuffer();
          self.postMessage({ type: "audio", id: msg.id, wav: buf }, [buf]);
        }
      }
      cancelled.delete(msg.id);
      self.postMessage({ type: "done", id: msg.id });
    }
  } catch (err) {
    self.postMessage({
      type: "error",
      id: msg.id,
      forType: msg.type,
      message: String(err?.message ?? err),
    });
  }
};
