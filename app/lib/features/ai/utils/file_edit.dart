import 'dart:math' as math;

// --- Public Types ---

class Edit {
  final String oldText;
  final String newText;

  Edit({required this.oldText, required this.newText});
}

class FuzzyMatchResult {
  final bool found;
  final int index;
  final int matchLength;
  final bool usedFuzzyMatch;
  final String contentForReplacement;

  FuzzyMatchResult({
    required this.found,
    required this.index,
    required this.matchLength,
    required this.usedFuzzyMatch,
    required this.contentForReplacement,
  });
}

// --- Private Types ---

class _LineSpan {
  final int start;
  final int end;

  const _LineSpan(this.start, this.end);
}

class _TextReplacement {
  final int matchIndex;
  final int matchLength;
  final String newText;

  _TextReplacement({
    required this.matchIndex,
    required this.matchLength,
    required this.newText,
  });
}

class _MatchedEdit extends _TextReplacement {
  final int editIndex;

  _MatchedEdit({
    required this.editIndex,
    required super.matchIndex,
    required super.matchLength,
    required super.newText,
  });
}

class _LineRange {
  final int startLine;
  final int endLine;

  const _LineRange(this.startLine, this.endLine);
}

class _ReplacementGroup {
  int startLine;
  int endLine;
  final List<_TextReplacement> replacements;

  _ReplacementGroup({
    required this.startLine,
    required this.endLine,
    required this.replacements,
  });
}

// --- Line Ending & BOM Utilities ---

String _detectLineEnding(String content) {
  final crlfIdx = content.indexOf('\r\n');
  final lfIdx = content.indexOf('\n');
  if (lfIdx == -1) return '\n';
  if (crlfIdx == -1) return '\n';
  return crlfIdx < lfIdx ? '\r\n' : '\n';
}

String _normalizeToLF(String text) {
  return text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
}

String _restoreLineEndings(String text, String ending) {
  return ending == '\r\n' ? text.replaceAll('\n', '\r\n') : text;
}

// --- Fuzzy Normalization ---

/// Normalize text for fuzzy matching. Applies progressive transformations:
/// - Strip trailing whitespace from each line
/// - Normalize smart quotes to ASCII equivalents
/// - Normalize Unicode dashes/hyphens to ASCII hyphen
/// - Normalize special Unicode spaces to regular space
///
/// Note: If standard Unicode NFKC compatibility decomposition is strictly required,
/// add `package:unorm_dart` (unorm.nfkc(text)).
String _normalizeForFuzzyMatch(String text) {
  return text
      // Strip trailing whitespace per line
      .split('\n')
      .map((line) => line.trimRight())
      .join('\n')
      // Smart single quotes → '
      .replaceAll(RegExp(r'[\u2018\u2019\u201A\u201B]'), "'")
      // Smart double quotes → "
      .replaceAll(RegExp(r'[\u201C\u201D\u201E\u201F]'), '"')
      // Various dashes/hyphens → -
      .replaceAll(RegExp(r'[\u2010\u2011\u2012\u2013\u2014\u2015\u2212]'), '-')
      // Special spaces → regular space
      .replaceAll(RegExp(r'[\u00A0\u2002-\u200A\u202F\u205F\u3000]'), ' ');
}

// --- Text Replacement Engines ---

List<String> _splitLinesWithEndings(String content) {
  if (content.isEmpty) return [];
  final matches = RegExp(r'[^\n]*\n|[^\n]+').allMatches(content);
  return matches.map((m) => m.group(0)!).toList();
}

List<_LineSpan> _getLineSpans(String content) {
  var offset = 0;
  final spans = <_LineSpan>[];
  for (final line in _splitLinesWithEndings(content)) {
    final span = _LineSpan(offset, offset + line.length);
    offset = span.end;
    spans.add(span);
  }
  return spans;
}

_LineRange _getReplacementLineRange(
  List<_LineSpan> lines,
  _TextReplacement replacement,
) {
  final replacementStart = replacement.matchIndex;
  final replacementEnd = replacement.matchIndex + replacement.matchLength;

  var startLine = -1;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (replacementStart >= line.start && replacementStart < line.end) {
      startLine = i;
      break;
    }
  }
  if (startLine == -1) {
    throw Exception('Replacement range is outside the base content.');
  }

  var endLine = startLine;
  while (endLine < lines.length && lines[endLine].end < replacementEnd) {
    endLine++;
  }
  if (endLine >= lines.length) {
    throw Exception('Replacement range is outside the base content.');
  }

  return _LineRange(startLine, endLine + 1);
}

