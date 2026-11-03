import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:texa/features/study_session/board/board_models.dart';
import 'package:texa/features/study_session/board/board_widget.dart';
import 'package:texa/features/study_session/board_controller.dart';

void main() {
  testWidgets('oversized latex shrinks its font to fit its box', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1700, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = BoardController();
    // The system from the reported screenshot, at a large font in a
    // narrow box: at size 48 it is far wider than 220 units, which used
    // to render as "RIGHT OVERFLOWED BY ... PIXELS".
    controller.elements = [
      BoardElement(
        id: 'system',
        kind: BoardElementKind.math,
        owner: BoardOwner.ai,
        x: 100,
        y: 100,
        width: 220,
        height: 260,
        latex: r'\begin{cases} x + xy + y = 3 \\ x^2y + xy^2 = -70 \end{cases}',
        size: 48,
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BoardView(
            controller: controller,
            tool: BoardTool.pen,
            penColor: const Color(0xFF000000),
            penWidth: 4,
            onStrokeStart: () {},
            onStrokeUpdate: (_) {},
            onStrokeEnd: () {},
            onErase: (_) {},
          ),
        ),
      ),
    );
    // One frame to measure the natural size, one to render fitted.
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    final fontSizes = tester
        .widgetList<Math>(find.byType(Math))
        .map((m) => m.textStyle?.fontSize)
        .whereType<double>()
        .toList();
    // The measuring copy stays at the requested size; the visible copy
    // is reduced to fit the 220-wide box.
    expect(fontSizes, contains(48));
    expect(fontSizes.where((s) => s < 48), isNotEmpty);
  });

  testWidgets('latex that already fits keeps the requested font size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1700, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = BoardController();
    controller.elements = [
      BoardElement(
        id: 'small',
        kind: BoardElementKind.math,
        owner: BoardOwner.ai,
        x: 100,
        y: 100,
        width: 420,
        height: 260,
        latex: r'x + 1',
        size: 36,
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BoardView(
            controller: controller,
            tool: BoardTool.pen,
            penColor: const Color(0xFF000000),
            penWidth: 4,
            onStrokeStart: () {},
            onStrokeUpdate: (_) {},
            onStrokeEnd: () {},
            onErase: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    final fontSizes = tester
        .widgetList<Math>(find.byType(Math))
        .map((m) => m.textStyle?.fontSize)
        .whereType<double>()
        .toList();
    expect(fontSizes, isNotEmpty);
    expect(fontSizes.every((s) => s == 36), isTrue);
  });
}
