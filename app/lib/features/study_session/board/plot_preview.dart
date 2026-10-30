import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import 'board_models.dart';
import 'plotter.dart';

/// Paints one plot element (axes, frame, curve, range labels) exactly as
/// the board does. Shared between the board itself and the history,
/// where a saved `plot_function` call is re-rendered from its arguments.
class PlotPainter extends CustomPainter {
  PlotPainter(this.element, {this.progress = 1});

  final BoardElement element;
  final double progress;

  /// Plot sampling is pure but not cheap; cache per element content.
  static final _plotCache =
      <String, ({List<Offset> points, double yMin, double yMax})>{};

  @override
  void paint(Canvas canvas, Size size) {
    final e = element;
    final xMin = e.xMin ?? -10, xMax = e.xMax ?? 10;
    final key = '${e.id}|${e.expression}|$xMin|$xMax|${e.yMin}|${e.yMax}';
    final sampled = _plotCache.putIfAbsent(
      key,
      () => samplePlot(e.expression ?? '', xMin, xMax, e.yMin, e.yMax),
    );
    if (sampled.points.isEmpty) return;
    // The element rect, translated to the painter's own origin.
    final rect = Offset.zero & size;
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
      ..color = e.color.withValues(alpha: progress)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final path = Path();
    var penDown = false;
    final total = sampled.points.length;
    final visible = (total * progress).ceil();
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
        xMin.toStringAsFixed(xMin % 1 == 0 ? 0 : 1),
        Offset(rect.left, rect.bottom + 4),
      ),
      (
        xMax.toStringAsFixed(xMax % 1 == 0 ? 0 : 1),
        Offset(rect.right - 44, rect.bottom + 4),
      ),
      (sampled.yMax.toStringAsFixed(1), Offset(rect.left + 4, rect.top)),
      (
        sampled.yMin.toStringAsFixed(1),
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
  bool shouldRepaint(covariant PlotPainter old) =>
      old.element != element || old.progress != progress;
}

/// A plot element rendered as a widget, for the session history (the
/// board paints the same content directly on its canvas).
class PlotView extends StatelessWidget {
  const PlotView({super.key, required this.element});

  final BoardElement element;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: PlotPainter(element), size: Size.infinite);
}

/// Builds a throwaway plot [BoardElement] from a saved `plot_function`
/// call's arguments, purely so the history can re-render it.
BoardElement plotElementFromArgs(
  Map<String, dynamic> args, {
  String fallbackId = 'history-plot',
}) {
  double? n(String k) => (args[k] as num?)?.toDouble();
  return BoardElement(
    id: args['element_id'] as String? ?? fallbackId,
    kind: BoardElementKind.plot,
    owner: BoardOwner.ai,
    width: n('width') ?? 420,
    height: n('height') ?? 260,
    expression: args['expression'] as String?,
    xMin: n('x_min'),
    xMax: n('x_max'),
    yMin: n('y_min'),
    yMax: n('y_max'),
    color: colorFromName(args['color'] as String?, const Color(0xFF1F2937)),
  );
}
