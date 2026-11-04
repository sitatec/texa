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
      <String, ({List<List<Offset>> curves, double yMin, double yMax})>{};

  @override
  void paint(Canvas canvas, Size size) {
    final e = element;
    final series = e.plotSeries;
    if (series.isEmpty) return;
    final xMin = e.xMin ?? -10, xMax = e.xMax ?? 10;
    final key =
        '${e.id}|${series.map((s) => '${s.expression}:${s.color?.toARGB32()}').join('|')}|$xMin|$xMax|${e.yMin}|${e.yMax}';
    final sampled = _plotCache.putIfAbsent(
      key,
      () => samplePlotSeries(
        [for (final s in series) s.expression],
        xMin,
        xMax,
        e.yMin,
        e.yMax,
      ),
    );
    if (sampled.curves.every((c) => c.isEmpty)) return;
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
    _paintTicks(
      canvas,
      rect,
      mx: mx,
      my: my,
      xMin: xMin,
      xMax: xMax,
      yMin: sampled.yMin,
      yMax: sampled.yMax,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0xFFD1D5DB)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    // Clip - do NOT clamp: clamping an out-of-range y to the range
    // edge bent straight lines flat along the top/bottom border
    // until they re-entered (the "bend at the corner" in reports).
    // Mapping the true point and clipping the canvas instead lets a
    // line leave through the border at its real angle.
    canvas.save();
    canvas.clipRect(rect);
    for (var s = 0; s < sampled.curves.length; s++) {
      final points = sampled.curves[s];
      final paint = Paint()
        ..color =
            (series[s].color ?? plotSeriesPalette[s % plotSeriesPalette.length])
                .withValues(alpha: progress)
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      final path = Path();
      var penDown = false;
      final total = points.length;
      final visible = (total * progress).ceil();
      for (var i = 0; i < math.min(visible, total); i++) {
        final p = points[i];
        if (p.dx.isNaN) {
          penDown = false;
          continue;
        }
        final o = Offset(mx(p.dx), my(p.dy));
        if (!penDown) {
          path.moveTo(o.dx, o.dy);
          penDown = true;
        } else {
          path.lineTo(o.dx, o.dy);
        }
      }
      canvas.drawPath(path, paint);
    }
    canvas.restore();
    // Frame again over the clipped curves so an exiting line never
    // paints over the border.
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0xFFD1D5DB)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    if (series.length > 1) _paintLegend(canvas, rect, series);
    // No range-end labels (the former big -2 / 5 / 7.0 / -1.0 corner
    // numbers): the tick bars + their values now carry the reference,
    // and the oversized corner labels stood out enough to look like
    // specially-marked points. Tick labels therefore include the
    // range ends (see _paintTicks).
  }

  /// Small tick bars (usually every 1 unit) plus their values, on the
  /// zero axes when those are inside the plot and on the frame edge
  /// otherwise - without them a point's coordinates cannot be read
  /// off the curve, only the corner extremes were labelled before.
  void _paintTicks(
    Canvas canvas,
    Rect rect, {
    required double Function(double) mx,
    required double Function(double) my,
    required double xMin,
    required double xMax,
    required double yMin,
    required double yMax,
  }) {
    final tickPaint = Paint()
      ..color = const Color(0xFF9CA3AF)
      ..strokeWidth = 1.5;
    const labelStyle = TextStyle(color: Color(0xFF6B7280), fontSize: 13);
    final xZeroInside = yMin < 0 && yMax > 0;
    final yZeroInside = xMin < 0 && xMax > 0;
    final xAxisY = xZeroInside ? my(0) : rect.bottom;
    final yAxisX = yZeroInside ? mx(0) : rect.left;
    final xStep = plotTickStep(xMax - xMin);
    final yStep = plotTickStep(yMax - yMin);

    for (final v in plotTicks(xMin, xMax)) {
      final x = mx(v);
      final from = xZeroInside ? xAxisY - 5 : rect.bottom - 10;
      final to = xZeroInside ? xAxisY + 5 : rect.bottom;
      canvas.drawLine(Offset(x, from), Offset(x, to), tickPaint);
      // The origin label would collide with the y-axis labels.
      if (v == 0) continue;
      final text = plotTickLabel(v, xStep);
      final tp = TextPainter(
        text: TextSpan(text: text, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final lx = (x - tp.width / 2).clamp(rect.left, rect.right - tp.width);
      final ly = xZeroInside
          ? math.min(xAxisY + 6, rect.bottom - tp.height - 2)
          : rect.bottom - tp.height - 12;
      tp.paint(canvas, Offset(lx.toDouble(), ly));
    }
    for (final v in plotTicks(yMin, yMax)) {
      final y = my(v);
      final from = yZeroInside ? yAxisX - 5 : rect.left;
      final to = yZeroInside ? yAxisX + 5 : rect.left + 10;
      canvas.drawLine(Offset(from, y), Offset(to, y), tickPaint);
      if (v == 0) continue;
      final text = plotTickLabel(v, yStep);
      final tp = TextPainter(
        text: TextSpan(text: text, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final lx = yZeroInside
          ? math.max(rect.left + 2, yAxisX - tp.width - 8)
          : rect.left + 12;
      final ly = (y - tp.height / 2).clamp(rect.top, rect.bottom - tp.height);
      tp.paint(canvas, Offset(lx, ly.toDouble()));
    }
  }

  void _paintLegend(Canvas canvas, Rect rect, List<PlotSeries> series) {
    const style = TextStyle(color: Color(0xFF374151), fontSize: 16);
    final painters = <TextPainter>[];
    var maxWidth = 0.0;
    for (final s in series) {
      final tp = TextPainter(
        text: TextSpan(text: s.displayLabel, style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: math.max(60, rect.width - 90));
      painters.add(tp);
      maxWidth = math.max(maxWidth, tp.width);
    }
    const rowHeight = 22.0, swatchWidth = 26.0, padding = 8.0;
    final box = Rect.fromLTWH(
      rect.right - maxWidth - swatchWidth - padding * 3,
      rect.top + padding,
      maxWidth + swatchWidth + padding * 3,
      series.length * rowHeight + padding,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(box, const Radius.circular(6)),
      Paint()..color = Colors.white.withValues(alpha: 0.88 * progress),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(box, const Radius.circular(6)),
      Paint()
        ..color = const Color(0xFFD1D5DB)
        ..style = PaintingStyle.stroke,
    );
    for (var i = 0; i < series.length; i++) {
      final y = box.top + padding / 2 + i * rowHeight + rowHeight / 2;
      final color =
          series[i].color ?? plotSeriesPalette[i % plotSeriesPalette.length];
      canvas.drawLine(
        Offset(box.left + padding, y),
        Offset(box.left + padding + swatchWidth - 6, y),
        Paint()
          ..color = color.withValues(alpha: progress)
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round,
      );
      painters[i].paint(
        canvas,
        Offset(box.left + padding + swatchWidth, y - painters[i].height / 2),
      );
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
  final series = plotSeriesFromArgs(args);
  return BoardElement(
    id: args['element_id'] as String? ?? fallbackId,
    kind: BoardElementKind.plot,
    owner: BoardOwner.ai,
    width: n('width') ?? 420,
    height: n('height') ?? 260,
    expression: series.isNotEmpty
        ? series.first.expression
        : args['expression'] as String?,
    series: series,
    xMin: n('x_min'),
    xMax: n('x_max'),
    yMin: n('y_min'),
    yMax: n('y_max'),
    color: series.isNotEmpty && series.first.color != null
        ? series.first.color!
        : colorFromName(args['color'] as String?, const Color(0xFF1F2937)),
  );
}
