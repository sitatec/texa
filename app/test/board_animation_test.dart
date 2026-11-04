import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:texa/features/study_session/ai/ai_actions.dart';
import 'package:texa/features/study_session/board/board_models.dart';
import 'package:texa/features/study_session/board/board_widget.dart';
import 'package:texa/features/study_session/board_controller.dart';

void main() {
  group('entrance animation targets', () {
    Future<BoardController> boardWithPlot() async {
      final board = BoardController();
      final item = ActionItem('plot_function', {
        'element_id': 'p1',
        'x': 100.0,
        'y': 100.0,
        'width': 400.0,
        'height': 300.0,
        'expressions': [
          {'expression': 'x^2'},
        ],
      });
      await board.applyAction(
        item,
        animate: () =>
            board.animateEntering(duration: const Duration(milliseconds: 60)),
      );
      return board;
    }

    test('marking a landmark does not restart the plot entrance', () async {
      final board = await boardWithPlot();
      final plot = board.elements.firstWhere((e) => e.id == 'p1');
      expect(plot.progress, 1);

      final mark = ActionItem('mark_landmarks', {
        'element_id': 'p1',
        'landmarks': ['vertex'],
      });
      await board.applyAction(
        mark,
        animate: () =>
            board.animateEntering(duration: const Duration(milliseconds: 60)),
      );

      // The plot was only the landmark's target: its curves must stay
      // fully drawn. The landmark itself completed its entrance.
      expect(plot.progress, 1);
      final landmark = board.elements.firstWhere(
        (e) => e.kind == BoardElementKind.landmark,
      );
      expect(landmark.progress, 1);
    });

    test('editing a plot re-animates it and ends fully drawn', () async {
      final board = await boardWithPlot();
      final edit = ActionItem('edit_element', {
        'element_id': 'p1',
        'expressions': [
          {'expression': 'x^2+1'},
        ],
      });
      await board.applyAction(
        edit,
        animate: () =>
            board.animateEntering(duration: const Duration(milliseconds: 60)),
      );
      final plot = board.elements.firstWhere((e) => e.id == 'p1');
      expect(plot.progress, 1);
      expect(plot.plotSeries.single.expression, 'x^2+1');
    });
  });

  testWidgets('a progress-only change repaints the board canvas', (
    tester,
  ) async {
    final board = BoardController();
    board.elements.add(
      BoardElement(
        id: 'p1',
        kind: BoardElementKind.plot,
        owner: BoardOwner.ai,
        x: 100,
        y: 100,
        width: 400,
        height: 300,
        expression: 'x^2',
        series: const [PlotSeries(expression: 'x^2')],
        xMin: -5,
        xMax: 5,
        progress: 1,
      ),
    );
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: FittedBox(
              child: BoardView(
                controller: board,
                tool: BoardTool.pan,
                penColor: Colors.black,
                penWidth: 3,
                onStrokeStart: () {},
                onStrokeUpdate: (_) {},
                onStrokeEnd: () {},
                onErase: (_) {},
                captureKey: key,
              ),
            ),
          ),
        ),
      ),
    );

    Future<int> curvePixels() async {
      await tester.pump();
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 0.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      var count = 0;
      for (var i = 0; i < data!.lengthInBytes; i += 4) {
        // The curve colour (#1F2937) is near-black; axes/ticks are grey.
        if (data.getUint8(i) < 60 &&
            data.getUint8(i + 1) < 70 &&
            data.getUint8(i + 2) < 90) {
          count++;
        }
      }
      return count;
    }

    await tester.runAsync(() async {
      final drawn = await curvePixels();
      expect(drawn, greaterThan(100));

      // No structural change, no revision bump: only progress moved.
      // The canvas must still follow it in both directions, or a plot
      // painted mid-entrance can stay erased after it completes.
      board.elements.first.progress = 0;
      board.notifyListenersPublic();
      expect(await curvePixels(), lessThan(drawn ~/ 2));

      board.elements.first.progress = 1;
      board.notifyListenersPublic();
      expect(await curvePixels(), drawn);
    });
  });
}
