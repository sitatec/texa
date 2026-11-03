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

enum BoardTool { pan, pen, line, eraser }

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
    // Pan tool: draw nothing and report nothing. Crucially,
    // onDrawPointerDown is not called, so the host never disables the
    // surrounding InteractiveViewer and the drag becomes a board pan
    // (single finger / mouse, no trackpad or pinch needed).
    if (tool == BoardTool.pan) return;
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
    if (tool == BoardTool.pan) return;
    if (e.pointer != _activePointer) return;
    if (tool == BoardTool.eraser) {
      widget.onErase(e.localPosition);
    } else {
      widget.onStrokeUpdate(e.localPosition);
    }
  }

  void _pointerUp(PointerEvent e) {
    if (tool == BoardTool.pan) return;
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
    return MouseRegion(
      cursor: tool == BoardTool.pan
          ? SystemMouseCursors.grab
          : SystemMouseCursors.basic,
      child: RepaintBoundary(
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
                  builder: (context, _) => _BoardContent(
                    elements: controller.elements,
                    revision: controller.revision,
                    pointer: controller.pointer,
                  ),
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
      ),
    );
  }
}

/// Everything on the board except the live ink stroke and the input
/// listener: the dot grid, strokes/plots/landmarks (painted) and the
/// rich elements (widgets). Shared by the live board and
/// [BoardPreview], so a preview can never drift from how the board
/// itself renders the same elements.
class _BoardContent extends StatelessWidget {
  const _BoardContent({
    required this.elements,
    required this.revision,
    this.pointer,
  });
  final List<BoardElement> elements;
  final int revision;
  final ({Offset pos, String? label})? pointer;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(painter: _BoardPainter(elements, revision)),
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
                // Text wraps at the board's right edge and takes
                // whatever height its lines need - its stored box is
                // measured from the content, and legacy boxes saved
                // with a fixed height must not clip it.
                width: e.kind == BoardElementKind.text
                    ? math.min(e.width, math.max(1.0, boardWidth - e.x))
                    : e.width,
                height: e.kind == BoardElementKind.text
                    ? null
                    : math.max(24, e.height),
                child: RepaintBoundary(
                  child: Opacity(
                    opacity: e.progress,
                    child: _boardElementWidget(e),
                  ),
                ),
              ),
            ),
        if (pointer != null)
          Positioned(
            left: pointer!.pos.dx - 10,
            top: pointer!.pos.dy - 10,
            child: _Pointer(label: pointer!.label),
          ),
      ],
    );
  }
}

