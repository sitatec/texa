import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/constants.dart';

enum BoardElementKind { stroke, text, math, svg, plot }

enum BoardOwner { student, ai }

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
  double? xMin, xMax, yMin, yMax;
  Color color;
  List<Offset> points;
  Rect get rect => Rect.fromLTWH(x, y, width, height);
  BoardElement copyWith({
    double? x,
    double? y,
    double? width,
    double? height,
    String? text,
    String? latex,
    String? svg,
    String? expression,
    double? progress,
  }) => BoardElement(
    id: id,
    kind: kind,
    owner: owner,
    x: x ?? this.x,
    y: y ?? this.y,
    width: width ?? this.width,
    height: height ?? this.height,
    text: text ?? this.text,
    latex: latex ?? this.latex,
    svg: svg ?? this.svg,
    expression: expression ?? this.expression,
    xMin: xMin,
    xMax: xMax,
    yMin: yMin,
    yMax: yMax,
    color: color,
    size: size,
    strokeWidth: strokeWidth,
    points: points,
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
  });
  final List<BoardElement> elements;
  final List<double> viewport;
  final Map<String, AiElementInfo> registry;
  String encode() => jsonEncode({
    'elements': elements.map((e) => e.toJson()).toList(),
    'viewport': viewport,
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
