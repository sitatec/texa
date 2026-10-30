import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:mime/mime.dart';
import 'package:texa/core/utils/snackbar.dart';
import 'package:texa/core/theme.dart';
import 'package:texa/generated/i18n/translations.g.dart';

import '../recording/audio_recorder.dart';

import 'package:waveform_flutter/waveform_flutter.dart' as wf;

part '_audio_recorder_widget.dart';

final _logger = Logger('Core/TexaFilePicker');

const int _maxFileSizeInMb = 45;
final int _maxFileSizeInBytes = _maxFileSizeInMb * 1024 * 1024; // 45MB

enum TexaFileType { image, video, audio, document, any }

class BaseTexaFile<T> {
  final TexaFileType type;
  final String mimeType;
  final T data;

  const BaseTexaFile({
    required this.type,
    required this.mimeType,
    required this.data,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BaseTexaFile &&
          runtimeType == other.runtimeType &&
          type == other.type &&
          mimeType == other.mimeType &&
          data == other.data;

  @override
  int get hashCode => type.hashCode ^ mimeType.hashCode ^ data.hashCode;

  @override
  String toString() => 'File(type: $type, mimeType: $mimeType, data: $data)';
}

class TexaRemoteFile extends BaseTexaFile<String> {
  TexaRemoteFile({
    required super.type,
    required super.mimeType,
    required super.data,
  });
}

class TexaLocalFile extends BaseTexaFile<XFile> {
  TexaLocalFile({
    required super.type,
    required super.mimeType,
    required super.data,
  });

  @override
  bool operator ==(Object other) =>
      super == other &&
      other is TexaLocalFile &&
      runtimeType == other.runtimeType &&
      type == other.type &&
      mimeType == other.mimeType &&
      data.path == other.data.path;

  @override
  int get hashCode => type.hashCode ^ mimeType.hashCode ^ data.path.hashCode;
}

/// File attachment control with its own built-in state management.
///
/// Tapping it opens a modal with the platform's upload options and a
/// vertically scrollable, responsive grid of selected-file previews.
class TexaInputFileWidget extends StatefulWidget {
  final int maxFiles;
  final int minFiles;
  final List<TexaLocalFile>? initialValue;
  final ValueChanged<List<TexaLocalFile>>? onChanged;
  final List<TexaFileType> supportedFileTypes;
  final Widget? icon;
  final bool enableAudioRecording;

  /// Renders as a single icon button (with a count badge) instead of a chip.
  final bool iconOnly;

  /// Called with the selected files each time the upload modal closes.
  final ValueChanged<List<TexaLocalFile>>? onModalClosed;

  const TexaInputFileWidget({
    super.key,
    int? maxFiles,
    int? minFiles,
    this.initialValue,
    this.onChanged,
    this.supportedFileTypes = const [
      TexaFileType.image,
      TexaFileType.video,
      TexaFileType.audio,
      TexaFileType.document,
    ],
    this.icon,
    this.enableAudioRecording = true,
    this.iconOnly = false,
    this.onModalClosed,
  }) : maxFiles = maxFiles ?? 15,
       minFiles = minFiles ?? 0;

  @override
  State<TexaInputFileWidget> createState() => _TexaInputFileWidgetState();
}

class _TexaInputFileWidgetState extends State<TexaInputFileWidget> {
  final _picker = ImagePicker();

  /// The widget's own state: the currently selected files.
  List<TexaLocalFile> _files = [];

  @override
  void initState() {
    super.initState();
    _files = List.of(widget.initialValue ?? []);
  }

  @override
  void didUpdateWidget(covariant TexaInputFileWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.initialValue, widget.initialValue)) {
      setState(() => _files = List.of(widget.initialValue ?? []));
    }
  }

  void _setFiles(List<TexaLocalFile> files) {
    setState(() => _files = files);
    widget.onChanged?.call(files);
  }

