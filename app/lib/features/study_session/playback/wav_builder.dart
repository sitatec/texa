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

/// Extracts the audio from a 16-bit PCM WAV file as raw mono s16le PCM,
/// resampled to [targetSampleRate] (linear interpolation) when the file
/// was recorded at a different rate.
///
/// Used to feed loudspeaker playback to an echo canceller, which needs
/// the bare PCM reference at the capture sample rate, not a WAV file.
/// Returns an empty list when [wav] is not a parseable 16-bit PCM WAV.
Uint8List pcm16MonoFromWav(Uint8List wav, {required int targetSampleRate}) {
  if (wav.length < 44) return Uint8List(0);
  final bytes = ByteData.sublistView(wav);
  bool tag(int offset, String value) =>
      offset + value.length <= wav.length &&
      String.fromCharCodes(wav.sublist(offset, offset + value.length)) == value;
  if (!tag(0, 'RIFF') || !tag(8, 'WAVE')) return Uint8List(0);

  var channels = 1;
  var sourceRate = targetSampleRate;
  var bitsPerSample = 16;
  var dataOffset = -1;
  var dataLength = 0;
  var offset = 12;
  while (offset + 8 <= wav.length) {
    final chunkSize = bytes.getUint32(offset + 4, Endian.little);
    final chunkEnd = offset + 8 + chunkSize;
    if (chunkEnd > wav.length) return Uint8List(0);
    if (tag(offset, 'fmt ')) {
      if (chunkSize < 16 || bytes.getUint16(offset + 8, Endian.little) != 1) {
        return Uint8List(0);
      }
      channels = bytes.getUint16(offset + 10, Endian.little);
      sourceRate = bytes.getUint32(offset + 12, Endian.little);
      bitsPerSample = bytes.getUint16(offset + 22, Endian.little);
    } else if (tag(offset, 'data')) {
      dataOffset = offset + 8;
      dataLength = chunkSize;
      break;
    }
    offset = chunkEnd + (chunkSize.isOdd ? 1 : 0);
  }
  if (dataOffset < 0 ||
      channels < 1 ||
      sourceRate <= 0 ||
      bitsPerSample != 16) {
    return Uint8List(0);
  }

  final frameCount = dataLength ~/ (2 * channels);
  if (frameCount == 0) return Uint8List(0);
  final mono = Int16List(frameCount);
  for (var i = 0; i < frameCount; i++) {
    var sum = 0;
    for (var c = 0; c < channels; c++) {
      sum += bytes.getInt16(dataOffset + (i * channels + c) * 2, Endian.little);
    }
    mono[i] = (sum / channels).round();
  }
  if (sourceRate == targetSampleRate) {
    return mono.buffer.asUint8List(mono.offsetInBytes, mono.lengthInBytes);
  }
  final outCount = (frameCount * targetSampleRate / sourceRate).floor();
  final out = ByteData(outCount * 2);
  for (var i = 0; i < outCount; i++) {
    final position = i * sourceRate / targetSampleRate;
    final index = position.floor();
    final next = index + 1 < frameCount ? mono[index + 1] : mono[index];
    final sample = mono[index] + (next - mono[index]) * (position - index);
    out.setInt16(i * 2, sample.round().clamp(-32768, 32767), Endian.little);
  }
  return out.buffer.asUint8List();
}
