import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

/// Native: `video_player` cannot play in-memory bytes, so the turn video
/// is written to a stable temp file (same message -> same file, so
/// reopening the history reuses it instead of piling up copies).
Future<VideoPlayerController> createTurnVideoController(
  Uint8List bytes,
  String keyHint,
) async {
  final dir = await getTemporaryDirectory();
  final name =
      'texa_history_${keyHint.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.mp4';
  final file = File('${dir.path}/$name');
  if (!await file.exists() || await file.length() != bytes.length) {
    await file.writeAsBytes(bytes, flush: true);
  }
  return VideoPlayerController.file(file);
}
