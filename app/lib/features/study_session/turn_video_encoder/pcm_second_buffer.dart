import 'dart:typed_data';

/// Buffers mic PCM and hands it out exactly one second at a time.
///
/// Both streaming encoders consume audio in fixed one-second frames
/// (the native encoder asserts that size; WebCodecs gets matching
/// one-second AudioData), while the microphone delivers arbitrary
/// small chunks. This buffer bridges the two: chunks accumulate until
/// a full second is available, and the final partial second of a turn
/// is silence-padded. Only un-consumed audio is kept, so a long turn
/// holds at most about a second of raw PCM.
class PcmSecondBuffer {
  PcmSecondBuffer({required this.secondBytes});

  /// Bytes per audio frame: sampleRate * channels * 2 (16-bit PCM).
  final int secondBytes;

  final List<Uint8List> _chunks = [];
  int _bufferedBytes = 0;

  /// Total bytes ever added since the last [clear] (speech checks use
  /// this to tell "nothing was recorded" apart from a short buffer).
  int totalReceived = 0;

  int get bufferedBytes => _bufferedBytes;
  bool get hasFullSecond => _bufferedBytes >= secondBytes;

  void add(Uint8List data) {
    totalReceived += data.length;
    _chunks.add(data);
    _bufferedBytes += data.length;
  }

  /// Removes and returns exactly [secondBytes] of PCM, padding a short
  /// remainder with silence.
  Uint8List takeSecond() {
    final out = Uint8List(secondBytes);
    var offset = 0;
    while (offset < out.length && _chunks.isNotEmpty) {
      final chunk = _chunks.first;
      final need = out.length - offset;
      if (chunk.length <= need) {
        out.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
        _chunks.removeAt(0);
      } else {
        out.setRange(offset, offset + need, chunk.sublist(0, need));
        _chunks[0] = chunk.sublist(need);
        offset += need;
      }
    }
    _bufferedBytes -= offset;
    return out;
  }

  void clear() {
    _chunks.clear();
    _bufferedBytes = 0;
    totalReceived = 0;
  }
}
