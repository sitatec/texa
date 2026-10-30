import 'dart:typed_data';

import 'package:video_player/video_player.dart';

Future<VideoPlayerController> createTurnVideoController(
  Uint8List bytes,
  String keyHint,
) => throw UnsupportedError('No turn-video playback on this platform.');
