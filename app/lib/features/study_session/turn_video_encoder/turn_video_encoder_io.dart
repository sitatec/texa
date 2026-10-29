import 'dart:io' as io;
import 'dart:typed_data';

import 'package:flutter_quick_video_encoder/flutter_quick_video_encoder.dart';
import 'package:path_provider/path_provider.dart';

import 'turn_video_encoder.dart';

/// Native streaming encoder: a thin wrapper over
/// flutter_quick_video_encoder writing to a temp file, whose bytes are
/// read back (and the file deleted) at [finish].
class IoTurnVideoEncoder implements TurnVideoEncoder {
  io.File? _file;

  @override
  Future<void> setup({
    required int width,
    required int height,
    required int fps,
    required int videoBitrate,
    required int audioChannels,
    required int audioBitrate,
    required int sampleRate,
  }) async {
    final dir = await getTemporaryDirectory();
    _file = io.File(
      '${dir.path}/turn_${DateTime.now().microsecondsSinceEpoch}.mp4',
    );
    await FlutterQuickVideoEncoder.setup(
      width: width,
      height: height,
      fps: fps,
      videoBitrate: videoBitrate,
      profileLevel: ProfileLevel.highAutoLevel,
      audioChannels: audioChannels,
      audioBitrate: audioBitrate,
      sampleRate: sampleRate,
      filepath: _file!.path,
    );
  }

  @override
  Future<void> appendVideoFrame(Uint8List rawRgba) =>
      FlutterQuickVideoEncoder.appendVideoFrame(rawRgba);

  @override
  Future<void> appendAudioFrame(Uint8List rawPcm) =>
      FlutterQuickVideoEncoder.appendAudioFrame(rawPcm);

  @override
  Future<Uint8List> finish() async {
    try {
      await FlutterQuickVideoEncoder.finish();
      final bytes = await _file!.readAsBytes();
      return bytes;
    } finally {
      await _deleteFile();
    }
  }

  @override
  Future<void> abort() async {
    try {
      await FlutterQuickVideoEncoder.finish();
    } catch (_) {}
    await _deleteFile();
  }

  Future<void> _deleteFile() async {
    try {
      await _file?.delete();
    } catch (_) {}
    _file = null;
  }
}

TurnVideoEncoder createTurnVideoEncoder() => IoTurnVideoEncoder();
