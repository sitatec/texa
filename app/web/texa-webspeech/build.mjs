import { build } from 'esbuild';
import { cpSync, mkdirSync, rmSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.resolve(here, '..');
const require = createRequire(import.meta.url);
// Force a single onnxruntime-web (top-level) for transformers/piper/smart-turn
// so only one ORT wasm set is shipped in ort-wasm/.
const ortWeb = path.join(here, 'node_modules/onnxruntime-web');
// Simpler, reliable alias: resolve any onnxruntime-web import from top level.
const aliasOrt = (entry) => ({
  name: 'alias-ort',
  setup(b) {
    b.onResolve({ filter: /^onnxruntime-web(\/.*)?$/ }, () => ({ path: path.join(ortWeb, 'dist', entry) }));
  },
});
const stubNodeBuiltins = {
  name: 'stub-node-builtins',
  setup(b) {
    b.onResolve({ filter: /^(fs|path|crypto|util|stream|buffer|process|os|url|child_process)$/ }, (a) => ({ path: a.path, namespace: 'stub' }));
    b.onLoad({ filter: /.*/, namespace: 'stub' }, () => ({ contents: 'export default {}; export const readFile=()=>{};', loader: 'js' }));
  },
};
const common = { bundle: true, platform: 'browser', target: 'es2022', format: 'iife', logLevel: 'info' };
await build({ ...common, plugins: [aliasOrt('ort.wasm.min.mjs'), stubNodeBuiltins], entryPoints: [path.join(here, 'src/realtime-worker.js')], outfile: path.join(outDir, 'speech_worker.js') });
await build({ ...common, plugins: [aliasOrt('ort.all.min.mjs'), stubNodeBuiltins], entryPoints: [path.join(here, 'src/tts-worker.js')], outfile: path.join(outDir, 'speech_tts_worker.js') });

// ORT wasm binaries (loaded at runtime via env.wasm.wasmPaths -> ./ort-wasm/)
const wasmOut = path.join(outDir, 'ort-wasm');
rmSync(wasmOut, { recursive: true, force: true }); mkdirSync(wasmOut, { recursive: true });
for (const f of ['ort-wasm-simd-threaded.wasm', 'ort-wasm-simd-threaded.mjs', 'ort-wasm-simd-threaded.jsep.wasm', 'ort-wasm-simd-threaded.jsep.mjs']) {
  try { cpSync(path.join(ortWeb, 'dist', f), path.join(wasmOut, f)); } catch (_) {}
}
console.log('Wrote speech_worker.js, speech_tts_worker.js and ort-wasm/ to', outDir);
