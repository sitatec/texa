import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Sink for diagnostic lines that should also land in the persisted
/// debug log (Settings > Debug logs). Set by SessionController; when
/// null, diagnostics only go to the console.
void Function(String line)? texaDiagSink;

/// One structured diagnostic line. Keep payloads to hashes/lengths:
/// these logs are meant to be shared for debugging, so no student
/// content, arguments or base64 ever goes in - only fingerprints that
/// let two occurrences be recognised as the same piece.
void texaDiag(String scope, String message) {
  if (kReleaseMode) return;
  final line = '[TexaDiag][$scope] $message';
  debugPrint(line);
  try {
    texaDiagSink?.call(line);
  } catch (_) {
    // Diagnostics must never break the turn they are observing.
  }
}

/// Short stable fingerprint of [value] (FNV-1a): equal content gets an
/// equal hash, which is all repetition debugging needs.
String diagHash(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

String diagText(String value) => 'len=${value.length} hash=${diagHash(value)}';

String diagJson(Object? value) {
  String encoded;
  try {
    encoded = jsonEncode(value);
  } catch (_) {
    encoded = value.toString();
  }
  return diagText(encoded);
}

/// Compact type sequence of a Responses input list, e.g.
/// `user,reasoning,assistant,function_call,call_out(call_1),user`.
/// Consecutive duplicates collapse to `type xN` so a whole request
/// stays one log line while ordering - the thing replay bugs break -
/// stays visible.
String diagInputSummary(List<Map<String, dynamic>> input) {
  final parts = <String>[];
  String? last;
  var run = 0;
  void flush() {
    if (last != null) parts.add(run > 1 ? '$last x$run' : last);
  }

  for (final item in input) {
    final type = switch (item['type']) {
      'function_call' => 'fc(${item['name'] ?? '?'}:${item['call_id'] ?? '?'})',
      'function_call_output' => 'out(${item['call_id'] ?? '?'})',
      'reasoning' => 'reasoning(${item['id'] ?? 'noid'})',
      _ => item['role']?.toString() ?? item['type']?.toString() ?? '?',
    };
    if (type == last) {
      run++;
    } else {
      flush();
      last = type;
      run = 1;
    }
  }
  flush();
  return parts.join(',');
}