  void _addFiles(List<TexaLocalFile> newFiles) {
    final remaining = widget.maxFiles - _files.length;
    if (remaining <= 0) {
      showErrorSnackBar(tr.common.maxReached(max: widget.maxFiles), context);
      return;
    }
    final filtered = newFiles.where((file) {
      return !_files.any(
        (existing) =>
            (existing.data.path.isNotEmpty &&
                existing.data.path == file.data.path) ||
            (existing.data.name.isNotEmpty &&
                existing.data.name == file.data.name),
      );
    }).toList();
    if (filtered.length > remaining) {
      showErrorSnackBar(tr.common.maxReached(max: widget.maxFiles), context);
    }
    final toAdd = filtered.take(remaining).toList();
    if (toAdd.isNotEmpty) {
      _setFiles([..._files, ...toAdd]);
    }
  }

  void _removeFile(int index) {
    if (index >= 0 && index < _files.length) {
      _setFiles(List.of(_files)..removeAt(index));
    }
  }

  List<String>? _allowedExtensions() {
    if (widget.supportedFileTypes.contains(TexaFileType.any)) return null;
    final extensions = <String>{};
    if (widget.supportedFileTypes.contains(TexaFileType.image)) {
      extensions.addAll(['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'heic']);
    }
    if (widget.supportedFileTypes.contains(TexaFileType.video)) {
      extensions.addAll(['mp4']);
    }
    if (widget.supportedFileTypes.contains(TexaFileType.audio)) {
      extensions.addAll(['mp3', 'wav', 'mpeg']);
    }
    if (widget.supportedFileTypes.contains(TexaFileType.document)) {
      extensions.addAll(['txt', 'csv', 'pdf', 'json']);
    }
    return extensions.toList();
  }

  TexaFileType _resolveFileType(String mimeType, String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    if (mimeType.startsWith('image/') ||
        {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'heic'}.contains(ext)) {
      return TexaFileType.image;
    }
    if (mimeType.startsWith('video/') || ext == 'mp4') {
      return TexaFileType.video;
    }
    if (mimeType.startsWith('audio/') || {'mp3', 'wav', 'mpeg'}.contains(ext)) {
      return TexaFileType.audio;
    }
    if (mimeType == 'application/pdf' ||
        mimeType.startsWith('text/') ||
        {'txt', 'csv', 'pdf'}.contains(ext)) {
      return TexaFileType.document;
    }
    return TexaFileType.any;
  }

  Future<XFile> _processImageFile(XFile file) async {
    try {
      final bytes = await file.readAsBytes();
      final compressed = await FlutterImageCompress.compressWithList(
        bytes,
        format: CompressFormat.jpeg,
        // Says min but it actually behave like max
        minHeight: 1920,
        minWidth: 1920,
        quality: 95,
        keepExif: false,
      );
      return XFile.fromData(
        compressed,
        mimeType: 'image/jpeg',
        name: file.name.replaceAll(RegExp(r'\.[^.]+$'), '.jpg'),
      );
    } catch (e, stack) {
      _logger.warning('Image compression failed, using original', e, stack);
      return file;
    }
  }

  Future<TexaLocalFile?> _platformFileToTexaLocalFile(
    PlatformFile platformFile,
  ) async {
    final length = await platformFile.length();
    if (length != null && length > _maxFileSizeInBytes) {
      if (mounted) {
        showErrorSnackBar(
          tr.session.inputFile.fileTooLarge(sizeInMb: _maxFileSizeInMb),
          context,
        );
      }
      return null;
    }
    XFile xFile = platformFile.xFile;
    final fileName = platformFile.name;
    final mimeType =
        lookupMimeType(fileName) ??
        (platformFile.path != null
            ? lookupMimeType(platformFile.path!)
            : null) ??
        'application/octet-stream';
    final type = _resolveFileType(mimeType, fileName);
    if (type == TexaFileType.image) {
      xFile = await _processImageFile(xFile);
    }
    return TexaLocalFile(
      type: type,
      mimeType: xFile.mimeType ?? mimeType,
      data: xFile,
    );
  }

  Future<void> _convertAndAdd(List<PlatformFile> files) async {
    final converted = <TexaLocalFile>[];
    for (final file in files) {
      final local = await _platformFileToTexaLocalFile(file);
      if (local != null) converted.add(local);
    }
    if (mounted) _addFiles(converted);
  }

  Future<void> _pickFiles() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: _allowedExtensions(),
      );
      if (files.isEmpty) return;
      await _convertAndAdd(files);
    } catch (e, stack) {
      _logger.severe('Failed to pick files', e, stack);
    }
  }

  Future<void> _pickImageGallery() async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.image);
      if (files.isEmpty) return;
      await _convertAndAdd(files);
    } catch (e, stack) {
      _logger.severe('Failed to pick images from gallery', e, stack);
    }
  }

  Future<void> _pickCamera() async {
    try {
      final picked = await _picker.pickImage(source: ImageSource.camera);
      if (picked == null) return;
      if (await picked.length() > _maxFileSizeInBytes) {
        if (mounted) {
          showErrorSnackBar(
            tr.session.inputFile.fileTooLarge(sizeInMb: _maxFileSizeInMb),
            context,
          );
        }
        return;
      }
      final processed = await _processImageFile(picked);
      _addFiles([
        TexaLocalFile(
          type: TexaFileType.image,
          mimeType: processed.mimeType ?? 'image/jpeg',
          data: processed,
        ),
      ]);
    } catch (e, stack) {
      _logger.severe('Failed to capture camera image', e, stack);
    }
  }

  /// Upload sources that make sense on this platform.
  List<({IconData icon, String label, Future<void> Function() run})>
  _uploadOptions(void Function(void Function()) refreshModal) {
    final supportsImage = widget.supportedFileTypes.contains(
      TexaFileType.image,
    );
    final isMobile =
        !kIsWeb &&
        {
          TargetPlatform.android,
          TargetPlatform.iOS,
        }.contains(defaultTargetPlatform);
    return [
      if (supportsImage && isMobile)
        (
          icon: Symbols.photo_library_rounded,
          label: tr.session.inputFile.imageGallery,
          run: _pickImageGallery,
        ),
      if (supportsImage && isMobile)
        (
          icon: Symbols.photo_camera_rounded,
          label: tr.session.inputFile.camera,
          run: _pickCamera,
        ),
      (
        icon: Symbols.folder_open_rounded,
        label: tr.session.inputFile.selectFiles,
        run: _pickFiles,
      ),
    ];
  }

  Future<void> _openUploadModal() async {
    if (_files.length >= widget.maxFiles) {
      showErrorSnackBar(tr.common.maxReached(max: widget.maxFiles), context);
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (modalContext) {
        var recording = false;
        return StatefulBuilder(
          builder: (context, setModalState) {
            final options = _uploadOptions(setModalState);
            final canRecord =
                widget.enableAudioRecording &&
                widget.supportedFileTypes.contains(TexaFileType.audio) &&
                _files.length < widget.maxFiles;
            return SafeArea(
              child: FractionallySizedBox(
                heightFactor: 0.82,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        tr.session.inputFile.uploadTitle,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          ...options.map(
                            (o) => ActionChip(
                              avatar: Icon(o.icon, size: 18),
                              label: Text(o.label),
                              onPressed: () async {
                                await o.run();
                                setModalState(() {});
                              },
                            ),
                          ),
                          if (canRecord && !recording)
                            ActionChip(
                              avatar: const Icon(Symbols.mic_rounded, size: 18),
                              label: Text(tr.session.inputFile.recordAudio),
                              onPressed: () =>
                                  setModalState(() => recording = true),
                            ),
                        ],
                      ),
                      if (recording) ...[
                        const SizedBox(height: 12),
                        _RecordingView(
                          onCancel: () =>
                              setModalState(() => recording = false),
                          onFinalize: (bytes) {
                            setModalState(() => recording = false);
                            final name =
                                'recording_${DateTime.now().millisecondsSinceEpoch}.wav';
                            _addFiles([
                              TexaLocalFile(
                                type: TexaFileType.audio,
                                mimeType: 'audio/wav',
                                data: XFile.fromData(
                                  bytes,
                                  mimeType: 'audio/wav',
                                  name: name,
                                  path: name,
                                ),
                              ),
                            ]);
                            setModalState(() {});
                          },
                        ),
                      ],
                      const SizedBox(height: 16),
                      Expanded(
                        child: _files.isEmpty
                            ? Center(
                                child: Text(
                                  tr.session.inputFile.noFilesYet,
                                  textAlign: TextAlign.center,
                                ),
                              )
                            : GridView.builder(
                                gridDelegate:
                                    const SliverGridDelegateWithMaxCrossAxisExtent(
                                      maxCrossAxisExtent: 150,
                                      mainAxisSpacing: 12,
                                      crossAxisSpacing: 12,
                                      childAspectRatio: 0.82,
                                    ),
                                itemCount: _files.length,
                                itemBuilder: (context, index) {
                                  final file = _files[index];
                                  return _FileGridCell(
                                    file: file,
                                    onRemove: () {
                                      _removeFile(index);
                                      setModalState(() {});
                                    },
                                  );
                                },
                              ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () => Navigator.pop(modalContext),
                        child: Text(tr.common.kContinue),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    if (mounted) setState(() {});
    widget.onModalClosed?.call(List.unmodifiable(_files));
  }

  String? get _validationError {
    if (widget.minFiles > 0 && _files.length < widget.minFiles) {
      return tr.common.validationIndicatingMinimum(min: widget.minFiles);
    }
    if (_files.length > widget.maxFiles) {
      return tr.common.validationIndicatingMaximum(max: widget.maxFiles);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final error = _validationError;
    if (widget.iconOnly) {
      return IconButton(
        visualDensity: VisualDensity.compact,
        iconSize: 20,
        tooltip: tr.session.inputFile.addFiles,
        onPressed: _openUploadModal,
        icon: Badge(
          isLabelVisible: _files.isNotEmpty,
          label: Text('${_files.length}'),
          child: widget.icon ?? const Icon(Symbols.attach_file, size: 22),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: _openUploadModal,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                widget.icon ??
                    const Icon(Symbols.add_photo_alternate, size: 22),
                const SizedBox(width: 8),
                Text(
                  _files.isEmpty
                      ? tr.session.inputFile.addFiles
                      : tr.session.inputFile.filesAttached(
                          count: _files.length,
                        ),
                ),
                if (_files.isNotEmpty) ...[
                  const SizedBox(width: 10),
                  ..._files
                      .take(4)
                      .map(
                        (f) => Padding(
                          padding: const EdgeInsetsDirectional.only(end: 4),
                          child: SizedBox(
                            width: 30,
                            height: 30,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: _FileThumbnailContent(file: f),
                            ),
                          ),
                        ),
                      ),
                ],
              ],
            ),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              error,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          ),
      ],
    );
  }
}

/// One cell of the modal's preview grid: preview plus file name.
class _FileGridCell extends StatelessWidget {
  const _FileGridCell({required this.file, required this.onRemove});
  final TexaLocalFile file;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: theme.colorScheme.outline.withValues(alpha: 0.5),
                  ),
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.3,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: _FileThumbnailContent(file: file, large: true),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              file.data.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        Positioned(
          top: -6,
          right: -6,
          child: IconButton(
            tooltip: tr.session.inputFile.removeFile,
            onPressed: onRemove,
            icon: const Icon(Symbols.close, size: 14, color: Colors.white),
            style: IconButton.styleFrom(
              backgroundColor: texaRed,
              minimumSize: const Size(24, 24),
              padding: EdgeInsets.zero,
            ),
          ),
        ),
      ],
    );
  }
}

class _FileThumbnailContent extends StatelessWidget {
  const _FileThumbnailContent({required this.file, this.large = false});
  final TexaLocalFile file;
  final bool large;

  @override
  Widget build(BuildContext context) {
    if (file.type == TexaFileType.image) {
      return FutureBuilder<Uint8List>(
        future: file.data.readAsBytes(),
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            return Image.memory(snapshot.data!, fit: BoxFit.cover);
          }
          return const Center(
            child: SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        },
      );
    }
    if (file.type == TexaFileType.audio) {
      return _AudioPlayerThumbnail(file: file);
    }
    final IconData icon = switch (file.type) {
      TexaFileType.video => Symbols.videocam_rounded,
      TexaFileType.document => Symbols.description_rounded,
      _ => Symbols.insert_drive_file_rounded,
    };
    return Center(
      child: Icon(
        icon,
        size: large ? 44 : 22,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}
