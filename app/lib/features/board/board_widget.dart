import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
import 'board_models.dart';
import 'plotter.dart';

enum BoardTool { pen, eraser }

/// The unified 1200x1600 board: student ink, AI text/math/SVG/plots together.
class BoardView extends StatelessWidget {
  const BoardView({
    super.key,
    required this.elements,
    required this.tool,
    required this.penColor,
    required this.penWidth,
    required this.onStrokeStart,
    required this.onStrokeUpdate,
    required this.onStrokeEnd,
    required this.onErase,
    this.pointer,
    this.captureKey,
  });
  final List<BoardElement> elements;
  final BoardTool tool;
  final Color penColor;
  final double penWidth;
  final VoidCallback onStrokeStart;
  final void Function(Offset p) onStrokeUpdate;
  final VoidCallback onStrokeEnd;
  final void Function(Offset p) onErase;
  final ({Offset pos, String? label})? pointer;
  final GlobalKey? captureKey;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: captureKey,
      child: Container(
        width: boardWidth,
        height: boardHeight,
        color: Colors.white,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(painter: _BoardPainter(elements)),
            ),
            ...elements
                .where(
                  (e) =>
                      e.kind != BoardElementKind.stroke &&
                      e.kind != BoardElementKind.plot,
                )
                .map(
                  (e) => Positioned(
                    left: e.x,
                    top: e.y,
                    width: e.width,
                    height: math.max(24, e.height),
                    child: Opacity(
                      opacity: e.progress,
                      child: _elementWidget(e),
                    ),
                  ),
                ),
            if (pointer != null)
              Positioned(
                left: pointer!.pos.dx - 10,
                top: pointer!.pos.dy - 10,
                child: _Pointer(label: pointer!.label),
              ),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (d) {
                  if (tool == BoardTool.pen) {
                    onStrokeStart();
                    onStrokeUpdate(d.localPosition);
                  } else {
                    onErase(d.localPosition);
                  }
                },
                onPanUpdate: (d) {
                  if (tool == BoardTool.pen) {
                    onStrokeUpdate(d.localPosition);
                  } else {
                    onErase(d.localPosition);
                  }
                },
                onPanEnd: (_) {
                  if (tool == BoardTool.pen) onStrokeEnd();
                },
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
        child: const Icon(Icons.north_east, color: Colors.black87, size: 22),
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

class _BoardPainter extends CustomPainter {
  _BoardPainter(this.elements);
  final List<BoardElement> elements;
  @override
  void paint(Canvas canvas, Size size) {
    // Faint dot grid guides the eye without competing with ink.
    final dot = Paint()..color = const Color(0xFFE8EEF7);
    for (var x = 40.0; x < boardWidth; x += 40) {
      for (var y = 40.0; y < boardHeight; y += 40) {
        canvas.drawCircle(Offset(x, y), 2, dot);
      }
    }
    for (final e in elements) {
      canvas.saveLayer(
        Rect.fromLTWH(0, 0, boardWidth, boardHeight),
        Paint()..color = Colors.white.withValues(alpha: e.progress),
      );
      if (e.kind == BoardElementKind.stroke) {
        final paint = Paint()
          ..color = e.color
          ..strokeWidth = e.strokeWidth
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..style = PaintingStyle.stroke;
        final pts = e.points;
        if (pts.length == 1) {
          canvas.drawCircle(
            pts.first,
            e.strokeWidth / 2,
            paint..style = PaintingStyle.fill,
          );
        }
        for (var i = 1; i < pts.length; i++) {
          canvas.drawLine(pts[i - 1], pts[i], paint);
        }
      } else if (e.kind == BoardElementKind.plot) {
        _paintPlot(canvas, e);
      }
      canvas.restore();
    }
  }

  void _paintPlot(Canvas canvas, BoardElement e) {
    final xMin = e.xMin ?? -10, xMax = e.xMax ?? 10;
    final sampled = samplePlot(e.expression ?? '', xMin, xMax, e.yMin, e.yMax);
    if (sampled.points.isEmpty) return;
    final rect = e.rect;
    double mx(double x) => rect.left + (x - xMin) / (xMax - xMin) * rect.width;
    double my(double y) =>
        rect.bottom -
        (y - sampled.yMin) / (sampled.yMax - sampled.yMin) * rect.height;
    final axis = Paint()
      ..color = const Color(0xFF9CA3AF)
      ..strokeWidth = 2;
    if (sampled.yMin < 0 && sampled.yMax > 0) {
      canvas.drawLine(
        Offset(rect.left, my(0)),
        Offset(rect.right, my(0)),
        axis,
      );
    }
    if (xMin < 0 && xMax > 0) {
      canvas.drawLine(
        Offset(mx(0), rect.top),
        Offset(mx(0), rect.bottom),
        axis,
      );
    }
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0xFFD1D5DB)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    final paint = Paint()
      ..color = e.color
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final path = Path();
    var penDown = false;
    final total = sampled.points.length;
    final visible = (total * e.progress).ceil();
    for (var i = 0; i < math.min(visible, total); i++) {
      final p = sampled.points[i];
      if (p.dx.isNaN) {
        penDown = false;
        continue;
      }
      final o = Offset(mx(p.dx), my(p.dy.clamp(sampled.yMin, sampled.yMax)));
      if (!penDown) {
        path.moveTo(o.dx, o.dy);
        penDown = true;
      } else {
        path.lineTo(o.dx, o.dy);
      }
    }
    canvas.drawPath(path, paint);
    final labelStyle = const TextStyle(color: Color(0xFF6B7280), fontSize: 20);
    for (final (text, pos) in [
      (
        (xMin.toStringAsFixed(xMin % 1 == 0 ? 0 : 1)),
        Offset(rect.left, rect.bottom + 4),
      ),
      (
        (xMax.toStringAsFixed(xMax % 1 == 0 ? 0 : 1)),
        Offset(rect.right - 44, rect.bottom + 4),
      ),
      ((sampled.yMax.toStringAsFixed(1)), Offset(rect.left + 4, rect.top)),
      (
        (sampled.yMin.toStringAsFixed(1)),
        Offset(rect.left + 4, rect.bottom - 26),
      ),
    ]) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, pos);
    }
  }

  @override
  bool shouldRepaint(covariant _BoardPainter old) => true;
}
