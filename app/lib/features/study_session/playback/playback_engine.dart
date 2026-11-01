import '../ai/ai_actions.dart';

/// Suspended playback snapshot taken when the student interrupts Texa.
class SuspendedPlayback {
  const SuspendedPlayback({
    required this.remaining,
    required this.interruptedSpeechChunk,
    required this.completedActions,
  });
  final List<PlaybackItem> remaining;
  final String? interruptedSpeechChunk;
  final List<Map<String, Object?>> completedActions;
  Map<String, dynamic> toContext() => {
    'interruptedSpeechChunk': interruptedSpeechChunk,
    'completedActions': completedActions,
    'suspendedStepsRemaining': remaining.length,
  };
}

/// Pure queue logic for suspend / false-trigger resume / real interruption.
class PlaybackQueue {
  final List<PlaybackItem> _pending = [];
  int currentIndex = -1;
  PlaybackItem? current;
  final List<Map<String, Object?>> completed = [];
  void addAll(Iterable<PlaybackItem> items) => _pending.addAll(items);
  void add(PlaybackItem item) => _pending.add(item);
  PlaybackItem? next() {
    if (_pending.isEmpty) {
      current = null;
      return null;
    }
    currentIndex++;
    current = _pending.removeAt(0);
    return current;
  }

  bool get hasMore => _pending.isNotEmpty;
  List<PlaybackItem> get pendingSnapshot => List.unmodifiable(_pending);
  void clearPending() => _pending.clear();

  /// Captures the remaining queue (including re-speaking the current chunk).
  SuspendedPlayback suspend(String? interruptedChunk) {
    final remaining = <PlaybackItem>[
      if (interruptedChunk != null && interruptedChunk.isNotEmpty)
        TextItem(interruptedChunk),
      ..._pending,
    ];
    return SuspendedPlayback(
      remaining: remaining,
      interruptedSpeechChunk: interruptedChunk,
      completedActions: List.of(completed),
    );
  }
}
