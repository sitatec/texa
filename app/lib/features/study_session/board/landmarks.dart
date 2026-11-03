import 'package:flutter/material.dart';

import 'board_models.dart';
import 'plotter.dart';

/// Computes board-space landmark points for an element, by name.
///
/// The model only ever supplies landmark *names* (never coordinates); the
/// app derives the exact points from what it already knows analytically:
/// the sampled curve of a plot, or the geometry inside an SVG it placed.
/// Returns an empty list for a name that doesn't apply to the element.
List<Offset> computeLandmarks(BoardElement target, String rawName) {
  final name = rawName.trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
  // Generic element-rect landmarks work for every kind.
  final rect = target.rect;
  switch (name) {
    case 'center':
      if (target.kind == BoardElementKind.plot) break; // refined below
      if (target.kind == BoardElementKind.svg) {
        final g = _svgGeometry(target);
        if (g != null) return [g.centroidOrCenter];
      }
      return [rect.center];
    case 'top_left':
      return [rect.topLeft];
    case 'top_right':
      return [rect.topRight];
    case 'bottom_left':
      return [rect.bottomLeft];
    case 'bottom_right':
      return [rect.bottomRight];
  }
  if (target.kind == BoardElementKind.plot) return _plotLandmark(target, name);
  if (target.kind == BoardElementKind.svg) return _svgLandmark(target, name);
  return const [];
}

List<Offset> _plotLandmark(BoardElement e, String name) {
  final xMin = e.xMin ?? -10, xMax = e.xMax ?? 10;
  final expressions = [for (final s in e.plotSeries) s.expression];
  if (expressions.isEmpty) return const [];
  // Use the shared multi-curve sampling so markers land on the same
  // y-scale the painter uses when several functions share the plot.
  final sampled = samplePlotSeries(expressions, xMin, xMax, e.yMin, e.yMax);
  final rect0 = e.rect;
  Offset toBoard0(Offset d) => Offset(
    rect0.left + (d.dx - xMin) / (xMax - xMin) * rect0.width,
    rect0.bottom -
        (d.dy - sampled.yMin) / (sampled.yMax - sampled.yMin) * rect0.height,
  );
  if (name == 'intersection' ||
      name == 'intersections' ||
      name == 'crossing' ||
      name == 'crossings') {
    if (expressions.length < 2) return const [];
    return [
      for (final pt in plotIntersections(expressions, xMin, xMax)) toBoard0(pt),
    ];
  }
  final pts = (sampled.curves.isEmpty ? const <Offset>[] : sampled.curves.first)
      .where((p) => !p.dx.isNaN && !p.dy.isNaN)
      .toList();
  if (pts.isEmpty) return const [];
  final rect = e.rect;
  Offset toBoard(Offset d) => Offset(
    rect.left + (d.dx - xMin) / (xMax - xMin) * rect.width,
    rect.bottom -
        (d.dy - sampled.yMin) / (sampled.yMax - sampled.yMin) * rect.height,
  );
  switch (name) {
    case 'center':
      return [rect.center];
    case 'y_intercept':
      if (xMin > 0 || xMax < 0) return const [];
      for (var i = 1; i < pts.length; i++) {
        if (pts[i - 1].dx <= 0 && pts[i].dx >= 0) {
          final t = (0 - pts[i - 1].dx) / (pts[i].dx - pts[i - 1].dx);
          final y = pts[i - 1].dy + t * (pts[i].dy - pts[i - 1].dy);
          return [toBoard(Offset(0, y))];
        }
      }
      return const [];
    case 'root':
    case 'roots':
    case 'x_intercept':
    case 'x_intercepts':
      final out = <Offset>[];
      for (var i = 1; i < pts.length; i++) {
        final a = pts[i - 1], b = pts[i];
        // Include zero endpoints: the sample grid can land exactly on a
        // root, where strict sign-change tests would miss the crossing.
        if ((a.dy < 0 && b.dy >= 0) || (a.dy > 0 && b.dy <= 0)) {
          final t = a.dy / (a.dy - b.dy);
          final root = toBoard(Offset(a.dx + t * (b.dx - a.dx), 0));
          if (out.isEmpty || (out.last.dx - root.dx).abs() > 1) out.add(root);
        }
      }
      return out;
    case 'maximum':
      return [toBoard(pts.reduce((a, b) => a.dy > b.dy ? a : b))];
    case 'minimum':
      return [toBoard(pts.reduce((a, b) => a.dy < b.dy ? a : b))];
    case 'vertex':
    case 'turning_point':
      // Local extrema (slope sign changes) in the interior.
      final extrema = <Offset>[];
      for (var i = 1; i < pts.length - 1; i++) {
        final prev = pts[i - 1].dy, cur = pts[i].dy, next = pts[i + 1].dy;
        if ((cur > prev && cur >= next) || (cur < prev && cur <= next)) {
          extrema.add(pts[i]);
        }
      }
      if (extrema.isEmpty) {
        final lo = pts.reduce((a, b) => a.dy < b.dy ? a : b);
        final hi = pts.reduce((a, b) => a.dy > b.dy ? a : b);
        final midY = (pts.first.dy + pts.last.dy) / 2;
        final best = (lo.dy - midY).abs() > (hi.dy - midY).abs() ? lo : hi;
        return [toBoard(best)];
      }
      final midY = (pts.first.dy + pts.last.dy) / 2;
      extrema.sort(
        (a, b) => (b.dy - midY).abs().compareTo((a.dy - midY).abs()),
      );
      return [toBoard(extrema.first)];
    default:
      return const [];
  }
}

