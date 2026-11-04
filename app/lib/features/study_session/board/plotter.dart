import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:math_expressions/math_expressions.dart';

List<Offset> _sampleRaw(
  String expression,
  double xMin,
  double xMax,
  int samples,
) {
  final ExpressionParser parser = GrammarParser();
  Expression exp;
  try {
    exp = parser.parse(expression);
  } catch (_) {
    return <Offset>[];
  }
  final cm = ContextModel();
  final evaluator = RealEvaluator(cm);
  final raw = <Offset>[];
  for (var i = 0; i <= samples; i++) {
    final x = xMin + (xMax - xMin) * i / samples;
    cm.bindVariableName('x', Number(x));
    double y;
    try {
      y = evaluator.evaluate(exp).toDouble();
    } catch (_) {
      continue;
    }
    if (y.isFinite) raw.add(Offset(x, y));
  }
  return raw;
}

({double yMin, double yMax}) _yRange(
  Iterable<List<Offset>> curves,
  double? reqYMin,
  double? reqYMax,
) {
  var lo = double.infinity, hi = double.negativeInfinity;
  for (final raw in curves) {
    for (final p in raw) {
      if (p.dy < lo) lo = p.dy;
      if (p.dy > hi) hi = p.dy;
    }
  }
  if (lo == double.infinity) {
    return (yMin: reqYMin ?? -10, yMax: reqYMax ?? 10);
  }
  var yMin = reqYMin ?? lo, yMax = reqYMax ?? hi;
  if (yMax - yMin < 1e-6) {
    yMin -= 1;
    yMax += 1;
  }
  final pad = (yMax - yMin) * 0.08;
  if (reqYMin == null) yMin -= pad;
  if (reqYMax == null) yMax += pad;
  return (yMin: yMin, yMax: yMax);
}

List<Offset> _withBreaks(
  List<Offset> raw,
  double xMin,
  double xMax,
  double yMin,
  double yMax,
  int samples,
) {
  // Break the path at discontinuities by inserting NaN markers.
  final out = <Offset>[];
  for (var i = 0; i < raw.length; i++) {
    if (i > 0) {
      final jump = (raw[i].dy - raw[i - 1].dy).abs();
      if (jump > (yMax - yMin) * 1.5 ||
          (raw[i].dx - raw[i - 1].dx) > (xMax - xMin) / samples * 2.5) {
        out.add(const Offset(double.nan, double.nan));
      }
    }
    out.add(raw[i]);
  }
  return out;
}

/// Samples an analytic expression in x for plotting. Never takes coordinates.
({List<Offset> points, double yMin, double yMax}) samplePlot(
  String expression,
  double xMin,
  double xMax,
  double? reqYMin,
  double? reqYMax, {
  int samples = 240,
}) {
  final raw = _sampleRaw(expression, xMin, xMax, samples);
  if (raw.isEmpty) {
    return (points: raw, yMin: reqYMin ?? -10, yMax: reqYMax ?? 10);
  }
  final range = _yRange([raw], reqYMin, reqYMax);
  return (
    points: _withBreaks(raw, xMin, xMax, range.yMin, range.yMax, samples),
    yMin: range.yMin,
    yMax: range.yMax,
  );
}

/// Samples several expressions on one shared y-range, so curves plotted
/// together are directly comparable and cross at their true positions.
/// Curves are returned in the same order as [expressions].
({List<List<Offset>> curves, double yMin, double yMax}) samplePlotSeries(
  List<String> expressions,
  double xMin,
  double xMax,
  double? reqYMin,
  double? reqYMax, {
  int samples = 240,
}) {
  final raws = [
    for (final e in expressions) _sampleRaw(e, xMin, xMax, samples),
  ];
  final range = _yRange(raws, reqYMin, reqYMax);
  return (
    curves: [
      for (final raw in raws)
        _withBreaks(raw, xMin, xMax, range.yMin, range.yMax, samples),
    ],
    yMin: range.yMin,
    yMax: range.yMax,
  );
}

/// Data-space points where any two of [expressions] cross within
/// [xMin, xMax], found by sign changes of pairwise differences on a
/// common sample grid and refined by linear interpolation.
/// Spacing between axis tick marks for a data range: 1 unit whenever
/// that stays readable (the common classroom case the student asked
/// for), otherwise the next 1/2/5/10 step that keeps ~8 ticks.
double plotTickStep(double range) {
  if (!range.isFinite || range <= 0) return 1;
  final raw = range / 8;
  final magnitude = math
      .pow(10, (math.log(raw) / math.ln10).floor())
      .toDouble();
  final normalised = raw / magnitude;
  final factor = normalised < 1.5
      ? 1.0
      : normalised < 3.5
      ? 2.0
      : normalised < 7.5
      ? 5.0
      : 10.0;
  return factor * magnitude;
}

/// Tick values inside [min, max] at [plotTickStep] spacing, aligned to
/// multiples of the step (so integer data gets integer ticks).
List<double> plotTicks(double min, double max) {
  final step = plotTickStep(max - min);
  final out = <double>[];
  var v = (min / step).ceil() * step;
  // Guard against floating dust pushing the first tick past max.
  while (v <= max + step * 1e-9) {
    out.add(v == 0 ? 0 : v);
    v += step;
  }
  return out;
}

/// Label for a tick value: integers without a decimal point, smaller
/// steps with just the decimals they need.
String plotTickLabel(double value, double step) {
  if (step >= 1) return value.toStringAsFixed(0);
  final decimals = step >= 0.1 ? 1 : 2;
  return value.toStringAsFixed(decimals);
}

List<Offset> plotIntersections(
  List<String> expressions,
  double xMin,
  double xMax, {
  int samples = 480,
}) {
  if (expressions.length < 2) return const [];
  final parsers = <Expression?>[];
  for (final e in expressions) {
    try {
      parsers.add(GrammarParser().parse(e));
    } catch (_) {
      parsers.add(null);
    }
  }
  final cm = ContextModel();
  double? eval(Expression? exp, double x) {
    if (exp == null) return null;
    cm.bindVariableName('x', Number(x));
    try {
      final y = RealEvaluator(cm).evaluate(exp).toDouble();
      return y.isFinite ? y : null;
    } catch (_) {
      return null;
    }
  }

  final out = <Offset>[];
  final minGap = (xMax - xMin) / samples * 1.5;
  for (var a = 0; a < expressions.length; a++) {
    for (var b = a + 1; b < expressions.length; b++) {
      double? prevX, prevDiff;
      for (var i = 0; i <= samples; i++) {
        final x = xMin + (xMax - xMin) * i / samples;
        final ya = eval(parsers[a], x), yb = eval(parsers[b], x);
        final diff = (ya == null || yb == null) ? null : ya - yb;
        if (diff != null && prevDiff != null && prevX != null) {
          if (diff == 0 ||
              (prevDiff < 0 && diff > 0) ||
              (prevDiff > 0 && diff < 0)) {
            final t = prevDiff / (prevDiff - diff);
            final ix = prevX + t * (x - prevX);
            // Re-evaluate one curve at the crossing for its y value.
            final iy = eval(parsers[a], ix);
            if (iy != null &&
                (out.isEmpty || (out.last.dx - ix).abs() > minGap)) {
              out.add(Offset(ix, iy));
            }
          }
        }
        if (diff != null) {
          prevX = x;
          prevDiff = diff;
        } else {
          prevX = null;
          prevDiff = null;
        }
      }
    }
  }
  out.sort((a, b) => a.dx.compareTo(b.dx));
  return out;
}
