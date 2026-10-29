import 'dart:typed_data';

import 'turn_video_encoder_stub.dart'
    if (dart.library.io) 'turn_video_encoder_io.dart'
    if (dart.library.js_interop) 'turn_video_encoder_web.dart'
    as impl;

/// Streaming turn-video encoder.
///
/// Frames are appended *while the student is still speaking*: every
/// captured board frame and every second of mic audio is encoded as
/// soon as it exists, so ending a turn only finalizes the file instead
/// of encoding the whole turn from buffered raw frames.
///
/// Native platforms wrap `flutter_quick_video_encoder`; the web wraps
/// the hardware-accelerated WebCodecs encoders (H.264 + AAC) muxed
/// into MP4 by the vendored mp4-muxer script (see web/index.html).
abstract interface class TurnVideoEncoder {
  Future<void> setup({
    required int width,
    required int height,
    required int fps,
    required int videoBitrate,
    required int audioChannels,
    required int audioBitrate,
    required int sampleRate,
  });

  /// Appends one raw RGBA frame ([width]×[height]×4 bytes).
  Future<void> appendVideoFrame(Uint8List rawRgba);

  /// Appends one frame of 16-bit little-endian PCM audio. Callers pass
  /// exactly one second per [fps] tick, matching the native encoder's
  /// fixed frame size (`sampleRate * channels * 2 / fps` bytes).
  Future<void> appendAudioFrame(Uint8List rawPcm);

  /// Finalizes encoding and returns the complete MP4 bytes.
  Future<Uint8List> finish();

  /// Abandons the in-progress video and releases the encoder.
  Future<void> abort();
}

TurnVideoEncoder createTurnVideoEncoder() => impl.createTurnVideoEncoder();