String _applyReplacements(
  String content,
  List<_TextReplacement> replacements, [
  int offset = 0,
]) {
  var result = content;
  for (var i = replacements.length - 1; i >= 0; i--) {
    final replacement = replacements[i];
    final matchIndex = replacement.matchIndex - offset;
    result =
        result.substring(0, matchIndex) +
        replacement.newText +
        result.substring(matchIndex + replacement.matchLength);
  }
  return result;
}

/// Applies replacements while preserving unmodified line blocks from the original.
/// Used when modifications were matched against normalized content to ensure original formatting is preserved elsewhere.
String _applyReplacementsPreservingUnchangedLines(
  String originalContent,
  String baseContent,
  List<_TextReplacement> replacements,
) {
  final originalLines = _splitLinesWithEndings(originalContent);
  final baseLines = _getLineSpans(baseContent);

  if (originalLines.length != baseLines.length) {
    throw Exception(
      'Cannot preserve unchanged lines because the base content has a different line count.',
    );
  }

  final groups = <_ReplacementGroup>[];
  final sortedReplacements = [...replacements]
    ..sort((a, b) => a.matchIndex.compareTo(b.matchIndex));

  for (final replacement in sortedReplacements) {
    final range = _getReplacementLineRange(baseLines, replacement);
    final current = groups.isNotEmpty ? groups.last : null;
    if (current != null && range.startLine < current.endLine) {
      current.endLine = math.max(current.endLine, range.endLine);
      current.replacements.add(replacement);
      continue;
    }
    groups.add(
      _ReplacementGroup(
        startLine: range.startLine,
        endLine: range.endLine,
        replacements: [replacement],
      ),
    );
  }

  var originalLineIndex = 0;
  final buffer = StringBuffer();

  for (final group in groups) {
    buffer.write(
      originalLines.sublist(originalLineIndex, group.startLine).join(),
    );
    final groupStartOffset = baseLines[group.startLine].start;
    final groupEndOffset = baseLines[group.endLine - 1].end;

    buffer.write(
      _applyReplacements(
        baseContent.substring(groupStartOffset, groupEndOffset),
        group.replacements,
        groupStartOffset,
      ),
    );
    originalLineIndex = group.endLine;
  }

  buffer.write(originalLines.sublist(originalLineIndex).join());
  return buffer.toString();
}

FuzzyMatchResult _fuzzyFindText(String content, String oldText) {
  // Try exact match first
  final exactIndex = content.indexOf(oldText);
  if (exactIndex != -1) {
    return FuzzyMatchResult(
      found: true,
      index: exactIndex,
      matchLength: oldText.length,
      usedFuzzyMatch: false,
      contentForReplacement: content,
    );
  }

  // Fall back to fuzzy match in normalized space
  final fuzzyContent = _normalizeForFuzzyMatch(content);
  final fuzzyOldText = _normalizeForFuzzyMatch(oldText);
  final fuzzyIndex = fuzzyContent.indexOf(fuzzyOldText);

  if (fuzzyIndex == -1) {
    return FuzzyMatchResult(
      found: false,
      index: -1,
      matchLength: 0,
      usedFuzzyMatch: false,
      contentForReplacement: content,
    );
  }

  return FuzzyMatchResult(
    found: true,
    index: fuzzyIndex,
    matchLength: fuzzyOldText.length,
    usedFuzzyMatch: true,
    contentForReplacement: fuzzyContent,
  );
}

int _countOccurrences(String content, String oldText) {
  final fuzzyContent = _normalizeForFuzzyMatch(content);
  final fuzzyOldText = _normalizeForFuzzyMatch(oldText);
  return fuzzyContent.split(fuzzyOldText).length - 1;
}

// --- Error Handlers ---

Exception _getNotFoundError(int editIndex, int totalEdits) {
  return Exception(
    totalEdits == 1
        ? 'Could not find the exact text. The old text must match exactly including all whitespace and newlines.'
        : 'Could not find edits[$editIndex]. The oldText must match exactly including all whitespace and newlines.',
  );
}

Exception _getDuplicateError(int editIndex, int totalEdits, int occurrences) {
  return Exception(
    totalEdits == 1
        ? 'Found $occurrences occurrences of the text. The text must be unique. Please provide more context.'
        : 'Found $occurrences occurrences of edits[$editIndex]. Each oldText must be unique. Please provide more context.',
  );
}

Exception _getEmptyOldTextError(int editIndex, int totalEdits) {
  return Exception(
    totalEdits == 1
        ? 'oldText must not be empty.'
        : 'edits[$editIndex].oldText must not be empty.',
  );
}

