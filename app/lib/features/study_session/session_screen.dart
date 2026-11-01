import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import 'package:texa/core/constants.dart';
import 'package:texa/core/utils/fullscreen_manager.dart';
import 'package:texa/core/widgets/texa_app_bar.dart';

import '../../core/theme.dart';
import '../../generated/i18n/translations.g.dart';
import 'ai/ai_client.dart';
import 'board/board_models.dart';
import 'board/board_widget.dart';
import 'file_attachment/input_file_widget.dart';
import 'session_history/session_history_entry.dart';
import 'session_controller.dart';

/// The board-first tutoring session screen.
class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.controller});
  final SessionController controller;
  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  BoardTool _tool = BoardTool.pen;
  Color _penColor = const Color(0xFF1F2937);
  double _penWidth = 4;
  double _eraserWidth = 8;
  bool _fullscreen = false;
  final _fullScreenManager = FullScreenManager();
  bool _moreOpen = false;

  /// The macOS headphones notice is shown once per app run, not on
  /// every session the student opens.
  static bool _macHeadphonesNoticeShown = false;
  bool _strokeUndoPushed = false;
  bool _boardPointerActive = false;
  List<TexaLocalFile> _attachments = [];

  /// True while [_attachments] are staged on the controller for the next
  /// turn; cleared (with the selection) once that turn takes them.
  bool _uploadsStaged = false;
  SessionController get c => widget.controller;

  bool get _isEraser => _tool == BoardTool.eraser;
  double get _activeWidth => _isEraser ? _eraserWidth : _penWidth;
  set _activeWidth(double v) {
    if (_isEraser) {
      _eraserWidth = v;
    } else {
      _penWidth = v;
    }
  }

  @override
  void initState() {
    super.initState();
    _fullScreenManager.listenToFullScreenChange((type) {
      if (type == .enterFullScreen) {
        _fullscreen = true;
      } else if (type == .exitFullScreen) {
        _fullscreen == false;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() {});
      });
    });
    unawaited(c.init());
    c.addListener(_onControllerChanged);
    // macOS has no echo cancellation in this version (see
    // SessionController): through speakers Texa would hear its own
    // voice and loop, so Mac students must be told to use headphones.
    // Skipped entirely once they ticked "Don't show again" on it.
    if (!_macHeadphonesNoticeShown &&
        !c.settings.macHeadphonesNoticeDismissed &&
        defaultTargetPlatform == TargetPlatform.macOS) {
      _macHeadphonesNoticeShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_showMacHeadphonesNotice());
      });
    }
  }

  Future<void> _showMacHeadphonesNotice() async {
    var dontShowAgain = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          constraints: BoxConstraints(maxWidth: 500),
          title: Text(tr.session.headphonesTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr.session.headphonesBody),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: dontShowAgain,
                onChanged: (v) =>
                    setDialogState(() => dontShowAgain = v ?? false),
                title: Text(tr.session.headphonesDontShowAgain),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () {
                if (dontShowAgain) {
                  unawaited(c.dismissMacHeadphonesNotice());
                }
                Navigator.pop(dialogContext);
              },
              child: Text(tr.common.gotIt),
            ),
          ],
        ),
      ),
    );
  }

  /// Once a turn takes the staged uploads, drop the visible selection so
  /// the same files are not staged (and sent) again on a later turn.
  void _onControllerChanged() {
    if (!_uploadsStaged || c.hasPendingUploads || _attachments.isEmpty) {
      return;
    }
    _uploadsStaged = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _attachments = []);
    });
  }

  @override
  void dispose() {
    c.removeListener(_onControllerChanged);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    c.dispose();
    _fullScreenManager.dispose();
    super.dispose();
  }

  Future<void> _toggleFullscreen() async {
    _fullscreen = !_fullscreen;
    if (_fullscreen) {
      _fullScreenManager.exitFullScreen();
    } else {
      _fullScreenManager.enterFullScreen();
    }
    setState(() {});
  }

  String _statusText() {
    final key = c.statusKey;
    if (key.startsWith('action:')) {
      // A specific thing is being done on the board right now.
      return actionStatusLabel(key.substring('action:'.length)) ??
          tr.session.working;
    }
    return switch (key) {
      'capturing' => tr.session.capturing,
      'thinking' => tr.session.thinking,
      'speaking' => tr.session.speaking,
      'working' => tr.session.working,
      'muted' => tr.session.muted,
      _ => tr.session.listening,
    };
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([c, c.speaker.currentChunk]),
      builder: (context, _) {
        final compact = MediaQuery.sizeOf(context).width < 600;
        return Scaffold(
          appBar: _fullscreen
              ? null
              : TexaAppBar(
                  height: 42,
                  centerTitle: true,
                  title: Text(
                    c.session.title,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontSize: 17),
                  ),
                  actions: [
                    IconButton(
                      tooltip: tr.session.history,
                      iconSize: 22,
                      icon: const Icon(Symbols.history),
                      onPressed: _showHistory,
                    ),
                  ],
                ),
          body: SafeArea(
            child: Stack(
              children: [
                Positioned.fill(
                  child: LayoutBuilder(
                    builder: (context, box) {
                      c.board.viewportSize = Size(box.maxWidth, box.maxHeight);
                      return InteractiveViewer(
                        transformationController: c.board.transform,
                        constrained: false,
                        panEnabled: !_boardPointerActive,
                        scaleEnabled: !_boardPointerActive,
                        minScale: 0.08,
                        maxScale: 4,
                        boundaryMargin: const EdgeInsets.all(400),
                        onInteractionStart: (_) => c.onManualCamera(),
                        child: BoardView(
                          controller: c.board,
                          tool: _tool,
                          penColor: _penColor,
                          penWidth: _penWidth,
                          captureKey: c.captureKey,
                          onDrawPointerDown: () {
                            if (!_boardPointerActive) {
                              setState(() => _boardPointerActive = true);
                            }
                          },
                          onDrawPointerUp: () {
                            if (_boardPointerActive) {
                              setState(() => _boardPointerActive = false);
                            }
                          },
                          onStrokeCancel: () {
                            _strokeUndoPushed = false;
                            c.board.cancelActiveStroke();
                          },
                          onStrokeStart: () {
                            c.onStudentDrawStart();
                            _strokeUndoPushed = false;
                          },
                          onStrokeUpdate: (p) {
                            if (!_strokeUndoPushed) {
                              c.board.beginStudentChange();
                              _strokeUndoPushed = true;
                              final seed = BoardElementStroke.create(
                                p,
                                _penColor,
                                _penWidth,
                              );
                              if (_tool == BoardTool.line) {
                                c.board.addLine(seed);
                              } else {
                                c.board.addStroke(seed);
                              }
                            } else if (_tool == BoardTool.line) {
                              c.board.updateLineEnd(p);
                            } else {
                              c.board.updateLastStroke(p);
                            }
                          },
                          onStrokeEnd: () {
                            _strokeUndoPushed = false;
                            c.board.finishStroke();
                            unawaited(c.flushSave());
                          },
                          onEraseStart: c.board.beginErase,
                          onEraseEnd: c.board.endErase,
                          onErase: (p) => c.board.eraseAt(p, _eraserWidth / 2),
                        ),
                      );
                    },
                  ),
                ),
                Positioned(
                  top: 4,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: isMobile ? 6 : 8,
                            height: isMobile ? 6 : 8,
                            decoration: BoxDecoration(
                              color:
                                  c.statusKey == 'capturing' ||
                                      c.statusKey == 'speaking' ||
                                      c.statusKey.startsWith('action:')
                                  ? texaGreen
                                  : texaYellow,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _statusText(),
                            style: TextStyle(
                              fontSize: isMobile ? 11 : 13,
                              color: Colors.white,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(left: 10, top: 64, child: _toolbar()),
                Positioned(right: 10, top: 64, child: _overlays(compact)),
                if (c.replyActive)
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: FilledButton.icon(
                      onPressed: () => c.stopPlayback(),
                      style: FilledButton.styleFrom(
                        backgroundColor: texaRed,
                        visualDensity: .compact,
                        padding: .symmetric(vertical: 2, horizontal: 8),
                      ),
                      icon: const Icon(Symbols.stop),
                      label: Text(tr.session.stop),
                    ),
                  ),
                if (!c.hasMicPermission && !c.micMuted)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 16,
                    child: _hintCard(tr.session.drawOnlyHint),
                  ),
                if (c.errorMessage != null)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 16,
                    child: Material(
                      color: const Color(0xFFFFF1F2),
                      borderRadius: BorderRadius.circular(14),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            const Icon(Symbols.error_outline, color: texaRed),
                            const SizedBox(width: 8),
                            Expanded(child: Text(c.errorMessage!)),
                            TextButton(
                              onPressed: () => unawaited(c.retryTurn()),
                              child: Text(tr.session.retryTurn),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (c.captionsOn && c.speaker.currentChunk.value != null)
                  Positioned(
                    left: 14,
                    right: 14,
                    bottom: 16,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.84),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        c.speaker.currentChunk.value!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Files picked in the upload modal are staged, not sent: they ride
  /// along with the student's next explicit turn (there is no text
  /// composer by design, so that turn is their next spoken turn).
  void _onUploadModalClosed(List<TexaLocalFile> files) {
    unawaited(_stageAttachments(files));
  }

  Future<void> _stageAttachments(List<TexaLocalFile> files) async {
    final uploads = <AiUpload>[];
    for (final f in files) {
      final mime = f.mimeType;
      final isText =
          mime.startsWith('text/') ||
          mime == 'application/json' ||
          f.data.name.toLowerCase().endsWith('.md');
      try {
        if (isText) {
          uploads.add(
            AiUpload(
              name: f.data.name,
              mimeType: mime,
              text: utf8.decode(
                await f.data.readAsBytes(),
                allowMalformed: true,
              ),
            ),
          );
        } else {
          // Image, video, audio and document uploads all carry their bytes;
          // AiClient picks the request part (image_url, video_url,
          // input_audio, file) from the MIME type.
          uploads.add(
            AiUpload(
              name: f.data.name,
              mimeType: mime,
              base64: base64Encode(await f.data.readAsBytes()),
            ),
          );
        }
      } catch (_) {
        uploads.add(AiUpload(name: f.data.name, mimeType: mime));
      }
    }
    c.stageUploads(uploads);
    if (mounted) setState(() => _uploadsStaged = uploads.isNotEmpty);
  }

  Widget _hintCard(String text) => Material(
    color: const Color(0xFFFFFBEB),
    borderRadius: BorderRadius.circular(14),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          const Icon(Symbols.info, color: Color(0xFFD97706)),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    ),
  );

  Widget _toolbar() => ListenableBuilder(
    listenable: c.board,
    builder: (context, _) => Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(16),
      color: Colors.white.withValues(alpha: 0.94),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          spacing: 2,
          children: [
            IconButton(
              visualDensity: .compact,
              iconSize: 19,
              tooltip: tr.session.pen,
              isSelected: _tool == BoardTool.pen,
              icon: const Icon(Symbols.edit),
              onPressed: () => setState(() => _tool = BoardTool.pen),
            ),
            IconButton(
              visualDensity: .compact,
              iconSize: 20,
              tooltip: tr.session.lineTool,
              isSelected: _tool == BoardTool.line,
              icon: const Icon(Symbols.diagonal_line),
              onPressed: () => setState(() => _tool = BoardTool.line),
            ),
            IconButton(
              visualDensity: .compact,
              iconSize: 17,
              tooltip: tr.session.eraser,
              isSelected: _tool == BoardTool.eraser,
              icon: const Icon(Symbols.cleaning_services),
              onPressed: () => setState(() => _tool = BoardTool.eraser),
            ),
            IconButton(
              visualDensity: .compact,
              iconSize: 20,
              tooltip: tr.session.undo,
              icon: const Icon(Symbols.undo),
              onPressed: c.board.canUndo
                  ? () {
                      c.board.undo();
                    }
                  : null,
            ),
            IconButton(
              visualDensity: .compact,
              iconSize: 20,
              tooltip: tr.session.redo,
              icon: const Icon(Symbols.redo),
              onPressed: c.board.canRedo
                  ? () {
                      c.board.redo();
                    }
                  : null,
            ),
            IconButton(
              visualDensity: .compact,
              iconSize: 22,
              tooltip: tr.session.clearBoard,
              icon: const Icon(Symbols.delete_sweep),
              onPressed: _confirmClear,
            ),
            const SizedBox(height: 6),
            Tooltip(
              message: tr.session.penColor,
              child: GestureDetector(
                onTap: _pickPenColor,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: _penColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.black26, width: 2),
                  ),
                  child: const Icon(
                    Symbols.palette,
                    size: 13,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Tooltip(
              message: _isEraser
                  ? tr.session.eraserWidth
                  : tr.session.strokeWidth,
              child: SizedBox(
                width: 28,
                height: 56,
                child: RotatedBox(
                  quarterTurns: 1,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      thumbShape: RoundSliderThumbShape(
                        enabledThumbRadius: 8.0,
                      ),
                    ),
                    child: Slider(
                      value: _activeWidth,
                      min: 2,
                      max: _isEraser ? 40 : 12,
                      divisions: _isEraser ? 21 : 10,
                      label: _activeWidth.round().toString(),
                      onChanged: (v) => setState(() => _activeWidth = v),
                      padding: .zero,
                    ),
                  ),
                ),
              ),
            ),
            Text(
              _activeWidth.round().toString(),
              style: const TextStyle(fontSize: 10, color: Colors.black54),
            ),
          ],
        ),
      ),
    ),
  );

  /// Colour picker overlay: a compact swatch palette shown on demand
  /// from the single colour button in the toolbar.
  Future<void> _pickPenColor() async {
    const palette = [
      Color(0xFF1F2937),
      Color(0xFF3B82F6),
      Color(0xFFEF4444),
      Color(0xFF10B981),
      Color(0xFFF59E0B),
      Color(0xFF8B5CF6),
      Color(0xFFEC4899),
      Color(0xFF06B6D4),
      Color(0xFF84CC16),
      Color(0xFFF97316),
      Color(0xFF6B7280),
      Color(0xFF000000),
    ];
    final picked = await showDialog<Color>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr.session.penColor),
        content: SizedBox(
          width: 264,
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final col in palette)
                GestureDetector(
                  onTap: () => Navigator.pop(dialogContext, col),
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: col,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _penColor == col ? Colors.black : Colors.black12,
                        width: _penColor == col ? 3 : 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) {
      setState(() {
        _penColor = picked;
        _tool = BoardTool.pen;
      });
    }
  }

  Widget _overlays(bool compact) {
    final buttons = [
      TexaInputFileWidget(
        initialValue: _attachments,
        iconOnly: true,
        icon: const Icon(Symbols.attach_file),
        onChanged: (files) => setState(() => _attachments = files),
        onModalClosed: _onUploadModalClosed,
      ),
      const SizedBox(height: 2),
      IconButton(
        visualDensity: .compact,
        iconSize: 20,
        tooltip: c.micMuted ? tr.session.micOff : tr.session.micOn,
        icon: Icon(
          c.micMuted ? Symbols.mic_off : Symbols.mic,
          color: c.micMuted ? texaRed : null,
        ),
        onPressed: () => c.setMuted(!c.micMuted),
      ),
      const SizedBox(height: 2),
      IconButton(
        visualDensity: .compact,
        iconSize: 20,
        tooltip: c.captionsOn ? tr.session.captionsOn : tr.session.captionsOff,
        icon: Icon(
          c.captionsOn ? Symbols.closed_caption : Symbols.closed_caption_off,
        ),
        onPressed: () => setState(() => c.captionsOn = !c.captionsOn),
      ),
      const SizedBox(height: 2),
      IconButton(
        visualDensity: .compact,
        iconSize: 18,
        tooltip: tr.session.fullscreen,
        icon: Icon(_fullscreen ? Symbols.fullscreen_exit : Symbols.fullscreen),
        onPressed: _toggleFullscreen,
      ),
    ];
    if (!compact) {
      return Material(
        elevation: 2,
        borderRadius: BorderRadius.circular(12),
        color: Colors.white.withValues(alpha: 0.94),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Column(children: buttons),
        ),
      );
    }
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(12),
      color: Colors.white.withValues(alpha: 0.94),
      child: Column(
        children: [
          IconButton(
            tooltip: tr.session.more,
            icon: const Icon(Symbols.more_horiz),
            onPressed: () => setState(() => _moreOpen = !_moreOpen),
          ),
          if (_moreOpen) ...buttons,
        ],
      ),
    );
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(tr.session.clearTitle),
        content: Text(tr.session.clearBody),
        constraints: BoxConstraints(maxWidth: 500),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr.common.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr.session.clearBoard),
          ),
        ],
      ),
    );
    if (ok == true) {
      c.board.clear();
      await c.flushSave();
    }
  }

  void _showHistory() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          if (c.messages.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Text(tr.session.noHistory),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: c.messages
                .map((m) => SessionHistoryEntry(message: m))
                .toList(),
          );
        },
      ),
    );
  }
}

/// Helper so stroke creation stays terse in the screen.
extension BoardElementStroke on BoardElement {
  static BoardElement create(Offset p, Color color, double width) =>
      BoardElement(
        id: 's_${DateTime.now().microsecondsSinceEpoch}',
        kind: BoardElementKind.stroke,
        owner: BoardOwner.student,
        color: color,
        strokeWidth: width,
        points: [p],
      );
}