class _SvgGeometry {
  _SvgGeometry(this.polygons, this.circles, this.toBoard);
  final List<List<Offset>> polygons;
  final List<Offset> circles;
  final Offset Function(Offset local) toBoard;

  List<Offset> get allPolygonPoints => [for (final p in polygons) ...p];

  Offset get centroidOrCenter {
    final pts = allPolygonPoints;
    if (pts.isNotEmpty) {
      var x = 0.0, y = 0.0;
      for (final p in pts) {
        x += p.dx;
        y += p.dy;
      }
      return toBoard(Offset(x / pts.length, y / pts.length));
    }
    if (circles.isNotEmpty) return toBoard(circles.first);
    return Offset.zero;
  }
}

_SvgGeometry? _svgGeometry(BoardElement e) {
  final svg = e.svg;
  if (svg == null || svg.isEmpty) return null;
  // Source coordinate space: viewBox, else <svg width/height>, else the
  // element rect (SVG authored at board-element pixel size).
  var minX = 0.0, minY = 0.0, srcW = e.width, srcH = e.height;
  final vb = RegExp(r'viewBox\s*=\s*"([^"]+)"').firstMatch(svg);
  if (vb != null) {
    final nums = vb
        .group(1)!
        .split(RegExp(r'[\s,]+'))
        .map(double.tryParse)
        .whereType<double>()
        .toList();
    if (nums.length == 4 && nums[2] > 0 && nums[3] > 0) {
      minX = nums[0];
      minY = nums[1];
      srcW = nums[2];
      srcH = nums[3];
    }
  } else {
    final wm = RegExp(r'<svg[^>]*\swidth\s*=\s*"([\d.]+)"').firstMatch(svg);
    final hm = RegExp(r'<svg[^>]*\sheight\s*=\s*"([\d.]+)"').firstMatch(svg);
    if (wm != null) srcW = double.tryParse(wm.group(1)!) ?? srcW;
    if (hm != null) srcH = double.tryParse(hm.group(1)!) ?? srcH;
  }
  final rect = e.rect;
  Offset toBoard(Offset local) => Offset(
    rect.left + (local.dx - minX) / srcW * rect.width,
    rect.top + (local.dy - minY) / srcH * rect.height,
  );

  final polygons = <List<Offset>>[];
  for (final m in RegExp(
    r'<(?:polygon|polyline)[^>]*\spoints\s*=\s*"([^"]+)"',
  ).allMatches(svg)) {
    final nums = m
        .group(1)!
        .split(RegExp(r'[\s,]+'))
        .map(double.tryParse)
        .whereType<double>()
        .toList();
    final pts = <Offset>[];
    for (var i = 0; i + 1 < nums.length; i += 2) {
      pts.add(Offset(nums[i], nums[i + 1]));
    }
    if (pts.length >= 2) polygons.add(pts);
  }
  for (final m in RegExp(r'<line[^>]*>').allMatches(svg)) {
    double attr(String n) =>
        double.tryParse(
          RegExp('$n\\s*=\\s*"([\\d.-]+)"').firstMatch(m.group(0)!)?.group(1) ??
              '',
        ) ??
        0;
    polygons.add([
      Offset(attr('x1'), attr('y1')),
      Offset(attr('x2'), attr('y2')),
    ]);
  }
  final circles = <Offset>[];
  for (final m in RegExp(r'<circle[^>]*>').allMatches(svg)) {
    double attr(String n) =>
        double.tryParse(
          RegExp('$n\\s*=\\s*"([\\d.-]+)"').firstMatch(m.group(0)!)?.group(1) ??
              '',
        ) ??
        0;
    circles.add(Offset(attr('cx'), attr('cy')));
  }
  for (final m in RegExp(r'<rect[^>]*>').allMatches(svg)) {
    double attr(String n) =>
        double.tryParse(
          RegExp('$n\\s*=\\s*"([\\d.-]+)"').firstMatch(m.group(0)!)?.group(1) ??
              '',
        ) ??
        0;
    final x = attr('x'), y = attr('y'), w = attr('width'), h = attr('height');
    if (w > 0 && h > 0) {
      polygons.add([
        Offset(x, y),
        Offset(x + w, y),
        Offset(x + w, y + h),
        Offset(x, y + h),
      ]);
    }
  }
  if (polygons.isEmpty && circles.isEmpty) return null;
  return _SvgGeometry(polygons, circles, toBoard);
}

