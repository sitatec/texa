import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_recorder/flutter_recorder.dart';

/// Dedicated recorder wrapping [Recorder] (`flutter_recorder`).
///
/// Capture is always 16-bit PCM (`PCMFormat.s16le`), mono, at
/// [sampleRate]. Echo cancellation is unified across platforms:
///
/// - Android, iOS and Web use the platform voice-communication preset
///   (`AndroidInputPreset.voiceCommunication`,
///   `IosInputPreset.voiceCommunication`,
///   `WebInputPreset.voiceCommunication`), which enables the OS/browser
///   AEC, AGC and noise suppression. No software filter is added there.
/// - Every other platform (macOS, Windows, Linux, ...) has no such
///   preset, so the SpeexDSP `echoCancellationFilter` is activated
///   instead. On those platforms loudspeaker audio must be supplied as
///   the AEC reference through [feedPlaybackData].
///
/// `flutter_recorder`'s native recorder is a singleton, so instances of
/// this class share the underlying capture device; only one should be
/// streaming at a time.
class AudioRecorder {
  AudioRecorder({this._sampleRate = 16000, bool? usesSoftwareEchoCancellation})
    : _usesSoftwareEchoCancellation =
          usesSoftwareEchoCancellation ?? _defaultUsesSoftwareEchoCancellation;

  final int _sampleRate;
  final bool _usesSoftwareEchoCancellation;

  Recorder get _recorder => Recorder.instance;

  bool _initialized = false;
  bool _streaming = false;
  bool _echoCancellationActive = false;
  bool _disposed = false;

  /// Whether this platform relies on the software SpeexDSP echo
  /// canceller (true on macOS/Windows/Linux, false where the
  /// Android/iOS/Web voice-communication preset provides AEC).
  bool get usesSoftwareEchoCancellation => _usesSoftwareEchoCancellation;

  /// Whether [init] has completed and [dispose] has not run since.
  bool get isInitialized => _initialized;

  /// Whether audio is currently being streamed.
  bool get isStreaming => _streaming;

  /// Capture sample rate in Hz.
  int get sampleRate => _sampleRate;

  static bool get _defaultUsesSoftwareEchoCancellation {
    if (kIsWeb) return false;
    return defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS;
  }

  /// Initialises the capture device and, on software-AEC platforms,
  /// activates the SpeexDSP echo cancellation filter.
  ///
  /// All three platform presets are passed unconditionally: each is
  /// only applied on its own platform and ignored elsewhere. Calling
  /// this more than once is a no-op until [dispose] runs.
  Future<void> init() async {
    if (_initialized) return;
    _disposed = false;
    await _recorder.init(
      format: PCMFormat.s16le,
      sampleRate: _sampleRate,
      channels: RecorderChannels.mono,
      androidInputPreset: AndroidInputPreset.voiceCommunication,
      iosInputPreset: IosInputPreset.voiceCommunication,
      webInputPreset: WebInputPreset.voiceCommunication,
    );
    _initialized = true;
    if (_usesSoftwareEchoCancellation) {
      // ignore: experimental_member_use
      final filter = _recorder.filters.echoCancellationFilter;
      if (!filter.isActive) filter.activate();
      _echoCancellationActive = filter.isActive;
    }
  }

  /// Starts the device and returns the stream of recorded PCM chunks.
  ///
  /// `flutter_recorder` reuses the same native buffer for every chunk
  /// delivered on `uint8ListStream`, so each chunk is copied before it
  /// reaches consumers: retaining or buffering a chunk can never observe
  /// it being overwritten by a later one.
  ///
  /// Requires [init] to have completed first.
  Stream<Uint8List> startStreaming() {
    if (!_initialized || _disposed) {
      throw StateError(
        'AudioRecorder.init() must complete before '
        'startStreaming().',
      );
    }
    if (_streaming) {
      throw StateError('AudioRecorder is already streaming.');
    }
    _recorder.start();
    _recorder.startStreamingData();
    _streaming = true;
    return _recorder.uint8ListStream.map(
      (container) => Uint8List.fromList(container.rawData),
    );
  }

  /// Stops streaming and the capture device. The recorder stays
  /// initialised, so [startStreaming] can be called again.
  Future<void> stopStreaming() async {
    if (!_initialized) return;
    if (_streaming) {
      _streaming = false;
      _recorder.stopStreamingData();
    }
    if (_recorder.isStarted) _recorder.stop();
  }

  /// Feeds loudspeaker (far-end) audio to the software echo canceller
  /// as its playback reference.
  ///
  /// [chunk] must be raw PCM in [format] with [channels] channels at
  /// this recorder's [sampleRate]; it is not a WAV file. This is a
  /// no-op on Android, iOS and Web, where the voice-communication
  /// preset already performs echo cancellation, and whenever the
  /// software canceller is not active.
  void feedPlaybackData(
    Uint8List chunk, {
    PCMFormat format = PCMFormat.s16le,
    RecorderChannels channels = RecorderChannels.mono,
  }) {
    if (!_usesSoftwareEchoCancellation ||
        !_echoCancellationActive ||
        !_initialized ||
        _disposed ||
        chunk.isEmpty) {
      return;
    }
    _recorder.feedPlaybackData(chunk, format: format, channels: channels);
  }

  /// Stops streaming and releases the capture device. Call [init]
  /// again before reusing the recorder.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _streaming = false;
    _echoCancellationActive = false;
    if (_initialized) {
      _initialized = false;
      _recorder.deinit();
    }
  }
}
