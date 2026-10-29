import 'package:flutter_test/flutter_test.dart';
import 'package:texa/features/study_session/board/board_models.dart';
import 'package:texa/features/study_session/board/landmarks.dart';

BoardElement plot(String expr) => BoardElement(
  id: 'curve',
  kind: BoardElementKind.plot,
  owner: BoardOwner.ai,
  x: 100,
  y: 100,
  width: 400,
  height: 400,
  expression: expr,
  xMin: -5,
  xMax: 5,
);

void main() {
  test('plot vertex of x^2 is computed at the axis value, centred in x', () {
    final v = computeLandmarks(plot('x^2'), 'vertex');
    expect(v.length, 1);
    // x=0 maps to the horizontal centre of the 100..500 rect.
    expect(v.first.dx, closeTo(300, 2));
    // y=0 is above the curve minimum's data value on screen (smaller dy).
    expect(v.first.dy, greaterThan(100));
    expect(v.first.dy, lessThan(500));
  });

  test('roots and y-intercept of x^2 - 4', () {
    final roots = computeLandmarks(plot('x^2-4'), 'roots');
    expect(roots.length, 2);
    // x=-2 -> 100 + (3/10)*400 = 220; x=2 -> 380.
    expect(roots[0].dx, closeTo(220, 4));
    expect(roots[1].dx, closeTo(380, 4));
    final yInt = computeLandmarks(plot('x^2-4'), 'y_intercept');
    expect(yInt.length, 1);
    expect(yInt.first.dx, closeTo(300, 2));
  });

  test('triangle circumcenter, centroid and vertices from SVG geometry', () {
    final tri = BoardElement(
      id: 'tri',
      kind: BoardElementKind.svg,
      owner: BoardOwner.ai,
      x: 0,
      y: 0,
      width: 200,
      height: 200,
      svg: '<svg viewBox="0 0 100 100"><polygon points="0,100 100,100 50,0"/></svg>',
    );
    // Board points: (0,200), (200,200), (100,0) -> circumcenter (100,125).
    final cc = computeLandmarks(tri, 'circumcenter');
    expect(cc.length, 1);
    expect(cc.first.dx, closeTo(100, 0.01));
    expect(cc.first.dy, closeTo(125, 0.01));
    final centroid = computeLandmarks(tri, 'centroid');
    expect(centroid.first.dx, closeTo(100, 0.01));
    expect(centroid.first.dy, closeTo(400 / 3, 0.01));
    expect(computeLandmarks(tri, 'vertices').length, 3);
    expect(
      computeLandmarks(tri, 'circumcenter').first,
      isNot(computeLandmarks(tri, 'centroid').first),
    );
  });

  test('unknown landmark gives nothing', () {
    expect(computeLandmarks(plot('x^2'), 'circumcenter'), isEmpty);
  });
}