List<Offset> _svgLandmark(BoardElement e, String name) {
  final g = _svgGeometry(e);
  if (g == null) return const [];
  final polys = g.polygons;
  final tri = polys.length == 1 && polys.first.length == 3
      ? polys.first
      : (polys.any((p) => p.length == 3)
            ? polys.firstWhere((p) => p.length == 3)
            : null);
  switch (name) {
    case 'vertex':
    case 'vertices':
    case 'corners':
      return [for (final p in g.allPolygonPoints) g.toBoard(p)];
    case 'centroid':
      final pts = g.allPolygonPoints;
      if (pts.isEmpty) return const [];
      var x = 0.0, y = 0.0;
      for (final p in pts) {
        x += p.dx;
        y += p.dy;
      }
      return [g.toBoard(Offset(x / pts.length, y / pts.length))];
    case 'midpoint':
    case 'midpoints':
    case 'edge_midpoints':
      final out = <Offset>[];
      for (final poly in polys) {
        for (var i = 0; i < poly.length; i++) {
          final a = poly[i], b = poly[(i + 1) % poly.length];
          if (poly.length == 2 && i == 1) break;
          out.add(g.toBoard(Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2)));
        }
      }
      return out;
    case 'circumcenter':
      if (g.circles.isNotEmpty && tri == null) {
        return [g.toBoard(g.circles.first)];
      }
      if (tri == null) return const [];
      final c = _circumcenter(tri[0], tri[1], tri[2]);
      return c == null ? const [] : [g.toBoard(c)];
    case 'incenter':
      if (tri == null) return const [];
      final a = tri[0], b = tri[1], cPt = tri[2];
      final la = (b - cPt).distance;
      final lb = (a - cPt).distance;
      final lc = (a - b).distance;
      final p = la + lb + lc;
      if (p == 0) return const [];
      return [
        g.toBoard(
          Offset(
            (la * a.dx + lb * b.dx + lc * cPt.dx) / p,
            (la * a.dy + lb * b.dy + lc * cPt.dy) / p,
          ),
        ),
      ];
    case 'orthocenter':
      if (tri == null) return const [];
      final cc = _circumcenter(tri[0], tri[1], tri[2]);
      if (cc == null) return const [];
      // Euler: orthocenter = A + B + C - 2*circumcenter (position vectors).
      return [
        g.toBoard(
          Offset(
            tri[0].dx + tri[1].dx + tri[2].dx - 2 * cc.dx,
            tri[0].dy + tri[1].dy + tri[2].dy - 2 * cc.dy,
          ),
        ),
      ];
    default:
      return const [];
  }
}

Offset? _circumcenter(Offset a, Offset b, Offset c) {
  final d =
      2 * (a.dx * (b.dy - c.dy) + b.dx * (c.dy - a.dy) + c.dx * (a.dy - b.dy));
  if (d.abs() < 1e-9) return null;
  final a2 = a.dx * a.dx + a.dy * a.dy;
  final b2 = b.dx * b.dx + b.dy * b.dy;
  final c2 = c.dx * c.dx + c.dy * c.dy;
  return Offset(
    (a2 * (b.dy - c.dy) + b2 * (c.dy - a.dy) + c2 * (a.dy - b.dy)) / d,
    (a2 * (c.dx - b.dx) + b2 * (a.dx - c.dx) + c2 * (b.dx - a.dx)) / d,
  );
}

/// Keeps landmark element ids readable and unique per target + name.
String landmarkElementId(String targetId, String rawName) {
  final name = rawName.trim().toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]+'),
    '_',
  );
  return '${targetId}_$name';
}

/// Display label for a landmark name, e.g. `y_intercept` -> `y-intercept`.
String landmarkLabel(String rawName) =>
    rawName.trim().toLowerCase().replaceAll('_', '-');
