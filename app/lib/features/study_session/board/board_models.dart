import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/constants.dart';

enum BoardElementKind { stroke, text, math, svg, plot, landmark }

enum BoardOwner { student, ai }

/// Default curve colours, in assignment order, for plot series that do
/// not specify their own colour. Shared by argument parsing and painting
/// so a series keeps the same colour everywhere it is rendered.
const plotSeriesPalette = <Color>[
  Color(0xFF1F2937),
  Color(0xFF3B82F6),
  Color(0xFFE11D48),
  Color(0xFF10B981),
  Color(0xFF8B5CF6),
  Color(0xFFF97316),
];

/// One function of x drawn on a plot element. A plot may hold several
/// series so functions can be compared (and intersect) on shared axes.
class PlotSeries {
  const PlotSeries({required this.expression, this.color, this.label});

  final String expression;
  final Color? color;
  final String? label;

  String get displayLabel =>
      (label != null && label!.trim().isNotEmpty) ? label!.trim() : expression;

  Map<String, Object?> toJson() => {
    'expr': expression,
    'color': color?.toARGB32(),
    'label': label,
  };

  factory PlotSeries.fromJson(Map<String, dynamic> j) => PlotSeries(
    expression: (j['expr'] as String? ?? j['expression'] as String? ?? '')
        .trim(),
    color: j['color'] is int ? Color(j['color'] as int) : null,
    label: j['label'] as String?,
  );
}

/// Parses the functions of a `plot_function` call into plot series.
///
/// Accepts the multi-function form, `expressions`: a list of strings
/// (`["x^2", "2*x+1"]`) or objects (`{"expression": "x^2", "color":
/// "blue", "label": "f"}`), and the legacy single-function form,
/// `expression` plus an optional `color`. Series without a colour get
/// distinct palette colours so overlapping curves stay distinguishable.
List<PlotSeries> plotSeriesFromArgs(
  Map<String, dynamic> args, {
  Color fallback = const Color(0xFF1F2937),
}) {
  final out = <PlotSeries>[];
  void add(String? expression, String? colorName, Color? color, String? label) {
    final expr = expression?.trim() ?? '';
    if (expr.isEmpty) return;
    out.add(
      PlotSeries(
        expression: expr,
        color:
            color ??
            (colorName != null
                ? colorFromName(
                    colorName,
                    plotSeriesPalette[out.length % plotSeriesPalette.length],
                  )
                // colorFromName returns its fallback for unknown names, so
                // an unrecognised name still yields the palette colour.
                : plotSeriesPalette[out.length % plotSeriesPalette.length]),
        label: label,
      ),
    );
  }

  final raw = args['expressions'];
  if (raw is List) {
    for (final item in raw) {
      if (item is String) {
        add(item, null, null, null);
      } else if (item is Map) {
        final m = item.cast<String, dynamic>();
        add(
          (m['expression'] ?? m['expr']) as String?,
          m['color'] as String?,
          null,
          m['label'] as String?,
        );
      }
    }
  }
  if (out.isEmpty) {
    final single = args['expression'] as String?;
    if (single != null && single.trim().isNotEmpty) {
      return [
        PlotSeries(
          expression: single.trim(),
          color: colorFromName(args['color'] as String?, fallback),
          label: args['label'] as String?,
        ),
      ];
    }
  }
  return out;
}

/// One unified board element: student ink and AI content share this model.
class BoardElement {
  BoardElement({
    required this.id,
    required this.kind,
    required this.owner,
    this.x = 0,
    this.y = 0,
    this.width = 200,
    this.height = 80,
    this.text,
    this.latex,
    this.svg,
    this.expression,
    this.series = const [],
    this.xMin,
    this.xMax,
    this.yMin,
    this.yMax,
    this.color = const Color(0xFF1F2937),
    this.size = 36,
    this.strokeWidth = 4,
    this.points = const [],
    this.progress = 1,
  });
  final String id;
  final BoardElementKind kind;
  final BoardOwner owner;
  double x, y, width, height, size, strokeWidth, progress;
  String? text, latex, svg, expression;
  List<PlotSeries> series;
  double? xMin, xMax, yMin, yMax;
  Color color;
  List<Offset> points;
  Rect get rect => Rect.fromLTWH(x, y, width, height);

