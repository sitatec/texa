import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/constants.dart';
import 'ai/ai_actions.dart';
import 'board/board_models.dart';
import 'board/landmarks.dart';

/// Owns board elements, the AI registry, undo/redo and the camera.
class BoardController extends ChangeNotifier {
  List<BoardElement> elements = [];
  final List<String> _undo = [];
  final List<String> _redo = [];
  final TransformationController transform = TransformationController();
  Size viewportSize = const Size(400, 700);
  ({Offset pos, String? label})? pointer;
  bool cameraTakenByStudent = false;

  /// The stroke currently being drawn. Kept out of [elements] so the
  /// high-frequency point updates only repaint the ink layer.
  BoardElement? activeStroke;
  final ValueNotifier<int> activeStrokeTick = ValueNotifier(0);

  /// Bumped on every structural change; painters use it to skip repaints.
  int revision = 0;
  void _changed() {
    revision++;
    notifyListeners();
  }

  Timer? _pointerTimer;

  void notifyListenersPublic() => notifyListeners();
  Map<String, AiElementInfo> get registry => {
    for (final e in elements.where((e) => e.owner == BoardOwner.ai))
      e.id: AiElementInfo(id: e.id, kind: e.kind.name, rect: e.rect),
  };
  String _encode() => jsonEncode(elements.map((e) => e.toJson()).toList());
  void _pushUndo() {
    _undo.add(_encode());
    if (_undo.length > 60) _undo.removeAt(0);
    _redo.clear();
  }

  void restore(BoardSnapshot snap) {
    // Clamp content saved on the old portrait board into the landscape one.
    elements = snap.elements.map((e) {
      final c = e.copyWith(progress: 1);
      c.x = c.x.clamp(0, boardWidth - c.width);
      c.y = c.y.clamp(0, boardHeight - c.height);
      c.points = [
        for (final pt in c.points)
          Offset(pt.dx.clamp(0, boardWidth), pt.dy.clamp(0, boardHeight)),
      ];
      return c;
    }).toList();
    final v = snap.viewport;
    if (v.length >= 3 && v[0] > 0) {
      transform.value = snap.cameraTransform;
    }
    _changed();
  }

