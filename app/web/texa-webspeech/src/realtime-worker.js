import * as ort from 'onnxruntime-web';
import { predictSmartTurn } from './smart-turn.js';
import { SileroVad } from './silero-vad.js';

let vad = null; let smartTurn = null;
function configureOrt(wasmBaseUrl) {
  if (ort.env?.wasm) {
    if (wasmBaseUrl) ort.env.wasm.wasmPaths = wasmBaseUrl;
    ort.env.wasm.numThreads = self.crossOriginIsolated ? Math.min(2, navigator.hardwareConcurrency || 1) : 1;
  }
}
self.onmessage = async (e) => {
  const msg = e.data;
  try {
    if (msg.type === 'init') {
      configureOrt(msg.wasmBaseUrl);
      const opts = { executionProviders: ['wasm'] };
      const vadSession = await ort.InferenceSession.create(msg.vadModel, opts);
      vad = new SileroVad(vadSession, ort, msg.config ?? {});
      if (msg.smartTurnModel) {
        const stSession = await ort.InferenceSession.create(msg.smartTurnModel, opts);
        const threshold = msg.smartTurnThreshold ?? 0.5;
        smartTurn = { predict: (samples) => predictSmartTurn(stSession, ort, samples, threshold) };
      }
      self.postMessage({ type: 'ready', id: msg.id, smartTurn: !!smartTurn });
    } else if (msg.type === 'vad') {
      if (!vad) throw new Error('VAD not initialised');
      const r = await vad.acceptWaveform(new Float32Array(msg.samples));
      self.postMessage({ type: 'vad-result', id: msg.id, detected: r.detected, probability: r.probability });
    } else if (msg.type === 'smart-turn') {
      if (!smartTurn) { self.postMessage({ type: 'smart-turn-result', id: msg.id, probability: 1, complete: true, available: false }); return; }
      const r = await smartTurn.predict(new Float32Array(msg.samples));
      self.postMessage({ type: 'smart-turn-result', id: msg.id, probability: r.probability, complete: r.complete, available: true });
    } else if (msg.type === 'reset') { vad?.reset(); }
  } catch (err) {
    console.error(err);
    self.postMessage({ type: 'error', id: msg.id, forType: msg.type, message: String(err?.message ?? err) });
  }
};
