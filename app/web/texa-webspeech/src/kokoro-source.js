// Resolves a Kokoro repo-root base URL into Transformers.js settings.
//
// Accepted forms (KOKORO_WEB_BASE_URL):
//   https://huggingface.co/sitatech/Kokoro-82M-v1.0-ONNX/resolve/main/
//     -> remote mode: remoteHost=https://huggingface.co/,
//        model=sitatech/Kokoro-82M-v1.0-ONNX (HF resolve layout)
//   http://localhost:8765/sitatech/Kokoro-82M-v1.0-ONNX/
//     -> local mode: localModelPath=http://localhost:8765/,
//        model=sitatech/Kokoro-82M-v1.0-ONNX (files at repo root)
export function configureKokoroSource(hfEnv, baseUrl) {
  const fallback = "onnx-community/Kokoro-82M-v1.0-ONNX";
  if (!baseUrl) return fallback;
  let url;
  try { url = new URL(baseUrl); } catch (_) {
    console.warn(`[tts-worker] Invalid KOKORO_WEB_BASE_URL "${baseUrl}", falling back to HF ${fallback}`);
    return fallback;
  }
  const segments = url.pathname.split("/").filter(Boolean);
  const remote = segments.at(-2) === "resolve" && segments.at(-1) === "main";
  const repoSegments = remote ? segments.slice(0, -2) : segments;
  if (repoSegments.length < 2) {
    console.warn(`[tts-worker] KOKORO_WEB_BASE_URL "${baseUrl}" has no <owner>/<repo> path, falling back to HF ${fallback}`);
    return fallback;
  }
  const modelId = repoSegments.slice(-2).join("/");
  const prefix = repoSegments.slice(0, -2).join("/");
  const root = url.origin + (prefix ? `/${prefix}/` : "/");
  console.info(`[tts-worker] Kokoro source: ${remote ? "remote" : "local"} ${root} (model ${modelId})`);
  if (remote) {
    hfEnv.remoteHost = root;
    hfEnv.remotePathTemplate = "{model}/resolve/{revision}/";
    hfEnv.allowLocalModels = false;
    hfEnv.allowRemoteModels = true;
  } else {
    hfEnv.localModelPath = root;
    hfEnv.allowLocalModels = true;
    // Transformers.js 4.3.2 bug: file-existence metadata checks skip
    // URL local paths and report files as missing when remote models are
    // disabled (AutoTokenizer then crashes on an undefined config).
    // Point the "remote" endpoint at the same local mirror to work
    // around it; file contents still load via the local path first.
    hfEnv.remoteHost = root;
    hfEnv.remotePathTemplate = "{model}/";
    hfEnv.allowRemoteModels = true;
  }
  return modelId;
}
