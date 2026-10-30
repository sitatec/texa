import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/constants.dart';
import '../../../core/theme.dart';
import '../board_controller.dart';
import 'board_models.dart';
import 'plot_preview.dart';

enum BoardTool { pen, line, eraser }

/// The unified landscape board: student ink, AI text/math/SVG/plots.
///
/// Performance: structural content (committed elements) and the live ink
/// stroke are separate layers. Drawing a stroke only repaints the ink
/// layer; committed elements repaint only when [BoardController.revision]
/// changes, and each rich element is its own RepaintBoundary.
class BoardView extends StatefulWidget {
  const BoardView({
    super.key,
    required this.controller,
    required this.tool,
    required this.penColor,
    required this.penWidth,
    required this.onStrokeStart,
    required this.onStrokeUpdate,
    required this.onStrokeEnd,
    required this.onErase,
    this.onEraseStart,
    this.onEraseEnd,
    this.captureKey,
    this.onDrawPointerDown,
    this.onDrawPointerUp,
    this.onStrokeCancel,
  });
  final BoardController controller;
  final BoardTool tool;
  final Color penColor;
  final double penWidth;
  final VoidCallback onStrokeStart;
  final void Function(Offset p) onStrokeUpdate;
  final VoidCallback onStrokeEnd;
  final void Function(Offset p) onErase;

  /// Bracket one erase drag (down -> up/cancel), so the host can treat
  /// the whole drag as a single undo step.
  final VoidCallback? onEraseStart;
  final VoidCallback? onEraseEnd;
  final GlobalKey? captureKey;

  /// Fired the instant a drawing/erasing pointer touches the board (and
  /// when it lifts), so the host can suspend camera gestures meanwhile.
  final VoidCallback? onDrawPointerDown;
  final VoidCallback? onDrawPointerUp;
  final VoidCallback? onStrokeCancel;

  @override
  State<BoardView> createState() => _BoardViewState();
}

class _BoardViewState extends State<BoardView> {
  /// Raw pointer events (not a pan gesture) drive drawing: a pan
  /// recogniser only reports after the finger crosses touch slop, which
  /// made ink appear late and in chunks. A [Listener] reports the very
  /// first pixel of movement.
  int? _activePointer;

  BoardController get controller => widget.controller;
  BoardTool get tool => widget.tool;

  void _pointerDown(PointerDownEvent e) {
    if (_activePointer != null) {
      // Second finger: abandon the stroke so a pinch can take over.
      if (tool != BoardTool.eraser) {
        if (widget.onStrokeCancel != null) {
          widget.onStrokeCancel!();
        } else {
          widget.onStrokeEnd();
        }
      }
      _activePointer = null;
      if (tool == BoardTool.eraser) widget.onEraseEnd?.call();
      widget.onDrawPointerUp?.call();
      return;
    }
    _activePointer = e.pointer;
    widget.onDrawPointerDown?.call();
    if (tool == BoardTool.eraser) {
      widget.onEraseStart?.call();
      widget.onErase(e.localPosition);
    } else {
      widget.onStrokeStart();
      widget.onStrokeUpdate(e.localPosition);
    }
  }

  void _pointerMove(PointerMoveEvent e) {
    if (e.pointer != _activePointer) return;
    if (tool == BoardTool.eraser) {
      widget.onErase(e.localPosition);
    } else {
      widget.onStrokeUpdate(e.localPosition);
    }
  }

  void _pointerUp(PointerEvent e) {
    if (e.pointer != _activePointer) return;
    _activePointer = null;
    widget.onDrawPointerUp?.call();
    if (tool == BoardTool.eraser) {
      widget.onEraseEnd?.call();
    } else {
      widget.onStrokeEnd();
    }
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: widget.captureKey,
      child: Container(
        width: boardWidth,
        height: boardHeight,
        color: Colors.white,
        child: Stack(
          children: [
            Positioned.fill(
              child: ListenableBuilder(
                listenable: controller,
                builder: (context, _) {
                  final elements = controller.elements;
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _BoardPainter(elements, controller.revision),
                        ),
                      ),
                      ...elements
                          .where(
                            (e) =>
                                e.kind != BoardElementKind.stroke &&
                                e.kind != BoardElementKind.plot &&
                                e.kind != BoardElementKind.landmark,
                          )
                          .map(
                            (e) => Positioned(
                              key: ValueKey(e.id),
                              left: e.x,
                              top: e.y,
                              // Text wraps at the board's right edge
                              // and takes whatever height its lines
                              // need - its stored box is measured from
                              // the content, and legacy boxes saved
                              // with a fixed height must not clip it.
                              width: e.kind == BoardElementKind.text
                                  ? math.min(
                                      e.width,
                                      math.max(1.0, boardWidth - e.x),
                                    )
                                  : e.width,
                              height: e.kind == BoardElementKind.text
                                  ? null
                                  : math.max(24, e.height),
                              child: RepaintBoundary(
                                child: Opacity(
                                  opacity: e.progress,
                                  child: _elementWidget(e),
                                ),
                              ),
                            ),
                          ),
                      if (controller.pointer != null)
                        Positioned(
                          left: controller.pointer!.pos.dx - 10,
                          top: controller.pointer!.pos.dy - 10,
                          child: _Pointer(label: controller.pointer!.label),
                        ),
                    ],
                  );
                },
              ),
            ),
            Positioned.fill(
              child: ListenableBuilder(
                listenable: controller.activeStrokeTick,
                builder: (context, _) => CustomPaint(
                  painter: _ActiveStrokePainter(
                    controller.activeStroke,
                    controller.activeStrokeTick.value,
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _pointerDown,
                onPointerMove: _pointerMove,
                onPointerUp: _pointerUp,
                onPointerCancel: _pointerUp,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _elementWidget(BoardElement e) {
    try {
      return switch (e.kind) {
        BoardElementKind.text => Align(
          alignment: Alignment.topLeft,
          child: Text(
            e.text ?? '',
            softWrap: true,
            style: TextStyle(
              color: e.color,
              fontSize: e.size,
              fontFamily: 'GoogleSansFlex',
              height: 1.15,
            ),
          ),
        ),
        BoardElementKind.math => Align(
          alignment: Alignment.topLeft,
          child: Math.tex(
            e.latex ?? '',
            mathStyle: MathStyle.display,
            textStyle: TextStyle(color: e.color, fontSize: e.size),
            onErrorFallback: (err) => Text(
              e.latex ?? '',
              style: TextStyle(color: texaRed, fontSize: e.size * 0.5),
            ),
          ),
        ),
        BoardElementKind.svg => SvgStringWidget(svg: e.svg ?? ''),
        _ => const SizedBox.shrink(),
      };
    } catch (_) {
      return const SizedBox.shrink();
    }
  }
}

/// SVG that fails quietly so a broken action can be skipped upstream.
class SvgStringWidget extends StatelessWidget {
  const SvgStringWidget({super.key, required this.svg});
  final String svg;
  @override
  Widget build(BuildContext context) {
    try {
      return SvgPicture.string(svg, fit: BoxFit.fill);
    } catch (_) {
      return const SizedBox.shrink();
    }
  }
}

class _Pointer extends StatelessWidget {
  const _Pointer({this.label});
  final String? label;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: texaYellow.withValues(alpha: 0.35),
          shape: BoxShape.circle,
          border: Border.all(color: texaYellow, width: 3),
        ),
        child: const Icon(Symbols.north_east, color: Colors.black87, size: 22),
      ),
      if (label != null)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label!,
            style: const TextStyle(color: Colors.white, fontSize: 20),
          ),
        ),
    ],
  );
}