  /// Every function drawn on this plot: [series] when the element was
  /// created with multiple functions, otherwise the single legacy
  /// [expression]/[color] pair as a one-item list.
  List<PlotSeries> get plotSeries => series.isNotEmpty
      ? series
      : [
          if ((expression ?? '').trim().isNotEmpty)
            PlotSeries(expression: expression!.trim(), color: color),
        ];
  BoardElement copyWith({
    String? id,
    List<Offset>? points,
    double? x,
    double? y,
    double? width,
    double? height,
    String? text,
    String? latex,
    String? svg,
    String? expression,
    List<PlotSeries>? series,
    double? progress,
  }) => BoardElement(
    id: id ?? this.id,
    kind: kind,
    owner: owner,
    x: x ?? this.x,
    y: y ?? this.y,
    width: width ?? this.width,
    height: height ?? this.height,
    text: text ?? this.text,
    latex: latex ?? this.latex,
    svg: svg ?? this.svg,
    expression:
        expression ??
        (series != null && series.isNotEmpty
            ? series.first.expression
            : this.expression),
    series: series ?? this.series,
    xMin: xMin,
    xMax: xMax,
    yMin: yMin,
    yMax: yMax,
    color: color,
    size: size,
    strokeWidth: strokeWidth,
    points: points ?? this.points,
    progress: progress ?? this.progress,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'owner': owner.name,
    'x': x,
    'y': y,
    'w': width,
    'h': height,
    'text': text,
    'latex': latex,
    'svg': svg,
    'expr': expression,
    'series': series.map((s) => s.toJson()).toList(),
    'xMin': xMin,
    'xMax': xMax,
    'yMin': yMin,
    'yMax': yMax,
    'color': color.toARGB32(),
    'size': size,
    'sw': strokeWidth,
    'points': points.map((p) => [p.dx, p.dy]).toList(),
  };
  factory BoardElement.fromJson(Map<String, dynamic> j) => BoardElement(
    id: j['id'] as String,
    kind: BoardElementKind.values.byName(j['kind'] as String),
    owner: BoardOwner.values.byName(j['owner'] as String? ?? 'student'),
    x: (j['x'] as num? ?? 0).toDouble(),
    y: (j['y'] as num? ?? 0).toDouble(),
    width: (j['w'] as num? ?? 200).toDouble(),
    height: (j['h'] as num? ?? 80).toDouble(),
    text: j['text'] as String?,
    latex: j['latex'] as String?,
    svg: j['svg'] as String?,
    expression: j['expr'] as String?,
    series: ((j['series'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => PlotSeries.fromJson(e.cast<String, dynamic>()))
        .where((s) => s.expression.isNotEmpty)
        .toList(),
    xMin: (j['xMin'] as num?)?.toDouble(),
    xMax: (j['xMax'] as num?)?.toDouble(),
    yMin: (j['yMin'] as num?)?.toDouble(),
    yMax: (j['yMax'] as num?)?.toDouble(),
    color: Color(j['color'] as int? ?? 0xFF1F2937),
    size: (j['size'] as num? ?? 36).toDouble(),
    strokeWidth: (j['sw'] as num? ?? 4).toDouble(),
    points: ((j['points'] as List?) ?? [])
        .map((e) => Offset((e[0] as num).toDouble(), (e[1] as num).toDouble()))
        .toList(),
  );
}

/// Registry entry for an AI-created element the model may later edit/remove.
class AiElementInfo {
  const AiElementInfo({
    required this.id,
    required this.kind,
    required this.rect,
  });
  final String id;
  final String kind;
  final Rect rect;
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'x': rect.left,
    'y': rect.top,
    'w': rect.width,
    'h': rect.height,
  };
}

/// Persisted board state for one session.
class BoardSnapshot {
  const BoardSnapshot({
    required this.elements,
    required this.viewport,
    required this.registry,
    this.viewportSize = const [],
  });
  final List<BoardElement> elements;