Exception _getNoChangeError(int totalEdits) {
  return Exception(
    totalEdits == 1
        ? 'No changes made. The replacement produced identical content.'
        : 'No changes made. The replacements produced identical content.',
  );
}

// --- Main Public Entry Point ---

/// Apply one or more edits to string content using exact-first, fuzzy-fallback matching.
///
/// @param content The original raw string content (handles BOM and mixed line endings automatically).
/// @param edits A list of [Edit] objects containing oldText and newText.
/// @returns The new string with edits applied.
String applyEdits(String content, List<Edit> edits) {
  // 1. Strip BOM if present (to safely match against agent output)
  final hasBom = content.startsWith('\uFEFF');
  final textWithoutBom = hasBom ? content.substring(1) : content;

  // 2. Detect & normalize line endings to LF for consistent processing
  final originalEnding = _detectLineEnding(textWithoutBom);
  final normalizedContent = _normalizeToLF(textWithoutBom);

  final normalizedEdits = edits
      .map(
        (edit) => Edit(
          oldText: _normalizeToLF(edit.oldText),
          newText: _normalizeToLF(edit.newText),
        ),
      )
      .toList();

  for (var i = 0; i < normalizedEdits.length; i++) {
    if (normalizedEdits[i].oldText.isEmpty) {
      throw _getEmptyOldTextError(i, normalizedEdits.length);
    }
  }

  final initialMatches = normalizedEdits
      .map((edit) => _fuzzyFindText(normalizedContent, edit.oldText))
      .toList();
  final usedFuzzyMatch = initialMatches.any((match) => match.usedFuzzyMatch);
  final replacementBaseContent = usedFuzzyMatch
      ? _normalizeForFuzzyMatch(normalizedContent)
      : normalizedContent;

  final matchedEdits = <_MatchedEdit>[];

  // 3. Find and validate all edits
  for (var i = 0; i < normalizedEdits.length; i++) {
    final edit = normalizedEdits[i];
    final matchResult = _fuzzyFindText(replacementBaseContent, edit.oldText);

    if (!matchResult.found) {
      throw _getNotFoundError(i, normalizedEdits.length);
    }

    final occurrences = _countOccurrences(replacementBaseContent, edit.oldText);
    if (occurrences > 1) {
      throw _getDuplicateError(i, normalizedEdits.length, occurrences);
    }

    matchedEdits.add(
      _MatchedEdit(
        editIndex: i,
        matchIndex: matchResult.index,
        matchLength: matchResult.matchLength,
        newText: edit.newText,
      ),
    );
  }

  // 4. Sort and verify no overlaps
  matchedEdits.sort((a, b) => a.matchIndex.compareTo(b.matchIndex));
  for (var i = 1; i < matchedEdits.length; i++) {
    final previous = matchedEdits[i - 1];
    final current = matchedEdits[i];
    if (previous.matchIndex + previous.matchLength > current.matchIndex) {
      throw Exception(
        'edits[${previous.editIndex}] and edits[${current.editIndex}] overlap. Merge them into one edit or target disjoint regions.',
      );
    }
  }

  // 5. Apply the edits
  final newContent = usedFuzzyMatch
      ? _applyReplacementsPreservingUnchangedLines(
          normalizedContent,
          replacementBaseContent,
          matchedEdits,
        )
      : _applyReplacements(replacementBaseContent, matchedEdits);

  if (normalizedContent == newContent) {
    throw _getNoChangeError(normalizedEdits.length);
  }

  // 6. Restore original line endings and BOM
  final restoredContent = _restoreLineEndings(newContent, originalEnding);
  return hasBom ? '\uFEFF$restoredContent' : restoredContent;
}

/// Applies AI notebook edits to [current] text.
///
/// A blank notebook accepts a single edit whose old text is empty: that
/// edit's new text becomes the initial content.
String applyNotebookEdits(String current, List<Edit> edits) {
  if (edits.isEmpty) return current;
  if (current.trim().isEmpty &&
      edits.length == 1 &&
      edits.first.oldText.isEmpty) {
    return edits.first.newText.trim();
  }
  return applyEdits(current, edits).trim();
}

/// Keeps at most the first two paragraphs of [text].
String clampToTwoParagraphs(String text) {
  final parts = text
      .split(RegExp(r'\n\s*\n'))
      .where((e) => e.trim().isNotEmpty)
      .toList();
  return parts.take(2).join('\n\n');
}