  BoardSnapshot snapshot(String? thumb) => BoardSnapshot(
    elements: [...elements, ?activeStroke],
    viewport: [
      transform.value.getMaxScaleOnAxis(),
      transform.value.getTranslation().x,
      transform.value.getTranslation().y,
    ],
    // The camera translation only means something together with the
    // size of the viewport it was captured in; the board preview
    // needs both to reproduce the framing the student left behind.
    viewportSize: [viewportSize.width, viewportSize.height],
    registry: registry,
  );
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(_encode());
    final s = _undo.removeLast();
    elements = (jsonDecode(s) as List)
        .map((e) => BoardElement.fromJson(e as Map<String, dynamic>))
        .toList();
    _changed();
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(_encode());
    final s = _redo.removeLast();
    elements = (jsonDecode(s) as List)
        .map((e) => BoardElement.fromJson(e as Map<String, dynamic>))
        .toList();
    _changed();
  }

  void beginStudentChange() => _pushUndo();

  // -- Erase undo transaction -------------------------------------------
  // One erase *drag* is one undo step, however many eraseAt points it
  // contains. beginErase snapshots the board; the snapshot is only
  // pushed onto the undo stack when the drag actually changes something
  // (so tapping the eraser on empty board costs no undo step), and only
  // once per drag. eraseAt outside a drag is a transaction of its own.
  String? _eraseSnapshot;
  bool _eraseSnapshotPushed = false;

  void beginErase() {
    _eraseSnapshot = _encode();
    _eraseSnapshotPushed = false;
  }

  void endErase() {
    _eraseSnapshot = null;
    _eraseSnapshotPushed = false;
  }

  void _recordEraseUndo() {
    if (_eraseSnapshot != null) {
      if (_eraseSnapshotPushed) return;
      _eraseSnapshotPushed = true;
      _undo.add(_eraseSnapshot!);
      if (_undo.length > 60) _undo.removeAt(0);
      _redo.clear();
    } else {
      _pushUndo();
    }
  }

  void addStroke(BoardElement stroke) {
    activeStroke = stroke;
    activeStrokeTick.value++;
  }

  void updateLastStroke(Offset p) {
    final stroke = activeStroke;
    if (stroke == null) return;
    // Skip near-duplicate points: fewer segments to paint, smoother ink.
    if (stroke.points.isNotEmpty && (stroke.points.last - p).distance < 1.5) {
      return;
    }
    stroke.points = [...stroke.points, p];
    activeStrokeTick.value++;
  }

  /// Discards the in-progress stroke (e.g. a second finger landed, so
  /// the touch is becoming a pinch, not a drawing).
  void cancelActiveStroke() {
    if (activeStroke == null) return;
    activeStroke = null;
    activeStrokeTick.value++;
  }

  /// Commits the in-progress stroke to [elements] (one structural change).
  void finishStroke() {
    final stroke = activeStroke;
    if (stroke == null) return;
    activeStroke = null;
    if (stroke.points.isNotEmpty) elements.add(stroke);
    _changed();
  }

  /// Erases whatever is under the eraser.
  ///
  /// Rich elements (AI text/math/SVG/plots and any non-stroke element) hit
  /// by the eraser are removed whole. Ink strokes are *split*: the points
  /// under the eraser are cut out and the remaining runs become separate
  /// strokes, so erasing the middle of a line leaves two lines with a gap
  /// (never a straight bridge across the gap, never a vanished line).
  void eraseAt(Offset p, double radius) {
    var changed = false;
    final result = <BoardElement>[];
    for (final e in elements) {
      if (e.kind != BoardElementKind.stroke) {
        if (e.rect.inflate(radius).contains(p)) {
          changed = true;
        } else {
          result.add(e);
        }
        continue;
      }
      // Ink has thickness: erase where the eraser disc overlaps the
      // stroke's disc, not only where it crosses the centreline.
      final runs = _cutStroke(e.points, p, radius + e.strokeWidth / 2);
      if (runs.length == 1 &&
          runs.first.length == e.points.length &&
          runs.first.every((pt) => e.points.contains(pt))) {
        result.add(e);
      } else {
        changed = true;
        for (var i = 0; i < runs.length; i++) {
          if (runs[i].length < 2) continue;
          result.add(
            e.copyWith(id: i == 0 ? e.id : '${e.id}_x$i', points: runs[i]),
          );
        }
      }
    }
    if (changed) {
      _recordEraseUndo();
      elements = result;
      _changed();
    }
  }

  /// Cuts the parts of a polyline that fall inside the eraser circle and
  /// returns the surviving runs. Works on *segments*, not just stored
  /// points, so a two-point straight line can be erased in the middle:
  /// each segment is clipped against the circle analytically and the
  /// surviving pieces end exactly on the circle boundary.
  List<List<Offset>> _cutStroke(
    List<Offset> points,
    Offset center,
    double radius,
  ) {
    if (points.isEmpty) return const [];
    if (points.length == 1) {
      return (points.first - center).distance > radius
          ? [List.of(points)]
          : const [];
    }
    final runs = <List<Offset>>[];
    var current = <Offset>[];
    void addPoint(Offset pt) {
      if (current.isEmpty || current.last != pt) current.add(pt);
    }

    void flush() {
      if (current.length >= 2) runs.add(current);
      current = [];
    }

    for (var i = 0; i < points.length - 1; i++) {
      final a = points[i];
      final b = points[i + 1];
      final d = b - a;
      final f = a - center;
      final qa = d.dx * d.dx + d.dy * d.dy;
      if (qa == 0) {
        if (f.distance <= radius) flush();
        continue;
      }
      final qb = 2 * (f.dx * d.dx + f.dy * d.dy);
      final qc = f.dx * f.dx + f.dy * f.dy - radius * radius;
      final disc = qb * qb - 4 * qa * qc;
      // Parameter intervals of this segment that lie OUTSIDE the circle.
      final outside = <(double, double)>[];
      if (disc <= 0) {
        if (qc > 0) outside.add((0, 1));
      } else {
        final root = math.sqrt(disc);
        final raw1 = (-qb - root) / (2 * qa);
        final raw2 = (-qb + root) / (2 * qa);
        if (raw2 <= 0 || raw1 >= 1) {
          // The circle crossing happens before/after this segment.
          if (qc > 0 || (b - center).distance > radius) outside.add((0, 1));
        } else {
          final t1 = raw1.clamp(0.0, 1.0);
          final t2 = raw2.clamp(0.0, 1.0);
          if (t1 > 0) outside.add((0, t1));
          if (t2 < 1) outside.add((t2, 1));
        }
      }
      if (outside.isEmpty) {
        flush();
        continue;
      }
      for (var j = 0; j < outside.length; j++) {
        final (s, e) = outside[j];
        if (j > 0) flush(); // gap inside this segment
        if (s > 0 && current.isNotEmpty && current.last != a + d * s) {
          flush();
        }
        addPoint(a + d * s);
        addPoint(a + d * e);
        if (e < 1) flush(); // segment ends inside the circle
      }
    }
    flush();
    return runs;
  }

  /// Starts the straight-line tool's live preview stroke.
  void addLine(BoardElement line) {
    activeStroke = line;
    activeStrokeTick.value++;
  }

  /// Moves the straight line's end point (start stays anchored).
  void updateLineEnd(Offset p) {
    final line = activeStroke;
    if (line == null || line.points.isEmpty) return;
    line.points = [line.points.first, p];
    activeStrokeTick.value++;
  }

  void clear() {
    _pushUndo();
    elements.clear();
    _changed();
  }

  Rect? rectForArgs(Map<String, dynamic> a) {
    // Explicit coordinates win over the registry: a create (or an edit
    // that moves an element) reusing an existing element_id is heading
    // for the NEW x/y, not the rect that id currently occupies. The
    // registry rect is the fallback for actions that only name their
    // target (mark_landmarks, focus/point at an existing element).
    if (a['x'] is num && a['y'] is num) {
      return Rect.fromLTWH(
        (a['x'] as num).toDouble(),
        (a['y'] as num).toDouble(),
        (a['width'] as num? ?? 240).toDouble(),
        (a['height'] as num? ?? 160).toDouble(),
      );
    }
    final id = a['element_id'] as String?;
    if (id != null && registry.containsKey(id)) return registry[id]!.rect;
    return null;
  }

  /// Frames [target] unless [alreadyFramed] (the rect camera-framed
  /// just before the action ran) already covers most of it. Used after
  /// an action applies: the pre-action rect is only a prediction from
  /// the raw arguments (text is re-measured, edits can move elements),
  /// so when the real rect lands largely outside it the camera must
  /// move again or the new content sits off-screen.
  Future<void> frameRectUnlessCovered(Rect target, Rect? alreadyFramed) async {
    if (alreadyFramed != null) {
      final overlap = alreadyFramed.intersect(target);
      final area = target.width * target.height;
      if (area > 0 &&
          !overlap.isEmpty &&
          overlap.width * overlap.height >= area * 0.5) {
        return;
      }
    }
    await frameRect(clampToBoard(target));
  }

  /// The one text style board text is both measured and rendered with.
  /// Keeping these in sync matters: measuring with a different font than
  /// the renderer uses under-estimates the natural width, so the widget
  /// gets a box a few pixels too narrow and wraps the last character of
  /// an otherwise single-line word ("Functions" -> "Function\ns").
  static TextStyle boardTextStyle(double fontSize, {Color? color}) => TextStyle(
    color: color,
    fontSize: fontSize,
    fontFamily: 'GoogleSansFlex',
    height: 1.15,
  );

  /// Measures plain board text the way the board renders it, wrapped at
  /// [maxWidth]. Used so a text element's rect is its *actual* rendered
  /// size instead of a fixed guessed box: short text stays on one line
  /// at its natural width, long text wraps (at most to the board edge)
  /// and grows taller. The rect matters beyond looks - it is what the
  /// registry, camera framing and the eraser all reason about - so it
  /// must describe what is really on the board.
  static Size measureBoardText(String text, double fontSize, double maxWidth) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: boardTextStyle(fontSize)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
    return painter.size;
  }

  /// [rect] as a plain bounding box, `[x1, y1, x2, y2]` in board
  /// coordinates - the format tool results report to the model. Kept
  /// deliberately terse: with many elements on the board, a simple
  /// bbox per element is the easiest spatial record for the model to
  /// scan and to keep new placements from overlapping.
  static String describeBoardRect(Rect rect) =>
      'bbox [${rect.left.round()}, ${rect.top.round()}, '
      '${rect.right.round()}, ${rect.bottom.round()}]';

  /// The layout a text element with content [text] should occupy at
  /// ([x], [y]): its measured rect plus the font size it must actually
  /// be rendered at. The rect is the natural width, wrapped at the
  /// board's right edge, with measured height. An explicit
  /// model-supplied width is honoured as the wrap width (still clamped
  /// to the board), never as the height.
  ///
  /// Fit policy (shared with math, see _FittedMath in board_widget):
  /// the element's box is never grown just to make over-sized content
  /// fit. If the wrapped text would run past the board's bottom edge,
  /// the font size is reduced until it fits inside the board instead.
  ({Rect rect, double fontSize}) textLayoutFor({
    required double x,
    required double y,
    required String text,
    required double fontSize,
    double? requestedWidth,
  }) {
    Rect measure(double fs) {
      final toEdge = (boardWidth - x).clamp(80.0, boardWidth);
      final natural = measureBoardText(text, fs, double.infinity).width;
      // Breathing room: a box exactly as wide as the measured text can
      // still wrap its last glyph when the widget re-lays it out (font
      // fallback, sub-pixel rounding), so single-line text gets a small
      // slack - a fraction of the font size, at least a few pixels. An
      // explicit width from the model is an intentional wrap width and
      // is used as-is.
      final breathingRoom = math.max(4.0, fs * 0.2);
      final width = requestedWidth == null
          ? (natural + breathingRoom).clamp(1.0, toEdge)
          : requestedWidth.clamp(1.0, toEdge);
      final height = measureBoardText(text, fs, width).height;
      return Rect.fromLTWH(x, y, width, math.max(height, fs * 1.15));
    }

    var fitted = fontSize;
    var rect = measure(fitted);
    final availableHeight = (boardHeight - y).clamp(1.0, boardHeight);
    var guard = 0;
    while (rect.height > availableHeight && fitted > 10 && guard++ < 50) {
      fitted = math.max(10.0, fitted * 0.9);
      rect = measure(fitted);
    }
    return (rect: rect, fontSize: fitted);
  }

  /// The rect a text element should occupy; see [textLayoutFor].
  Rect textRectFor({
    required double x,
    required double y,
    required String text,
    required double fontSize,
    double? requestedWidth,
  }) {
    return textLayoutFor(
      x: x,
      y: y,
      text: text,
      fontSize: fontSize,
      requestedWidth: requestedWidth,
    ).rect;
  }

  /// Applies one AI action to the board. Returns its rect, or null to skip it.
  Future<Rect?> applyAction(
    ActionItem item, {
    required Future<void> Function() animate,
  }) async {
    final a = item.args;
    double n(String k, double d) => (a[k] as num?)?.toDouble() ?? d;
    try {
      switch (item.tool) {
        case 'write_text':
        case 'write_math':
        case 'draw_svg':
        case 'plot_function':
          final id = item.elementId;
          if (id == null || id.isEmpty) return null;
          if (item.tool == 'draw_svg' &&
              !(a['svg'] as String? ?? '').contains('<svg')) {
            return null;
          }
          if (item.tool == 'write_math' &&
              (a['latex'] as String? ?? '').isEmpty) {
            return null;
          }
          if (item.tool == 'plot_function' && plotSeriesFromArgs(a).isEmpty) {
            return null;
          }
          // Text is free-sized: its rect is measured from the actual
          // content (see textLayoutFor), not a fixed 520x90 box that
          // long text silently overflowed, and if it still cannot fit
          // the board its font is shrunk rather than its box grown.
          // Other kinds keep explicit boxes - a plot/SVG genuinely is
          // the rectangle the model asked for, and a math formula
          // cannot wrap, so its box stays as asked and the renderer
          // shrinks the formula's font to fit inside it (see
          // _FittedMath in board_widget).
          var effectiveSize = n('size', 30);
          final Rect rect;
          if (item.tool == 'write_text') {
            final layout = textLayoutFor(
              x: n('x', 60),
              y: n('y', 60),
              text: a['text'] as String? ?? '',
              fontSize: effectiveSize,
              requestedWidth: (a['width'] as num?)?.toDouble(),
            );
            rect = layout.rect;
            effectiveSize = layout.fontSize;
          } else {
            rect = clampToBoard(
              Rect.fromLTWH(
                n('x', 60),
                n('y', 60),
                n('width', 420),
                n('height', 260),
              ),
            );
          }
          final kind = switch (item.tool) {
            'write_text' => BoardElementKind.text,
            'write_math' => BoardElementKind.math,
            'draw_svg' => BoardElementKind.svg,
            _ => BoardElementKind.plot,
          };
          final plotSeries = item.tool == 'plot_function'
              ? plotSeriesFromArgs(a)
              : const <PlotSeries>[];
          final el = BoardElement(
            id: id,
            kind: kind,
            owner: BoardOwner.ai,
            x: rect.left,
            y: rect.top,
            width: rect.width,
            height: rect.height,
            text: a['text'] as String?,
            latex: a['latex'] as String?,
            svg: a['svg'] as String?,
            expression: plotSeries.isNotEmpty
                ? plotSeries.first.expression
                : a['expression'] as String?,
            series: plotSeries,
            xMin: (a['x_min'] as num?)?.toDouble(),
            xMax: (a['x_max'] as num?)?.toDouble(),
            yMin: (a['y_min'] as num?)?.toDouble(),
            yMax: (a['y_max'] as num?)?.toDouble(),
            color: plotSeries.isNotEmpty && plotSeries.first.color != null
                ? plotSeries.first.color!
                : colorFromName(a['color'] as String?, const Color(0xFF1F2937)),
            size: effectiveSize,
            progress: 0,
          );
          elements.removeWhere((e) => e.id == id && e.owner == BoardOwner.ai);
          elements.add(el);
          _changed();
          await animate();
          el.progress = 1;
          _changed();
          return rect;
        case 'mark_landmarks':
          final targetId = item.elementId;
          if (targetId == null) return null;
          final tIdx = elements.indexWhere(
            (e) => e.id == targetId && e.owner == BoardOwner.ai,
          );
          if (tIdx < 0) return null;
          final target = elements[tIdx];
          final names = (a['landmarks'] as List? ?? [])
              .map((e) => e.toString())
              .where((e) => e.trim().isNotEmpty)
              .toList();
          Rect? union;
          for (final name in names) {
            final points = computeLandmarks(target, name);
            if (points.isEmpty) continue;
            var bounds = Rect.fromCenter(
              center: points.first,
              width: 30,
              height: 30,
            );
            for (final pt in points.skip(1)) {
              bounds = bounds.expandToInclude(
                Rect.fromCenter(center: pt, width: 30, height: 30),
              );
            }
            final el = BoardElement(
              id: landmarkElementId(targetId, name),
              kind: BoardElementKind.landmark,
              owner: BoardOwner.ai,
              x: bounds.left,
              y: bounds.top,
              width: bounds.width,
              height: bounds.height,
              text: landmarkLabel(name),
              color: colorFromName(
                a['color'] as String?,
                const Color(0xFFE11D48),
              ),
              size: 15,
              points: points,
              progress: 0,
            );
            elements.removeWhere(
              (e) => e.id == el.id && e.owner == BoardOwner.ai,
            );
            elements.add(el);
            union = union?.expandToInclude(bounds) ?? bounds;
            _changed();
            await animate();
            el.progress = 1;
            _changed();
          }
          return union;
        case 'edit_element':
          final id = item.elementId;
          if (id == null) return null;
          final i = elements.indexWhere(
            (e) => e.id == id && e.owner == BoardOwner.ai,
          );
          if (i < 0) return null;
          final old = elements[i];
          final editedSeries =
              old.kind == BoardElementKind.plot &&
                  (a.containsKey('expressions') || a.containsKey('expression'))
              ? plotSeriesFromArgs(a)
              : null;
          elements[i] = old.copyWith(
            x: (a['x'] as num?)?.toDouble(),
            y: (a['y'] as num?)?.toDouble(),
            width: (a['width'] as num?)?.toDouble(),
            height: (a['height'] as num?)?.toDouble(),
            text: a['text'] as String?,
            latex: a['latex'] as String?,
            svg: a['svg'] as String?,
            expression: a['expression'] as String?,
            series: editedSeries != null && editedSeries.isNotEmpty
                ? editedSeries
                : null,
            progress: 0,
          );
          // Edited text gets a freshly measured rect too, unless the
          // model explicitly resized it in the same edit.
          final edited = elements[i];
          if (edited.kind == BoardElementKind.text &&
              a['width'] == null &&
              a['height'] == null) {
            final layout = textLayoutFor(
              x: edited.x,
              y: edited.y,
              text: edited.text ?? '',
              fontSize: edited.size,
            );
            elements[i] = edited.copyWith(
              width: layout.rect.width,
              height: layout.rect.height,
            );
            elements[i].size = layout.fontSize;
          }
          _changed();
          await animate();
          elements[i].progress = 1;
          _changed();
          return elements[i].rect;
        case 'remove_element':
          final id = item.elementId;
          if (id == null) return null;
          final before = elements.length;
          elements.removeWhere((e) => e.id == id && e.owner == BoardOwner.ai);
          if (elements.length == before) return null;
          _changed();
          return registry[id]?.rect;
        case 'point_at':
          final rect = rectForArgs(a);
          if (rect == null && a['x'] is! num) return null;
          final pos = rect?.center ?? Offset(n('x', 0), n('y', 0));
          pointer = (pos: pos, label: a['label'] as String?);
          _changed();
          _pointerTimer?.cancel();
          _pointerTimer = Timer(const Duration(seconds: 4), () {
            pointer = null;
            _changed();
          });
          return rect ?? Rect.fromCenter(center: pos, width: 120, height: 120);
        case 'focus_viewport':
          return rectForArgs(a);
        default:
          return null;
      }
    } catch (e) {
      debugPrint('Texa skip broken action ${item.tool}: $e');
      return null;
    }
  }

  /// Smoothly frames [rect] in the viewport unless the student took the camera.
  Future<void> frameRect(Rect rect) async {
    if (cameraTakenByStudent) return;
    // Generous padding plus a breathing-room factor on the fitted
    // scale: framing used to fit only the viewport width with ~10%
    // padding (and could zoom to 2.5x), which felt far too tight -
    // the element filled the screen edge to edge. Fit both viewport
    // dimensions instead, leave ~18% + 40 units around the rect, and
    // then back the zoom off a further 15%.
    final pad = math.max(rect.width, rect.height) * 0.18 + 40;
    final padded = rect.inflate(pad);
    final fitScale = math.min(
      viewportSize.width / padded.width,
      viewportSize.height / padded.height,
    );
    final scale = (fitScale * 0.85).clamp(0.1, 2.0).toDouble();
    final target = Matrix4.identity()
      ..translateByDouble(viewportSize.width / 2, viewportSize.height / 2, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1)
      ..translateByDouble(-padded.center.dx, -padded.center.dy, 0, 1);
    final start = transform.value.clone();
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < 420) {
      final t = Curves.easeInOut.transform(
        (sw.elapsedMilliseconds / 420).clamp(0, 1),
      );
      transform.value = Matrix4Tween(
        begin: start,
        end: target,
      ).evaluate(AlwaysStoppedAnimation(t));
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    transform.value = target;
  }

  @override
  void dispose() {
    activeStrokeTick.dispose();
    _pointerTimer?.cancel();
    transform.dispose();
    super.dispose();
  }
}
