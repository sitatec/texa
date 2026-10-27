import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../generated/i18n/translations.g.dart';
import '../board/board_models.dart';
import '../board/board_widget.dart';
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
  final double _penWidth = 4;
  bool _fullscreen = false;
  bool _moreOpen = false;
  bool _strokeUndoPushed = false;
  bool _eraseUndoPushed = false;
  final TextEditingController _question = TextEditingController();
  SessionController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    unawaited(c.init());
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _question.dispose();
    c.dispose();
    super.dispose();
  }

  Future<void> _toggleFullscreen() async {
    _fullscreen = !_fullscreen;
    await SystemChrome.setEnabledSystemUIMode(
      _fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    setState(() {});
  }

  String _statusText() => switch (c.statusKey) {
    'capturing' => tr.session.capturing,
    'thinking' => tr.session.thinking,
    'speaking' => tr.session.speaking,
    'muted' => tr.session.muted,
    _ => tr.session.listening,
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([c, c.board, c.speaker.currentChunk]),
      builder: (context, _) {
        final compact = MediaQuery.sizeOf(context).width < 600;
        return Scaffold(
          appBar: _fullscreen
              ? null
              : AppBar(
                  title: Text(c.session.title, overflow: TextOverflow.ellipsis),
                  actions: [
                    PopupMenuButton<String>(
                      initialValue: c.session.subject,
                      tooltip: tr.session.subject,
                      icon: const Icon(Icons.school_outlined),
                      onSelected: (v) => c.setSubject(v == 'none' ? null : v),
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'none', child: Text('—')),
                        ...subjectOptions.map(
                          (s) => PopupMenuItem(value: s, child: Text(s)),
                        ),
                      ],
                    ),
                    Chip(
                      label: Text(
                        c.session.model,
                        style: const TextStyle(fontSize: 11),
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      tooltip: tr.session.history,
                      icon: const Icon(Icons.history),
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
                        minScale: 0.08,
                        maxScale: 4,
                        boundaryMargin: const EdgeInsets.all(400),
                        onInteractionStart: (_) => c.onManualCamera(),
                        child: BoardView(
                          elements: c.board.elements,
                          tool: _tool,
                          penColor: _penColor,
                          penWidth: _penWidth,
                          captureKey: c.captureKey,
                          pointer: c.board.pointer,
                          onStrokeStart: () {
                            c.onStudentDrawStart();
                            _strokeUndoPushed = false;
                          },
                          onStrokeUpdate: (p) {
                            if (!_strokeUndoPushed) {
                              c.board.beginStudentChange();
                              _strokeUndoPushed = true;
                              c.board.addStroke(
                                BoardElementStroke.create(
                                  p,
                                  _penColor,
                                  _penWidth,
                                ),
                              );
                            } else {
                              c.board.updateLastStroke(p);
                            }
                          },
                          onStrokeEnd: () {
                            _strokeUndoPushed = false;
                            unawaited(c.flushSave());
                          },
                          onErase: (p) {
                            if (!_eraseUndoPushed) {
                              c.board.beginStudentChange();
                              _eraseUndoPushed = true;
                            }
                            c.board.eraseAt(p, 26);
                            Future<void>.microtask(
                              () => _eraseUndoPushed = false,
                            );
                          },
                        ),
                      );
                    },
                  ),
                ),
                Positioned(
                  top: 10,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 9,
                            height: 9,
                            decoration: BoxDecoration(
                              color:
                                  c.state == TurnState.capturing ||
                                      c.state == TurnState.speaking
                                  ? texaGreen
                                  : texaYellow,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _statusText(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(left: 10, top: 64, child: _toolbar()),
                Positioned(right: 10, top: 64, child: _overlays(compact)),
                if (c.state == TurnState.speaking)
                  Positioned(
                    right: 10,
                    top: compact && _moreOpen ? 300 : 124,
                    child: FilledButton.icon(
                      onPressed: () => c.stopPlayback(),
                      style: FilledButton.styleFrom(backgroundColor: texaRed),
                      icon: const Icon(Icons.stop),
                      label: Text(tr.session.stop),
                    ),
                  ),
                if (!c.hasMicPermission && !c.micMuted)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 118,
                    child: _hintCard(tr.session.drawOnlyHint),
                  ),
                if (c.errorMessage != null)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 118,
                    child: Material(
                      color: const Color(0xFFFFF1F2),
                      borderRadius: BorderRadius.circular(14),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline, color: texaRed),
                            const SizedBox(width: 8),
                            Expanded(child: Text(c.errorMessage!)),
                            TextButton(
                              onPressed: () {
                                final t = c.lastFailedText;
                                c.errorMessage = null;
                                unawaited(c.askTexa(t ?? ''));
                              },
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
                    bottom: 92,
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
                Positioned(
                  left: 10,
                  right: 10,
                  bottom: 10,
                  child: Material(
                    elevation: 3,
                    borderRadius: BorderRadius.circular(16),
                    color: Theme.of(context).colorScheme.surface,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _question,
                              decoration: InputDecoration(
                                hintText: tr.session.typeQuestion,
                                border: InputBorder.none,
                              ),
                              onSubmitted: (_) => _ask(),
                            ),
                          ),
                          FilledButton.icon(
                            onPressed: c.state == TurnState.thinking
                                ? null
                                : _ask,
                            icon: const Icon(Icons.auto_awesome, size: 18),
                            label: Text(tr.session.askTexa),
                          ),
                        ],
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

  void _ask() {
    final t = _question.text.trim();
    _question.clear();
    unawaited(c.askTexa(t));
  }

  Widget _hintCard(String text) => Material(
    color: const Color(0xFFFFFBEB),
    borderRadius: BorderRadius.circular(14),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: Color(0xFFD97706)),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    ),
  );

  Widget _toolbar() => Material(
    elevation: 2,
    borderRadius: BorderRadius.circular(16),
    color: Colors.white.withValues(alpha: 0.94),
    child: Padding(
      padding: const EdgeInsets.all(6),
      child: Column(
        children: [
          IconButton(
            tooltip: tr.session.pen,
            isSelected: _tool == BoardTool.pen,
            icon: const Icon(Icons.edit),
            onPressed: () => setState(() => _tool = BoardTool.pen),
          ),
          IconButton(
            tooltip: tr.session.eraser,
            isSelected: _tool == BoardTool.eraser,
            icon: const Icon(Icons.cleaning_services_outlined),
            onPressed: () => setState(() => _tool = BoardTool.eraser),
          ),
          IconButton(
            tooltip: tr.session.undo,
            icon: const Icon(Icons.undo),
            onPressed: c.board.canUndo
                ? () {
                    c.board.undo();
                  }
                : null,
          ),
          IconButton(
            tooltip: tr.session.redo,
            icon: const Icon(Icons.redo),
            onPressed: c.board.canRedo
                ? () {
                    c.board.redo();
                  }
                : null,
          ),
          IconButton(
            tooltip: tr.session.clearBoard,
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _confirmClear,
          ),
          const SizedBox(height: 4),
          ...[const Color(0xFF1F2937), texaBlue, texaRed, texaGreen].map(
            (col) => GestureDetector(
              onTap: () => setState(() {
                _penColor = col;
                _tool = BoardTool.pen;
              }),
              child: Container(
                margin: const EdgeInsets.only(bottom: 6),
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: col,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _penColor == col ? Colors.black : Colors.white,
                    width: 2,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _overlays(bool compact) {
    final buttons = [
      IconButton(
        tooltip: c.micMuted ? tr.session.micOff : tr.session.micOn,
        icon: Icon(
          c.micMuted ? Icons.mic_off : Icons.mic,
          color: c.micMuted ? texaRed : null,
        ),
        onPressed: () => c.setMuted(!c.micMuted),
      ),
      IconButton(
        tooltip: c.captionsOn ? tr.session.captionsOn : tr.session.captionsOff,
        icon: Icon(
          c.captionsOn
              ? Icons.closed_caption
              : Icons.closed_caption_off_outlined,
        ),
        onPressed: () => setState(() => c.captionsOn = !c.captionsOn),
      ),
      IconButton(
        tooltip: tr.session.fullscreen,
        icon: Icon(_fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
        onPressed: _toggleFullscreen,
      ),
    ];
    if (!compact) {
      return Material(
        elevation: 2,
        borderRadius: BorderRadius.circular(16),
        color: Colors.white.withValues(alpha: 0.94),
        child: Column(children: buttons),
      );
    }
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(16),
      color: Colors.white.withValues(alpha: 0.94),
      child: Column(
        children: [
          IconButton(
            tooltip: tr.session.more,
            icon: const Icon(Icons.more_horiz),
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
            children: c.messages.map((m) {
              final text = m.role == 'ai'
                  ? (m.payload['text'] as String? ?? '')
                  : (m.payload['text'] as String? ?? '');
              final tools = m.payload['toolCalls'];
              return ListTile(
                leading: Icon(
                  m.role == 'ai' ? Icons.auto_awesome : Icons.person_outline,
                ),
                title: Text(m.role == 'ai' ? 'Texa' : 'You'),
                subtitle: Text(
                  [
                    if (text.isNotEmpty) text,
                    if (tools is List && tools.isNotEmpty)
                      tools.map((t) => (t as Map)['name']).join(', '),
                  ].join('\n'),
                ),
              );
            }).toList(),
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
