import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'turn_video_encoder.dart';

/// Web streaming encoder: WebCodecs (hardware-accelerated H.264 video
/// + OPUS audio) muxed into an MP4 byte array by mp4-muxer, the small
/// script vendored at web/vendor/mp4-muxer.js — no FFmpeg WASM.
///
/// Video frames arrive as raw RGBA bytes. Creating a [VideoFrame]
/// straight from such a buffer is not supported everywhere, so that
/// capability is probed once (first encoder setup) and cached; when
/// unavailable, frames go through an OffscreenCanvas + ImageBitmap
/// instead. Every frame/bitmap is closed immediately after being
/// handed to the encoder so long turns cannot pile up GPU/memory.
class WebTurnVideoEncoder implements TurnVideoEncoder {
  static bool? _rgbaVideoFrameSupported;

  JSObject? _muxer;
  JSObject? _muxerTarget;
  JSObject? _videoEncoder;
  JSObject? _audioEncoder;
  Object? _codecError;

  int _width = 0;
  int _height = 0;
  int _fps = 1;
  int _audioChannels = 1;
  int _sampleRate = 16000;
  int _videoFrames = 0;
  int _audioFrames = 0;

  JSObject _construct(String name, [JSAny? a, JSAny? b, JSAny? c]) {
    final ctor = globalContext.getProperty(name.toJS) as JSFunction;
    return ctor.callAsConstructor(a, b, c) as JSObject;
  }

  JSObject _jsObject(Map<String, JSAny?> entries) {
    final obj = JSObject();
    for (final e in entries.entries) {
      if (e.value != null) obj.setProperty(e.key.toJS, e.value);
    }
    return obj;
  }

  void _checkCodecError() {
    final e = _codecError;
    if (e != null) throw StateError('WebCodecs encoder failed: $e');
  }

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
    if (globalContext.getProperty('VideoEncoder'.toJS) == null ||
        globalContext.getProperty('AudioEncoder'.toJS) == null ||
        globalContext.getProperty('Mp4Muxer'.toJS) == null) {
      throw StateError(
        'This browser cannot encode the turn video (WebCodecs unavailable).',
      );
    }
    _width = width;
    _height = height;
    _fps = fps;
    _audioChannels = audioChannels;
    _sampleRate = sampleRate;
    _videoFrames = 0;
    _audioFrames = 0;
    _codecError = null;
    _rgbaVideoFrameSupported ??= _probeRgbaVideoFrame();

    final mp4Muxer = globalContext.getProperty('Mp4Muxer'.toJS) as JSObject;
    _muxerTarget =
        (mp4Muxer.getProperty('ArrayBufferTarget'.toJS) as JSFunction)
                .callAsConstructor()
            as JSObject;
    _muxer =
        (mp4Muxer.getProperty('Muxer'.toJS) as JSFunction).callAsConstructor(
          _jsObject({
            'target': _muxerTarget,
            'video': _jsObject({
              'codec': 'avc'.toJS,
              'width': width.toJS,
              'height': height.toJS,
              'frameRate': fps.toJS,
            }),
            'audio': _jsObject({
              'codec': 'opus'.toJS,
              'numberOfChannels': audioChannels.toJS,
              'sampleRate': sampleRate.toJS,
            }),
            'fastStart': 'in-memory'.toJS,
            'firstTimestampBehavior': 'offset'.toJS,
          }),
        ) as JSObject;

    _videoEncoder = _construct(
      'VideoEncoder',
      _jsObject({
        'output': ((JSAny? chunk, JSAny? meta) {
          try {
            if (meta == null) {
              _muxer?.callMethod('addVideoChunk'.toJS, chunk);
            } else {
              _muxer?.callMethod('addVideoChunk'.toJS, chunk, meta);
            }
          } catch (e) {
            _codecError ??= e;
          }
        }).toJS,
        'error': ((JSAny? e) {
          _codecError ??= e;
        }).toJS,
      }),
    );
    _audioEncoder = _construct(
      'AudioEncoder',
      _jsObject({
        'output': ((JSAny? chunk, JSAny? meta) {
          try {
            if (meta == null) {
              _muxer?.callMethod('addAudioChunk'.toJS, chunk);
            } else {
              _muxer?.callMethod('addAudioChunk'.toJS, chunk, meta);
            }
          } catch (e) {
            _codecError ??= e;
          }
        }).toJS,
        'error': ((JSAny? e) {
          _codecError ??= e;
        }).toJS,
      }),
    );

    final videoConfig = await _pickVideoConfig(videoBitrate);
    if (videoConfig == null) {
      throw StateError('This browser cannot encode H.264 video.');
    }
    _videoEncoder!.callMethod('configure'.toJS, videoConfig);