  /// The saved camera: `[scale, translationX, translationY]`, in the
  /// coordinate space of the session viewport ([viewportSize]).
  final List<double> viewport;
  final Map<String, AiElementInfo> registry;

  /// Size of the session viewport [viewport] was captured in, as
  /// `[width, height]`. Without it the camera transform cannot be
  /// reproduced in a differently sized view, so snapshots saved
  /// before this was recorded have an empty list.
  final List<double> viewportSize;

  /// The camera transform saved with the board, ready to apply to a
  /// board-sized child positioned at the viewport's top-left - the
  /// same matrix [BoardController.restore] puts back into the
  /// session's InteractiveViewer when the session is reopened.
  Matrix4 get cameraTransform {
    final scale = viewport.isNotEmpty && viewport[0] > 0 ? viewport[0] : 1.0;
    final tx = viewport.length > 1 ? viewport[1] : 0.0;
    final ty = viewport.length > 2 ? viewport[2] : 0.0;
    return Matrix4.identity()
      ..scaleByDouble(scale, scale, 1, 1)
      ..setTranslationRaw(tx, ty, 0);
  }

  /// The size of the viewport [cameraTransform] was captured in, or
  /// null for snapshots saved before it was recorded.
  Size? get cameraViewportSize =>
      viewportSize.length >= 2 && viewportSize[0] > 0 && viewportSize[1] > 0
      ? Size(viewportSize[0], viewportSize[1])
      : null;

  String encode() => jsonEncode({
    'elements': elements.map((e) => e.toJson()).toList(),
    'viewport': viewport,
    'viewportSize': viewportSize,
    'registry': registry.values.map((e) => e.toJson()).toList(),
  });
  factory BoardSnapshot.decode(String? s) {
    if (s == null) {
      return const BoardSnapshot(
        elements: [],
        viewport: [1, 0, 0],
        registry: {},
      );
    }
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      final els = (j['elements'] as List)
          .map((e) => BoardElement.fromJson(e as Map<String, dynamic>))
          .toList();
      final reg = <String, AiElementInfo>{};
      for (final e in (j['registry'] as List? ?? [])) {
        final m = e as Map<String, dynamic>;
        reg[m['id'] as String] = AiElementInfo(
          id: m['id'] as String,
          kind: m['kind'] as String,
          rect: Rect.fromLTWH(
            (m['x'] as num).toDouble(),
            (m['y'] as num).toDouble(),
            (m['w'] as num).toDouble(),
            (m['h'] as num).toDouble(),
          ),
        );
      }
      return BoardSnapshot(
        elements: els,
        viewport: ((j['viewport'] as List?) ?? [1, 0, 0])
            .map((e) => (e as num).toDouble())
            .toList(),
        viewportSize: ((j['viewportSize'] as List?) ?? [])
            .map((e) => (e as num).toDouble())
            .toList(),
        registry: reg,
      );
    } catch (_) {
      return const BoardSnapshot(
        elements: [],
        viewport: [1, 0, 0],
        registry: {},
      );
    }
  }
  factory BoardSnapshot.empty() =>
      const BoardSnapshot(elements: [], viewport: [1, 0, 0], registry: {});
}

Rect clampToBoard(Rect r) {
  final x = r.left.clamp(0, boardWidth - 10).toDouble();
  final y = r.top.clamp(0, boardHeight - 10).toDouble();
  return Rect.fromLTWH(
    x,
    y,
    r.width.clamp(10, boardWidth - x).toDouble(),
    r.height.clamp(10, boardHeight - y).toDouble(),
  );
}
