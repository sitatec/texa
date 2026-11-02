import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:texa/features/study_session/board/board_models.dart';
import 'package:texa/features/study_session/board/board_widget.dart';
import 'package:texa/features/study_session/board_controller.dart';

BoardElement _stroke(String id, List<Offset> points) => BoardElement(
  id: id,
  kind: BoardElementKind.stroke,
  owner: BoardOwner.student,
  color: const Color(0xFF000000),
  strokeWidth: 24,
  points: points,
);

Future<int> _darkPixels(GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 0.25);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final bytes = data!.buffer.asUint8List();
  var dark = 0;
  for (var i = 0; i < bytes.length; i += 4) {
    if (bytes[i] < 120 && bytes[i + 1] < 120 && bytes[i + 2] < 120) dark++;
  }
  return dark;
}

void main() {
  testWidgets('ink is visible while drawing, before the finger lifts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1700, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = BoardController();
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BoardView(
            controller: controller,
            tool: BoardTool.pen,
            penColor: const Color(0xFF000000),
            penWidth: 24,
            captureKey: key,
            onStrokeStart: () {},
            onStrokeUpdate: (_) {},
            onStrokeEnd: () {},
            onErase: (_) {},
          ),
        ),
      ),
    );
    controller.addStroke(_stroke('s1', [const Offset(100, 100)]));
    controller.updateLastStroke(const Offset(300, 100));
    controller.updateLastStroke(const Offset(500, 100));
    await tester.pump();
    expect(await tester.runAsync(() => _darkPixels(key)), greaterThan(0));
  });

  testWidgets('ink appears on the first pixels of a drag, before lift', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1700, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = BoardController();
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BoardView(
            controller: controller,
            tool: BoardTool.pen,
            penColor: const Color(0xFF000000),
            penWidth: 24,
            captureKey: key,
            onStrokeStart: () {},
            onStrokeUpdate: (p) {
              if (controller.activeStroke == null) {
                controller.addStroke(_stroke('live', [p]));
              } else {
                controller.updateLastStroke(p);
              }
            },
            onStrokeEnd: controller.finishStroke,
            onErase: (_) {},
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(const Offset(200, 200));
    // A tiny movement — far below a pan gesture's touch slop.
    await gesture.moveBy(const Offset(6, 0));
    await tester.pump();
    expect(controller.activeStroke, isNotNull);
    expect(await tester.runAsync(() => _darkPixels(key)), greaterThan(0));
    await gesture.up();
    await tester.pump();
  });

  testWidgets('pan tool drags draw nothing and report no pointer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1700, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = BoardController();
    var strokeStarts = 0;
    var drawPointerDowns = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BoardView(
            controller: controller,
            tool: BoardTool.pan,
            penColor: const Color(0xFF000000),
            penWidth: 24,
            onStrokeStart: () => strokeStarts++,
            onStrokeUpdate: (_) {},
            onStrokeEnd: () {},
            onErase: (_) {},
            onDrawPointerDown: () => drawPointerDowns++,
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(const Offset(200, 200));
    await gesture.moveBy(const Offset(120, 60));
    await gesture.up();
    await tester.pump();
    // No stroke was started or reported: in the session screen the
    // missing onDrawPointerDown is what leaves the surrounding
    // InteractiveViewer enabled, so this drag pans the board instead.
    expect(strokeStarts, 0);
    expect(drawPointerDowns, 0);
    expect(controller.activeStroke, isNull);
    expect(controller.elements, isEmpty);
  });

  testWidgets('pan tool drag actually pans an InteractiveViewer host', (
    tester,
  ) async {
    // Smaller than the 1600x1200 board on both axes, like a real
    // session viewport, so the viewer has somewhere to pan to.
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = BoardController();
    final transform = TransformationController();
    addTearDown(transform.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveViewer(
            transformationController: transform,
            constrained: false,
            child: BoardView(
              controller: controller,
              tool: BoardTool.pan,
              penColor: const Color(0xFF000000),
              penWidth: 24,
              onStrokeStart: () {},
              onStrokeUpdate: (_) {},
              onStrokeEnd: () {},
              onErase: (_) {},
            ),
          ),
        ),
      ),
    );
    final before = transform.value.getTranslation();
    final gesture = await tester.startGesture(const Offset(300, 300));
    await gesture.moveBy(const Offset(-30, -10));
    await gesture.moveBy(const Offset(-90, -40));
    await gesture.up();
    await tester.pump();
    final after = transform.value.getTranslation();
    expect(after.x, isNot(closeTo(before.x, 0.01)));
    expect(after.y, isNot(closeTo(before.y, 0.01)));
  });

  test('eraser splits a stroke instead of bridging or deleting it', () {
    final c = BoardController();
    c.elements = [
      _stroke('line', [for (var i = 0; i <= 10; i++) Offset(i * 20.0, 0)]),
    ];
    // Erase the middle: two separate runs remain, with a circular gap —
    // nothing survives inside the eraser, and the runs end at its edge.
    c.eraseAt(const Offset(100, 0), 15);
    expect(c.elements.length, 2);
    expect(c.elements.every((e) => e.kind == BoardElementKind.stroke), isTrue);
    final pts = c.elements.expand((e) => e.points).toList();
    expect(pts.any((pt) => (pt - const Offset(100, 0)).distance < 14), isFalse);
    expect(c.elements[0].points.last.dx, lessThan(100));
    expect(c.elements[1].points.first.dx, greaterThan(100));
    // Erase at the edge: the rest of the line survives, shortened.
    final before = c.elements.length;
    c.eraseAt(const Offset(0, 0), 15);
    expect(c.elements.length, before);
    expect(
      c.elements
          .expand((e) => e.points)
          .map((p) => p.dx)
          .reduce((a, b) => a < b ? a : b),
      greaterThan(0),
    );
  });

  test('eraser cuts a two-point straight line in the middle and at edge', () {
    final c = BoardController();
    c.elements = [
      _stroke('ln', [const Offset(0, 0), const Offset(200, 0)]),
    ];
    c.eraseAt(const Offset(100, 0), 15);
    expect(c.elements.length, 2);
    final pts = c.elements.expand((e) => e.points).toList();
    expect(pts.any((pt) => (pt - const Offset(100, 0)).distance < 14), isFalse);
    // Erasing the surviving left end shortens it instead of deleting it.
    c.eraseAt(const Offset(0, 0), 15);
    final left = c.elements
        .expand((e) => e.points)
        .map((p) => p.dx)
        .reduce((a, b) => a < b ? a : b);
    expect(left, greaterThan(0));
  });

  test('line tool keeps a two-point straight preview', () {
    final c = BoardController();
    c.addLine(_stroke('ln', [const Offset(10, 10)]));
    c.updateLineEnd(const Offset(200, 90));
    expect(c.activeStroke!.points, [
      const Offset(10, 10),
      const Offset(200, 90),
    ]);
    c.finishStroke();
    expect(c.elements.single.points.length, 2);
  });
}
