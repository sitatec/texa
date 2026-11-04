import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:texa/features/study_session/board/board_models.dart';
import 'package:texa/features/study_session/board/landmarks.dart';
import 'package:texa/features/study_session/board/plot_preview.dart';
import 'package:texa/features/study_session/board/plotter.dart';

BoardElement multiPlot(List<PlotSeries> series) => BoardElement(
  id: 'curves',
  kind: BoardElementKind.plot,
  owner: BoardOwner.ai,
  x: 100,
  y: 100,
  width: 400,
  height: 400,
  expression: series.first.expression,
  series: series,
  xMin: -5,
  xMax: 5,
);

void main() {
  test(
    'parses expressions list (strings and objects) with distinct colours',
    () {
      final series = plotSeriesFromArgs({
        'expressions': [
          'x^2',
          {'expression': '2*x+1', 'color': 'red', 'label': 'g'},
        ],
      });
      expect(series.length, 2);
      expect(series[0].expression, 'x^2');
      expect(series[1].expression, '2*x+1');
      expect(series[1].displayLabel, 'g');
      expect(series[0].color, isNot(series[1].color));
    },
  );

  test('legacy single expression still parses as one series', () {
    final series = plotSeriesFromArgs({'expression': 'x^2', 'color': 'blue'});
    expect(series.length, 1);
    expect(series.single.expression, 'x^2');
    expect(series.single.color, const Color(0xFF3B82F6));
  });

  test('multi-function plot survives JSON round-trip', () {
    final el = multiPlot(const [
      PlotSeries(expression: 'x^2', label: 'f'),
      PlotSeries(expression: '2*x+1', color: Color(0xFFE11D48), label: 'g'),
    ]);
    final restored = BoardElement.fromJson(el.toJson());
    expect(restored.plotSeries.length, 2);
    expect(restored.plotSeries[1].expression, '2*x+1');
    expect(restored.plotSeries[1].displayLabel, 'g');
    expect(restored.expression, 'x^2');
  });

  test('series share one y-range covering every curve', () {
    final sampled = samplePlotSeries(['x^2', '1'], -2, 2, null, null);
    expect(sampled.curves.length, 2);
    // x^2 reaches 4 at the endpoints, the constant curve only 1.
    expect(sampled.yMax, greaterThan(4));
    expect(sampled.yMin, lessThan(0));
  });

  test('intersections of x and 2 are found in data space', () {
    final hits = plotIntersections(['x', '2'], -5, 5);
    expect(hits.length, 1);
    expect(hits.first.dx, closeTo(2, 0.05));
    expect(hits.first.dy, closeTo(2, 0.05));
  });

  test('marking intersections on a multi-function plot', () {
    final el = multiPlot(const [
      PlotSeries(expression: 'x'),
      PlotSeries(expression: '2'),
    ]);
    final hits = computeLandmarks(el, 'intersections');
    expect(hits.length, 1);
    // Data x=2 maps to 100 + (7/10)*400 = 380.
    expect(hits.first.dx, closeTo(380, 4));
  });

  testWidgets('multi-function PlotView paints without error', (tester) async {
    final el = multiPlot(const [
      PlotSeries(expression: 'x^2', label: 'f'),
      PlotSeries(expression: '2*x+1', label: 'g'),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 400, height: 300, child: PlotView(element: el)),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(PlotView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('history plot element rebuilds all series from saved args', () {
    final el = plotElementFromArgs({
      'element_id': 'curves',
      'expressions': [
        {'expression': 'x^2', 'label': 'f'},
        {'expression': '2*x+1', 'label': 'g'},
      ],
      'x_min': -5,
      'x_max': 5,
    });
    expect(el.plotSeries.length, 2);
    expect(el.plotSeries[1].displayLabel, 'g');
  });

  test('ticks are every 1 unit for classroom-sized ranges', () {
    expect(plotTickStep(7.5), 1);
    expect(plotTicks(-2, 5), [-2, -1, 0, 1, 2, 3, 4, 5]);
    expect(plotTicks(-2.5, 7.3), [-2, -1, 0, 1, 2, 3, 4, 5, 6, 7]);
    // Wider ranges widen the step instead of crowding the axis.
    expect(plotTickStep(100), 10);
    expect(plotTickLabel(3, 1), '3');
    expect(plotTickLabel(0.5, 0.5), '0.5');
  });
}
