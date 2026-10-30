import 'dart:typed_data';

import 'package:video_player/video_player.dart';

/// Web: there is no temp file to point the player at, so the bytes are
/// handed over as a `data:` URL, which the browser-backed player plays.
Future<VideoPlayerController> createTurnVideoController(
  Uint8List bytes,
  String keyHint,
) async => VideoPlayerController.networkUrl(
  Uri.dataFromBytes(bytes, mimeType: 'video/mp4'),
);
