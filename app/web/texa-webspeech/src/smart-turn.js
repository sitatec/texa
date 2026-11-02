// Smart Turn v3 (soniqo int8 export): mel preprocessing is baked into
// the ONNX graph, so this feeds raw waveform exactly like sherpa-onnx's
// SmartTurnDetector: keep the last 8s, silence-pad at the start to
// [1, 128000], output is a single end-of-turn probability.
export async function predictSmartTurn(session, ort, samples, threshold = 0.5) {
  const expected = 8 * 16000;
  const waveform = new Float32Array(expected);
  const used = samples.length > expected ? samples.subarray(samples.length - expected) : samples;
  waveform.set(used, expected - used.length);
  const out = await session.run({ [session.inputNames[0]]: new ort.Tensor('float32', waveform, [1, expected]) });
  const probability = out[session.outputNames[0]].data[0];
  return { probability, complete: probability >= threshold };
}
