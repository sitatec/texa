// ignore_for_file: experimental_member_use
part of 'input_file_widget.dart';

// ─── Recording ────────────────────────────────────────────────────────────────

class _RecordingView extends StatefulWidget {
  final VoidCallback onCancel;
  final ValueChanged<Uint8List> onFinalize;

  const _RecordingView({required this.onCancel, required this.onFinalize});

  @override
  State<_RecordingView> createState() => _RecordingViewState();
}

class _RecordingViewState extends State<_RecordingView> {
  final _recorder = AudioRecorder(sampleRate: 24000);
  final _recordedBytes = <int>[];
  final _amplitudeController = StreamController<wf.Amplitude>.broadcast();
  StreamSubscription<Uint8List>? _byteSubscription;
  Timer? _durationTimer;
  Duration _elapsed = Duration.zero;
  bool _maxDurationReached = false;
  Future<void>? _stopFuture;
  bool _isStarted = false;
  bool _isFinalizing = false;

  @override
  void initState() {
    super.initState();
    _startRecording();
  }

  Future<void> _startRecording() async {
    try {
      // flutter_recorder has no permission query: a denied microphone
      // surfaces as an error from init/startStreaming instead, which
      // cancels the recording below just like a refusal did before.
      await _recorder.init();
      final byteStream = _recorder.startStreaming();

      if (!mounted) {
        await _recorder.stopStreaming();
        return;
      }
      _byteSubscription = byteStream.listen((bytes) {
        _recordedBytes.addAll(bytes);
        _addAmplitude(bytes);
      });

      _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() => _elapsed = Duration(seconds: timer.tick.clamp(0, 120)));
        if (_elapsed.inMinutes >= 2) {
          setState(() => _maxDurationReached = true);
          unawaited(_stopRecording().catchError((Object _) {}));
        }
      });

      if (mounted) setState(() => _isStarted = true);
    } catch (e, stack) {
      _logger.severe('Failed to start audio recording', e, stack);
      if (mounted) widget.onCancel();
    }
  }

  /// Derives the waveform amplitude from the streamed s16le PCM chunk
  /// itself (flutter_recorder has no separate amplitude stream).
  void _addAmplitude(Uint8List bytes) {
    if (_amplitudeController.isClosed || bytes.length < 2) return;
    final view = ByteData.sublistView(bytes);
    var peak = 0;
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final sample = view.getInt16(i, Endian.little).abs();
      if (sample > peak) peak = sample;
    }
    final level = peak / 32768.0;
    _amplitudeController.add(wf.Amplitude(current: level, max: level));
  }

  Future<void> _stopRecording() => _stopFuture ??= _stop();

  Future<void> _stop() async {
    _durationTimer?.cancel();
    try {
      await _recorder.stopStreaming();
    } catch (e, stack) {
      _logger.severe('Failed to stop audio recording', e, stack);
      if (mounted) widget.onCancel();
      rethrow;
    }
  }

  Future<void> _finalize() async {
    if (_isFinalizing || !_isStarted) return;
    setState(() => _isFinalizing = true);
    try {
      await _stopRecording();
      if (!mounted) return;
      widget.onFinalize(_pcm16BitToWav(_recordedBytes));
    } catch (e, stack) {
      _logger.severe('Failed to finalize recording', e, stack);
      if (mounted) widget.onCancel();
    }
  }

  void _cancel() {
    _durationTimer?.cancel();
    _byteSubscription?.cancel();
    unawaited(_recorder.stopStreaming());
    widget.onCancel();
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    _byteSubscription?.cancel();
    _amplitudeController.close();
    _recorder.dispose();
    super.dispose();
  }

  String get _elapsedText {
    final m = _elapsed.inMinutes.toString().padLeft(2, '0');
    final s = (_elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;

    return Container(
      width: _maxDurationReached ? 280 : 196,
      height: 36,
      margin: EdgeInsetsDirectional.symmetric(vertical: 4).copyWith(end: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.2),
        border: Border.all(color: primaryColor.withValues(alpha: 0.5)),
      ),
      child: Stack(
        clipBehavior: .antiAlias,
        children: [
          if (_maxDurationReached)
            Positioned.fill(
              left: 44,
              right: 60,
              top: 0,
              child: Center(
                child: Text(
                  context.tr.core.files.recordingMaxDuration,
                  maxLines: 2,
                  overflow: .ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 10,
                    height: 1.1,
                  ),
                ),
              ),
            )
          else if (_isStarted)
            Positioned.fill(
              child: IgnorePointer(
                child: wf.AnimatedWaveList(
                  stream: _amplitudeController.stream,
                  barBuilder: (animation, amplitude) => wf.WaveFormBar(
                    animation: animation,
                    amplitude: amplitude,
                    maxHeight: 4,
                    color: primaryColor.withValues(alpha: 0.5),
                  ),
                ),
              ),
            )
          else
            Center(
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: primaryColor,
                ),
              ),
            ),
          if (_isStarted)
            Positioned(
              left: 6,
              top: 4,
              child: _RecordingDurationLabel(
                text: _elapsedText,
                color: theme.colorScheme.onSurface,
              ),
            ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: _isFinalizing
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Center(
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: primaryColor,
                        ),
                      ),
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _RecordingActionButton(
                        icon: Symbols.check_rounded,
                        onTap: _isStarted ? _finalize : null,
                      ),
                      _RecordingActionButton(
                        icon: Symbols.close,
                        onTap: _cancel,
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _RecordingDurationLabel extends StatelessWidget {
  final String text;
  final Color color;

  const _RecordingDurationLabel({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: color.withValues(alpha: 0.8),
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _RecordingActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _RecordingActionButton({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 28,
        height: double.infinity,
        color: Colors.black.withValues(alpha: 0.3),
        child: Icon(
          icon,
          size: 16,
          weight: 700,
          color: onTap != null
              ? Colors.white
              : Colors.white.withValues(alpha: 0.35),
        ),
      ),
    );
  }
}

// ─── Audio Playback Thumbnail ─────────────────────────────────────────────────

class _AudioPlayerThumbnail extends StatefulWidget {
  final TexaLocalFile file;

  const _AudioPlayerThumbnail({required this.file});

  @override
  State<_AudioPlayerThumbnail> createState() => _AudioPlayerThumbnailState();
}

class _AudioPlayerThumbnailState extends State<_AudioPlayerThumbnail> {
  AudioPlayer? _player;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  bool _isPlaying = false;
  bool _isLoading = false;

  Future<void> _togglePlayback() async {
    try {
      if (_isPlaying) {
        await _player?.pause();
        return;
      }
      if (_player == null) {
        setState(() => _isLoading = true);
        final player = AudioPlayer();
        _player = player;
        final bytes = await widget.file.data.readAsBytes();
        await player.setAudioSource(
          _BytesAudioSource(
            bytes,
            widget.file.mimeType.isNotEmpty
                ? widget.file.mimeType
                : 'audio/wav',
          ),
          preload: false,
        );
        _playerStateSubscription = player.playerStateStream.listen((state) {
          if (!mounted) return;
          final completed = state.processingState == ProcessingState.completed;
          setState(() => _isPlaying = state.playing && !completed);
        });
        if (mounted) setState(() => _isLoading = false);
      } else {
        if (_player?.playerState.processingState == .completed) {
          await _player!.seek(Duration.zero);
          await _player?.pause();
        }
      }
      await _player?.play();
    } catch (e, stack) {
      _logger.warning('Audio playback toggle error', e, stack);
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _playerStateSubscription?.cancel();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;

    return GestureDetector(
      onTap: _togglePlayback,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(Symbols.audio_capture, size: 22, color: color),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              padding: const EdgeInsets.all(2),
              child: _isLoading
                  ? const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      _isPlaying
                          ? Symbols.pause_rounded
                          : Symbols.play_arrow_rounded,
                      size: 12,
                      color: Colors.white,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Bytes Audio Source ────────────────────────────────────────────────────────

class _BytesAudioSource extends StreamAudioSource {
  final Uint8List _bytes;
  final String _contentType;

  _BytesAudioSource(this._bytes, this._contentType);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final from = start ?? 0;
    final to = end ?? _bytes.length;
    return StreamAudioResponse(
      sourceLength: _bytes.length,
      contentLength: to - from,
      offset: from,
      stream: Stream.value(_bytes.sublist(from, to)),
      contentType: _contentType,
    );
  }
}

/// Converts raw 16-bit PCM mono audio (24,000 Hz) into a valid standard WAV (RIFF) byte buffer.
///
/// Accepts [List<int>] or [Uint8List] and returns a contiguous [Uint8List].
Uint8List _pcm16BitToWav(
  List<int> pcmData, {
  int sampleRate = 24000,
  int numChannels = 1,
}) {
  const int headerSize = 44;
  final int pcmLength = pcmData.length;
  final int totalLength = headerSize + pcmLength;

  // 1. Allocate a single contiguous byte buffer for both header and payload
  final Uint8List wavBytes = Uint8List(totalLength);
  final ByteData byteData = ByteData.sublistView(wavBytes);

  const int bitsPerSample = 16;
  final int blockAlign = numChannels * (bitsPerSample ~/ 8); // 1 * 2 = 2 bytes
  final int byteRate = sampleRate * blockAlign; // 24000 * 2 = 48000 B/s

  // ---------------- RIFF Chunk Descriptor ----------------
  // "RIFF" chunk ID (big-endian ASCII)
  wavBytes[0] = 0x52; // 'R'
  wavBytes[1] = 0x49; // 'I'
  wavBytes[2] = 0x46; // 'F'
  wavBytes[3] = 0x46; // 'F'

  // Chunk size: 36 + SubChunk2Size (or totalLength - 8)
  byteData.setUint32(4, 36 + pcmLength, Endian.little);

  // "WAVE" format (big-endian ASCII)
  wavBytes[8] = 0x57; // 'W'
  wavBytes[9] = 0x41; // 'A'
  wavBytes[10] = 0x56; // 'V'
  wavBytes[11] = 0x45; // 'E'

  // ---------------- "fmt " Sub-chunk ----------------
  // "fmt " chunk ID (big-endian ASCII)
  wavBytes[12] = 0x66; // 'f'
  wavBytes[13] = 0x6D; // 'm'
  wavBytes[14] = 0x74; // 't'
  wavBytes[15] = 0x20; // ' '

  // SubChunk1Size: 16 for standard uncompressed PCM
  byteData.setUint32(16, 16, Endian.little);

  // Audio format: 1 indicates Linear PCM
  byteData.setUint16(20, 1, Endian.little);

  // Number of channels (1 = Mono)
  byteData.setUint16(22, numChannels, Endian.little);

  // Sample Rate (24000 Hz)
  byteData.setUint32(24, sampleRate, Endian.little);

  // Byte Rate (sampleRate * numChannels * bitsPerSample / 8)
  byteData.setUint32(28, byteRate, Endian.little);

  // Block Align (numChannels * bitsPerSample / 8)
  byteData.setUint16(32, blockAlign, Endian.little);

  // Bits Per Sample (16 bits)
  byteData.setUint16(34, bitsPerSample, Endian.little);

  // ---------------- "data" Sub-chunk ----------------
  // "data" chunk ID (big-endian ASCII)
  wavBytes[36] = 0x64; // 'd'
  wavBytes[37] = 0x61; // 'a'
  wavBytes[38] = 0x74; // 't'
  wavBytes[39] = 0x61; // 'a'

  // SubChunk2Size: size of the raw PCM data
  byteData.setUint32(40, pcmLength, Endian.little);

  // ---------------- Copy PCM Payload ----------------
  // Uses native block copy (O(N) with fast hardware memory copy)
  wavBytes.setRange(headerSize, totalLength, pcmData);

  return wavBytes;
}
