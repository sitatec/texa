import 'dart:typed_data';

import 'package:video_player/video_player.dart';

import 'turn_video_controller_stub.dart'
    if (dart.library.io) 'turn_video_controller_io.dart'
    if (dart.library.js_interop) 'turn_video_controller_web.dart'
    as impl;

/// Creates a (not yet initialised) controller that plays the given MP4
/// turn-video bytes, however the platform has to be fed them.
Future<VideoPlayerController> createTurnVideoController(
  Uint8List bytes,
  String keyHint,
) => impl.createTurnVideoController(bytes, keyHint);