    final audioConfig = _jsObject({
      'codec': 'opus'.toJS,
      'sampleRate': sampleRate.toJS,
      'numberOfChannels': audioChannels.toJS,
      'bitrate': audioBitrate.toJS,
    });
    if (!await _isSupported('AudioEncoder', audioConfig)) {
      throw StateError('This browser cannot encode opus audio.');
    }
    _audioEncoder!.callMethod('configure'.toJS, audioConfig);
  }

  bool _probeRgbaVideoFrame() {
    try {
      final frame = _videoFrameFromBuffer(Uint8List(4 * 4 * 4), 4, 4, 0, 1);
      frame.callMethod('close'.toJS);
      return true;
    } catch (_) {
      return false;
    }
  }

  JSObject _videoFrameFromBuffer(
    Uint8List rgba,
    int width,
    int height,
    int timestampUs,
    int durationUs,
  ) => _construct(
    'VideoFrame',
    rgba.toJS,
    _jsObject({
      'format': 'RGBA'.toJS,
      'codedWidth': width.toJS,
      'codedHeight': height.toJS,
      'timestamp': timestampUs.toJS,
      'duration': durationUs.toJS,
    }),
  );

  Future<JSObject?> _pickVideoConfig(int videoBitrate) async {
    for (final codec in ['avc1.640028', 'avc1.4D4028', 'avc1.42001F']) {
      for (final accel in ['prefer-hardware', 'no-preference']) {
        final config = _jsObject({
          'codec': codec.toJS,
          'width': _width.toJS,
          'height': _height.toJS,
          'bitrate': videoBitrate.toJS,
          'framerate': _fps.toJS,
          'hardwareAcceleration': accel.toJS,
          'latencyMode': 'realtime'.toJS,
        });
        if (await _isSupported('VideoEncoder', config)) return config;
      }
    }
    return null;
  }

  Future<bool> _isSupported(String ctorName, JSObject config) async {
    try {
      final ctor = globalContext.getProperty(ctorName.toJS) as JSObject;
      final promise = ctor.callMethod(
        'isConfigSupported'.toJS,
        config,
      ) as JSPromise<JSObject>;
      final result = await promise.toDart;
      final supported = result.getProperty('supported'.toJS);
      return supported != null &&
          supported.isA<JSBoolean>() &&
          (supported as JSBoolean).toDart;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> appendVideoFrame(Uint8List rawRgba) async {
    _checkCodecError();
    final encoder = _videoEncoder;
    if (encoder == null) throw StateError('Video encoder is not set up.');
    final timestampUs = _videoFrames * 1000000 ~/ _fps;
    final durationUs = 1000000 ~/ _fps;
    JSObject frame;
    if (_rgbaVideoFrameSupported ?? false) {
      try {
        frame = _videoFrameFromBuffer(
          rawRgba,
          _width,
          _height,
          timestampUs,
          durationUs,
        );
      } catch (_) {
        // Probe said yes but this frame failed: switch for good and
        // fall through to the canvas path for this frame too.
        _rgbaVideoFrameSupported = false;
        frame = await _videoFrameViaCanvas(rawRgba, timestampUs, durationUs);
      }
    } else {
      frame = await _videoFrameViaCanvas(rawRgba, timestampUs, durationUs);
    }
    try {
      encoder.callMethod(
        'encode'.toJS,
        frame,
        _jsObject({'keyFrame': (_videoFrames == 0).toJS}),
      );
    } finally {
      // The encoder keeps its own reference; closing immediately keeps
      // memory flat no matter how long the turn runs.
      frame.callMethod('close'.toJS);
    }
    _videoFrames++;
  }

  Future<JSObject> _videoFrameViaCanvas(
    Uint8List rgba,
    int timestampUs,
    int durationUs,
  ) async {
    final canvas = _construct('OffscreenCanvas', _width.toJS, _height.toJS);
    final context = canvas.callMethod('getContext'.toJS, '2d'.toJS) as JSObject;
    final clamped = _construct('Uint8ClampedArray', rgba.toJS);
    final imageData = _construct(
      'ImageData',
      clamped,
      _width.toJS,
      _height.toJS,
    );
    context.callMethod('putImageData'.toJS, imageData, 0.toJS, 0.toJS);
    final bitmapPromise =
        canvas.callMethod('convertToImageBitmap'.toJS) as JSPromise<JSObject>;
    final bitmap = await bitmapPromise.toDart;
    try {
      return _construct(
        'VideoFrame',
        bitmap,
        _jsObject({'timestamp': timestampUs.toJS, 'duration': durationUs.toJS}),
      );
    } finally {
      bitmap.callMethod('close'.toJS);
    }
  }

  @override
  Future<void> appendAudioFrame(Uint8List rawPcm) async {
    _checkCodecError();
    final encoder = _audioEncoder;
    if (encoder == null) throw StateError('Audio encoder is not set up.');
    final bytesPerFrame = 2 * _audioChannels;
    final audioData = _construct(
      'AudioData',
      _jsObject({
        'format': 's16'.toJS,
        'sampleRate': _sampleRate.toJS,
        'numberOfFrames': (rawPcm.length ~/ bytesPerFrame).toJS,
        'numberOfChannels': _audioChannels.toJS,
        'timestamp': (_audioFrames * 1000000).toJS,
        'data': rawPcm.toJS,
      }),
    );
    try {
      encoder.callMethod('encode'.toJS, audioData);
    } finally {
      audioData.callMethod('close'.toJS);
    }
    _audioFrames++;
  }

  @override
  Future<Uint8List> finish() async {
    _checkCodecError();
    try {
      await _flush(_videoEncoder);
      await _flush(_audioEncoder);
      _checkCodecError();
      _muxer!.callMethod('finalize'.toJS);
      final buffer = _muxerTarget!.getProperty('buffer'.toJS) as JSArrayBuffer;
      return Uint8List.fromList(buffer.toDart.asUint8List());
    } finally {
      _closeEncoders();
    }
  }

  @override
  Future<void> abort() async {
    for (final encoder in [_videoEncoder, _audioEncoder]) {
      try {
        encoder?.callMethod('reset'.toJS);
      } catch (_) {}
    }
    _closeEncoders();
  }

  Future<void> _flush(JSObject? encoder) async {
    if (encoder == null) return;
    final promise = encoder.callMethod('flush'.toJS) as JSPromise<JSAny?>;
    await promise.toDart;
  }

  void _closeEncoders() {
    for (final encoder in [_videoEncoder, _audioEncoder]) {
      try {
        encoder?.callMethod('close'.toJS);
      } catch (_) {}
    }
    _videoEncoder = null;
    _audioEncoder = null;
    _muxer = null;
    _muxerTarget = null;
  }
}

TurnVideoEncoder createTurnVideoEncoder() => WebTurnVideoEncoder();
