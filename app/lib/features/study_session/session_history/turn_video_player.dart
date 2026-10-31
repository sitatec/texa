import 'dart:convert';

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:texa/core/constants.dart';
import 'package:video_player/video_player.dart';

import 'turn_video_controller.dart';

/// Plays one student turn video (base64 MP4, as persisted with the
/// student message) inside the session history, with Chewie's playback
/// controls (play/pause, seek, fullscreen) over `video_player`.
class TurnVideoPlayer extends StatefulWidget {
  const TurnVideoPlayer({
    super.key,
    required this.base64Video,
    required this.messageId,
  });

  final String base64Video;
  final String messageId;

  @override
  State<TurnVideoPlayer> createState() => _TurnVideoPlayerState();
}

class _TurnVideoPlayerState extends State<TurnVideoPlayer> {
  VideoPlayerController? _video;
  ChewieController? _chewie;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final bytes = base64Decode(widget.base64Video);
      final video = await createTurnVideoController(bytes, widget.messageId);
      await video.initialize();
      if (!mounted) {
        video.dispose();
        return;
      }
      _video = video;
      _chewie = ChewieController(
        videoPlayerController: video,
        autoPlay: false,
        looping: false,
        showControls: true,
        aspectRatio: video.value.aspectRatio == 0
            ? boardWidth / boardHeight
            : video.value.aspectRatio,
      );
      setState(() {});
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _chewie?.dispose();
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chewie = _chewie;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: AspectRatio(
        // Board turn videos are boardWidth x boardHeight; fall back to that until
        // the controller reports its own ratio.
        aspectRatio: chewie?.aspectRatio ?? boardWidth / boardHeight,
        child: ColoredBox(
          color: Colors.black,
          child: _failed
              ? const Center(
                  child: Icon(
                    Icons.videocam_off_outlined,
                    color: Colors.white54,
                  ),
                )
              : chewie == null
              ? const Center(child: CircularProgressIndicator())
              : Chewie(controller: chewie),
        ),
      ),
    );
  }
}
