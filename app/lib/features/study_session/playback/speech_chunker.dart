/// Splits speech at sentence terminators, keeping the terminator attached.
List<String> splitSpeech(String text) {
  final splitter = StreamingSpeechSplitter();
  return [...splitter.add(text), ...splitter.flush()];
}

/// Incremental sentence splitter: feed streamed text, receive a sentence
/// chunk as soon as its terminator (followed by whitespace) arrives.
class StreamingSpeechSplitter {
  String _buffer = '';
  List<String> add(String delta) {
    _buffer += delta;
    final out = <String>[];
    while (true) {
      final match = RegExp(r'[.!?](?=\s)').firstMatch(_buffer);
      if (match == null) break;
      final end = match.end;
      final chunk = _buffer.substring(0, end).trim();
      // Consume the chunk plus following whitespace.
      var next = end;
      while (next < _buffer.length && _buffer[next].trim().isEmpty) {
        next++;
      }
      _buffer = _buffer.substring(next);
      if (chunk.isNotEmpty) out.add(chunk);
    }
    return out;
  }

  /// Emits whatever text remains at end-of-stream as the final chunk.
  List<String> flush() {
    final rest = _buffer.trim();
    _buffer = '';
    return rest.isEmpty ? [] : [rest];
  }

  String get pending => _buffer;
}