/// Read-only rendering of a persisted board, exactly as it was left:
/// every element at full opacity (never caught mid-animation), seen
/// through the camera the session was closed with - same zoom, same
/// pan - so the preview is a miniature of what reopening the session
/// shows. That needs the size of the viewport the camera was saved
/// in; snapshots saved before it was recorded fall back to fitting
/// the whole board. Used for the home list's board preview, replacing
/// the low-resolution raster thumbnail that could be captured before
/// the final board changes were drawn.
class BoardPreview extends StatelessWidget {
  const BoardPreview({super.key, required this.snapshot});
  final BoardSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final elements = snapshot.elements
        .map((e) => e.copyWith(progress: 1))
        .toList(growable: false);
    final board = SizedBox(
      width: boardWidth,
      height: boardHeight,
      child: _BoardContent(elements: elements, revision: 0),
    );
    final viewportSize = snapshot.cameraViewportSize;
    return ClipRect(
      child: ColoredBox(
        color: Colors.white,
        child: FittedBox(
          fit: BoxFit.contain,
          // Rebuild the session viewport at its saved size, apply
          // the saved camera to the board inside it, and let the
          // FittedBox shrink that whole viewport into the preview.
          child: viewportSize == null
              ? board
              : SizedBox.fromSize(
                  size: viewportSize,
                  child: ClipRect(
                    child: Transform(
                      transform: snapshot.cameraTransform,
                      alignment: Alignment.topLeft,
                      child: board,
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

Widget _boardElementWidget(BoardElement e) {
  try {
    return switch (e.kind) {
      BoardElementKind.text => Align(
        alignment: Alignment.topLeft,
        child: Text(
          e.text ?? '',
          softWrap: true,
          // Must stay identical to the style BoardController measures
          // with, or the measured box no longer fits the rendered text.
          style: BoardController.boardTextStyle(e.size, color: e.color),
        ),
      ),
      BoardElementKind.math => _FittedMath(
        latex: e.latex ?? '',
        fontSize: e.size,
        color: e.color,
      ),
      BoardElementKind.svg => SvgStringWidget(svg: e.svg ?? ''),
      _ => const SizedBox.shrink(),
    };
  } catch (_) {
    return const SizedBox.shrink();
  }
}

/// LaTeX rendered inside its element's box by shrinking the font,
/// never by growing the box.
///
/// A formula cannot wrap, so at the model's requested font size it can
/// be wider (or taller) than its box and the renderer overflows
/// ("RIGHT OVERFLOWED BY 73 PIXELS"). Instead of resizing the element,
/// the formula's natural rendered size is measured at the requested
/// font size (an invisible, unconstrained copy below) and the visible
/// copy is rendered at the largest font size, up to the requested one,
/// that fits the box in both dimensions. Because fitting is derived
/// deterministically from (latex, requested size, box), it also covers
/// elements edited after creation and legacy elements saved with an
/// over-sized font. The visible copy appears one frame after the
/// measurement, while the element is still fading in.
class _FittedMath extends StatefulWidget {
  const _FittedMath({
    required this.latex,
    required this.fontSize,
    required this.color,
  });
  final String latex;
  final double fontSize;
  final Color color;

  @override
  State<_FittedMath> createState() => _FittedMathState();
}

class _FittedMathState extends State<_FittedMath> {
  final _measureKey = GlobalKey();
  double? _fittedFontSize;
  String? _fittedFor;

  String _signature(Size avail) =>
      '${widget.latex}|${widget.fontSize}|${avail.width}x${avail.height}';

  Widget _math(double fontSize, {Key? key}) => Math.tex(
    widget.latex,
    key: key,
    mathStyle: MathStyle.display,
    textStyle: TextStyle(color: widget.color, fontSize: fontSize),
    onErrorFallback: (err) => Text(
      widget.latex,
      style: TextStyle(color: texaRed, fontSize: fontSize * 0.5),
    ),
  );

  void _scheduleFit(Size avail) {
    final signature = _signature(avail);
    if (_fittedFor == signature) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _fittedFor == signature) return;
      final measured =
          _measureKey.currentContext?.findRenderObject() as RenderBox?;
      // Unmeasurable (should not happen): fall back to the requested
      // size rather than rendering nothing.
      var fitted = widget.fontSize;
      if (measured != null && measured.hasSize) {
        final natural = measured.size;
        var scale = 1.0;
        if (natural.width > 0) {
          scale = math.min(scale, (avail.width - 2) / natural.width);
        }
        if (natural.height > 0) {
          scale = math.min(scale, (avail.height - 2) / natural.height);
        }
        fitted = widget.fontSize * scale.clamp(0.05, 1.0);
      }
      setState(() {
        _fittedFor = signature;
        _fittedFontSize = fitted;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bounded =
            constraints.maxWidth.isFinite && constraints.maxHeight.isFinite;
        final avail = bounded
            ? Size(constraints.maxWidth, constraints.maxHeight)
            : Size.infinite;
        if (bounded) _scheduleFit(avail);
        final fitted = bounded && _fittedFor == _signature(avail)
            ? _fittedFontSize
            : (bounded ? null : widget.fontSize);
        return Stack(
          children: [
            const SizedBox.expand(),
            // Invisible measuring copy at the requested font size,
            // laid out unconstrained so its render size is the
            // formula's natural size.
            Positioned(
              left: 0,
              top: 0,
              // Bounded size for the OverflowBox itself; only its
              // child (the measuring copy) is laid out unconstrained.
              width: bounded ? avail.width : 0,
              height: bounded ? avail.height : 0,
              child: IgnorePointer(
                child: Opacity(
                  opacity: 0,
                  child: OverflowBox(
                    alignment: Alignment.topLeft,
                    minWidth: 0,
                    minHeight: 0,
                    maxWidth: double.infinity,
                    maxHeight: double.infinity,
                    child: _math(widget.fontSize, key: _measureKey),
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.topLeft,
              child: fitted == null ? const SizedBox.shrink() : _math(fitted),
            ),
          ],
        );
      },
    );
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
