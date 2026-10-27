import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../ai/ai_actions.dart';
import '../board/board_models.dart';

/// Owns board elements, the AI registry, undo/redo and the camera.
class BoardController extends ChangeNotifier {
  List<BoardElement> elements = [];
  final List<String> _undo = [];
  final List<String> _redo = [];
  final TransformationController transform = TransformationController();
  Size viewportSize = const Size(400, 700);
  ({Offset pos, String? label})? pointer;
  bool cameraTakenByStudent = false;
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
    elements = snap.elements.map((e) => e.copyWith(progress: 1)).toList();
    final v = snap.viewport;
    if (v.length >= 3 && v[0] > 0) {
      transform.value = Matrix4.identity()
        ..scaleByDouble(v[0], v[0], 1, 1)
        ..setTranslationRaw(v[1], v[2], 0);
    }
    notifyListeners();
  }

  BoardSnapshot snapshot(String? thumb) => BoardSnapshot(
    elements: elements,
    viewport: [
      transform.value.getMaxScaleOnAxis(),
      transform.value.getTranslation().x,
      transform.value.getTranslation().y,
    ],
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
    notifyListeners();
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(_encode());
    final s = _redo.removeLast();
    elements = (jsonDecode(s) as List)
        .map((e) => BoardElement.fromJson(e as Map<String, dynamic>))
        .toList();
    notifyListeners();
  }

  void beginStudentChange() => _pushUndo();
  void addStroke(BoardElement stroke) {
    elements.add(stroke);
    notifyListeners();
  }

  void updateLastStroke(Offset p) {
    if (elements.isEmpty) return;
    final last = elements.last;
    if (last.kind == BoardElementKind.stroke) {
      last.points = [...last.points, p];
      notifyListeners();
    }
  }

  void eraseAt(Offset p, double radius) {
    var changed = false;
    elements.removeWhere((e) {
      if (e.kind == BoardElementKind.stroke) return false;
      final hit = e.rect.inflate(radius).contains(p);
      if (hit) changed = true;
      return hit;
    });
    for (final e in elements.where((e) => e.kind == BoardElementKind.stroke)) {
      final before = e.points.length;
      e.points = e.points.where((pt) => (pt - p).distance > radius).toList();
      if (e.points.length != before) changed = true;
    }
    elements.removeWhere(
      (e) => e.kind == BoardElementKind.stroke && e.points.isEmpty,
    );
    if (changed) notifyListeners();
  }

  void clear() {
    _pushUndo();
    elements.clear();
    notifyListeners();
  }

  Rect? rectForArgs(Map<String, dynamic> a) {
    final id = a['element_id'] as String?;
    if (id != null && registry.containsKey(id)) return registry[id]!.rect;
    if (a['x'] is num && a['y'] is num) {
      return Rect.fromLTWH(
        (a['x'] as num).toDouble(),
        (a['y'] as num).toDouble(),
        (a['width'] as num? ?? 240).toDouble(),
        (a['height'] as num? ?? 160).toDouble(),
      );
    }
    return null;
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
          if (item.tool == 'plot_function' &&
              (a['expression'] as String? ?? '').isEmpty) {
            return null;
          }
          final rect = clampToBoard(
            Rect.fromLTWH(
              n('x', 60),
              n('y', 60),
              n('width', item.tool == 'write_text' ? 520 : 420),
              n('height', item.tool == 'write_text' ? 90 : 260),
            ),
          );
          final kind = switch (item.tool) {
            'write_text' => BoardElementKind.text,
            'write_math' => BoardElementKind.math,
            'draw_svg' => BoardElementKind.svg,
            _ => BoardElementKind.plot,
          };
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
            expression: a['expression'] as String?,
            xMin: (a['x_min'] as num?)?.toDouble(),
            xMax: (a['x_max'] as num?)?.toDouble(),
            yMin: (a['y_min'] as num?)?.toDouble(),
            yMax: (a['y_max'] as num?)?.toDouble(),
            color: colorFromName(
              a['color'] as String?,
              const Color(0xFF1F2937),
            ),
            size: n('size', 38),
            progress: 0,
          );
          elements.removeWhere((e) => e.id == id && e.owner == BoardOwner.ai);
          elements.add(el);
          notifyListeners();
          await animate();
          el.progress = 1;
          notifyListeners();
          return rect;
        case 'edit_element':
          final id = item.elementId;
          if (id == null) return null;
          final i = elements.indexWhere(
            (e) => e.id == id && e.owner == BoardOwner.ai,
          );
          if (i < 0) return null;
          final old = elements[i];
          elements[i] = old.copyWith(
            x: (a['x'] as num?)?.toDouble(),
            y: (a['y'] as num?)?.toDouble(),
            width: (a['width'] as num?)?.toDouble(),
            height: (a['height'] as num?)?.toDouble(),
            text: a['text'] as String?,
            latex: a['latex'] as String?,
            svg: a['svg'] as String?,
            expression: a['expression'] as String?,
            progress: 0,
          );
          notifyListeners();
          await animate();
          elements[i].progress = 1;
          notifyListeners();
          return elements[i].rect;
        case 'remove_element':
          final id = item.elementId;
          if (id == null) return null;
          final before = elements.length;
          elements.removeWhere((e) => e.id == id && e.owner == BoardOwner.ai);
          if (elements.length == before) return null;
          notifyListeners();
          return registry[id]?.rect;
        case 'point_at':
          final rect = rectForArgs(a);
          if (rect == null && a['x'] is! num) return null;
          final pos = rect?.center ?? Offset(n('x', 0), n('y', 0));
          pointer = (pos: pos, label: a['label'] as String?);
          notifyListeners();
          _pointerTimer?.cancel();
          _pointerTimer = Timer(const Duration(seconds: 4), () {
            pointer = null;
            notifyListeners();
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
    final padded = rect.inflate(rect.width * 0.1 + 24);
    final scale = (viewportSize.width / padded.width)
        .clamp(0.12, 2.5)
        .toDouble();
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
    _pointerTimer?.cancel();
    transform.dispose();
    super.dispose();
  }
}