class _ActiveStrokePainter extends CustomPainter {
  _ActiveStrokePainter(this.stroke, this.tick);
  final BoardElement? stroke;

  /// Monotonic counter bumped on every point change. Comparing this (not
  /// the mutated stroke object, which is identical on both sides) is what
  /// makes live ink repaint while the finger is still down.
  final int tick;
  @override
  void paint(Canvas canvas, Size size) {
    final e = stroke;
    if (e == null || e.points.isEmpty) return;
    _paintStroke(canvas, e);
  }

  @override
  bool shouldRepaint(covariant _ActiveStrokePainter old) =>
      old.tick != tick ||
      old.stroke != stroke ||
      old.stroke?.points.length != stroke?.points.length;
}

void _paintStroke(Canvas canvas, BoardElement e) {
  final paint = Paint()
    ..color = e.color.withValues(alpha: e.progress)
    ..strokeWidth = e.strokeWidth
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke;
  final pts = e.points;
  if (pts.length == 1) {
    canvas.drawCircle(
      pts.first,
      e.strokeWidth / 2,
      Paint()..color = paint.color,
    );
    return;
  }
  final path = Path()..moveTo(pts.first.dx, pts.first.dy);
  for (var i = 1; i < pts.length; i++) {
    path.lineTo(pts[i].dx, pts[i].dy);
  }
  canvas.drawPath(path, paint);
}

class _BoardPainter extends CustomPainter {
  _BoardPainter(this.elements, this.revision);
  final List<BoardElement> elements;
  final int revision;

  @override
  void paint(Canvas canvas, Size size) {
    // Faint dot grid guides the eye without competing with ink.
    final dot = Paint()..color = const Color(0xFFD3D9E4);
    for (var x = 40.0; x < boardWidth; x += 40) {
      for (var y = 40.0; y < boardHeight; y += 40) {
        canvas.drawCircle(Offset(x, y), 2, dot);
      }
    }
    for (final e in elements) {
      if (e.kind == BoardElementKind.stroke) {
        _paintStroke(canvas, e);
      } else if (e.kind == BoardElementKind.plot) {
        _paintPlot(canvas, e);
      } else if (e.kind == BoardElementKind.landmark) {
        _paintLandmark(canvas, e);
      }
    }
  }

  void _paintLandmark(Canvas canvas, BoardElement e) {
    final fill = Paint()
      ..color = e.color.withValues(alpha: e.progress)
      ..style = PaintingStyle.fill;
    final ring = Paint()
      ..color = Colors.white.withValues(alpha: e.progress)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    for (final pt in e.points) {
      canvas.drawCircle(pt, e.size * 0.62, fill);
      canvas.drawCircle(pt, e.size * 0.62, ring);
      canvas.drawCircle(pt, 3, Paint()..color = Colors.white);
    }
    if (e.points.isNotEmpty && (e.text?.isNotEmpty ?? false)) {
      final tp = TextPainter(
        text: TextSpan(
          text: e.text,
          style: TextStyle(
            color: const Color(0xFF111827).withValues(alpha: e.progress),
            fontSize: 19,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, e.points.first + const Offset(14, -12));
    }
  }

  void _paintPlot(Canvas canvas, BoardElement e) {
    canvas.save();
    canvas.translate(e.x, e.y);
    PlotPainter(e, progress: e.progress).paint(canvas, e.rect.size);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BoardPainter old) =>
      old.revision != revision || !identical(old.elements, elements);
}
