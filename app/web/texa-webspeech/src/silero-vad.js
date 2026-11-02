// Streaming Silero VAD ( sherpa-onnx silero_vad.onnx, v5 layout):
// inputs  input:[1,576] state:[2,1,128] sr:int64  outputs output,stateN
// The 576-sample window is the last 64 context samples + 512 new samples.
// Speech state machine mirrors sherpa-onnx SileroVadModel::IsSpeech.
export class SileroVad {
  constructor(session, ort, { threshold = 0.5, minSilenceMs = 500, minSpeechMs = 250, sampleRate = 16000 } = {}) {
    this.session = session; this.ort = ort;
    this.threshold = threshold;
    this.minSilenceSamples = (sampleRate * minSilenceMs) / 1000;
    this.minSpeechSamples = (sampleRate * minSpeechMs) / 1000;
    this.sampleRate = sampleRate;
    this.reset();
  }
  reset() {
    this.state = new this.ort.Tensor('float32', new Float32Array(2 * 1 * 128), [2, 1, 128]);
    this.context = new Float32Array(64);
    this.triggered = false; this.currentSample = 0; this.tempStart = 0; this.tempEnd = 0;
  }
  /** Feed exactly 512 new samples; returns {detected, probability}. */
  async acceptWaveform(samples) {
    const input = new Float32Array(576);
    input.set(this.context, 0); input.set(samples, 64);
    const feeds = {
      input: new this.ort.Tensor('float32', input, [1, 576]),
      state: this.state,
      sr: new this.ort.Tensor('int64', BigInt64Array.from([BigInt(this.sampleRate)]), []),
    };
    const out = await this.session.run(feeds);
    const prob = out.output.data[0];
    if (out.stateN) this.state = out.stateN;
    this.context = input.slice(512);
    return { detected: this.#isSpeech(prob), probability: prob };
  }
  #isSpeech(prob) {
    const threshold = this.threshold;
    this.currentSample += 512;
    if (prob > threshold && this.tempEnd !== 0) this.tempEnd = 0;
    if (prob > threshold && this.tempStart === 0) { this.tempStart = this.currentSample; return false; }
    if (prob > threshold && this.tempStart !== 0 && !this.triggered) {
      if (this.currentSample - this.tempStart < this.minSpeechSamples) return false;
      this.triggered = true; return true;
    }
    if (prob < threshold && !this.triggered) { this.tempStart = 0; this.tempEnd = 0; return false; }
    const negThreshold = Math.max(threshold - 0.15, 0.01);
    if (prob > negThreshold && this.triggered) return true;
    if (prob > threshold && !this.triggered) { this.triggered = true; return true; }
    if (prob < threshold && this.triggered) {
      if (this.tempEnd === 0) this.tempEnd = this.currentSample;
      if (this.currentSample - this.tempEnd < this.minSilenceSamples) return true;
      this.tempStart = 0; this.tempEnd = 0; this.triggered = false; return false;
    }
    return false;
  }
}
