import 'dart:typed_data';

/// Builds a complete 16-bit PCM WAV file from float samples in memory.
Uint8List buildWav(Float32List samples, int sampleRate) {
  final data = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    final v = (samples[i].clamp(-1, 1) * 32767).round();
    data.setInt16(i * 2, v, Endian.little);
  }
  final out = BytesBuilder();
  void str(String s) => out.add(s.codeUnits);
  void u32(int v) {
    final b = ByteData(4)..setUint32(0, v, Endian.little);
    out.add(b.buffer.asUint8List());
  }

  void u16(int v) {
    final b = ByteData(2)..setUint16(0, v, Endian.little);
    out.add(b.buffer.asUint8List());
  }

  str('RIFF');
  u32(36 + data.lengthInBytes);
  str('WAVE');
  str('fmt ');
  u32(16);
  u16(1);
  u16(1);
  u32(sampleRate);
  u32(sampleRate * 2);
  u16(2);
  u16(16);
  str('data');
  u32(data.lengthInBytes);
  out.add(data.buffer.asUint8List());
  return out.takeBytes();
}
