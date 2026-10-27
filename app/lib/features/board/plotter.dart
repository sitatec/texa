import 'package:flutter/material.dart';
import 'package:math_expressions/math_expressions.dart';

/// Samples an analytic expression in x for plotting. Never takes coordinates.
({List<Offset> points, double yMin, double yMax}) samplePlot(
  String expression,
  double xMin,
  double xMax,
  double? reqYMin,
  double? reqYMax, {
  int samples = 240,
}) {
  final ExpressionParser parser = GrammarParser();
  Expression exp;
  try {
    exp = parser.parse(expression);
  } catch (_) {
    return (points: <Offset>[], yMin: reqYMin ?? -10, yMax: reqYMax ?? 10);
  }
  final cm = ContextModel();
  final evaluator = RealEvaluator(cm);
  final raw = <Offset>[];
  var lo = double.infinity, hi = double.negativeInfinity;
  for (var i = 0; i <= samples; i++) {
    final x = xMin + (xMax - xMin) * i / samples;
    cm.bindVariableName('x', Number(x));
    double y;
    try {
      y = evaluator.evaluate(exp).toDouble();
    } catch (_) {
      continue;
    }
    if (y.isFinite) {
      raw.add(Offset(x, y));
      if (y < lo) lo = y;
      if (y > hi) hi = y;
    }
  }
  if (raw.isEmpty) {
    return (points: raw, yMin: reqYMin ?? -10, yMax: reqYMax ?? 10);
  }
  var yMin = reqYMin ?? lo, yMax = reqYMax ?? hi;
  if (yMax - yMin < 1e-6) {
    yMin -= 1;
    yMax += 1;
  }
  final pad = (yMax - yMin) * 0.08;
  if (reqYMin == null) yMin -= pad;
  if (reqYMax == null) yMax += pad;
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
  return (points: out, yMin: yMin, yMax: yMax);
}
