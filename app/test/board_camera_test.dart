import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:texa/features/study_session/ai/ai_actions.dart';
import 'package:texa/features/study_session/board_controller.dart';

void main() {
  BoardController controller() {
    final c = BoardController();
    c.viewportSize = const Size(800, 600);
    return c;
  }

  test(
    'rectForArgs prefers explicit new coordinates over the registry',
    () async {
      final c = controller();
      await c.applyAction(
        ActionItem('write_text', {
          'element_id': 'label',
          'x': 100.0,
          'y': 100.0,
          'text': 'Hello',
        }),
        animate: () async {},
      );
      // No coordinates: the existing element's rect is the target.
      expect(c.rectForArgs({'element_id': 'label'}), c.elements.single.rect);
      // Reusing the id at new coordinates (a fresh create / moving edit)
      // must aim the camera at the new location, not the old rect.
      final moved = c.rectForArgs({
        'element_id': 'label',
        'x': 900.0,
        'y': 700.0,
        'width': 200.0,
        'height': 100.0,
      });
      expect(moved, const Rect.fromLTWH(900, 700, 200, 100));
    },
  );

  test('rectForArgs unions multiple element_ids for focus_viewport', () async {
    final c = controller();
    for (final (id, x, y) in [('a', 100.0, 100.0), ('b', 500.0, 400.0)]) {
      await c.applyAction(
        ActionItem('write_text', {
          'element_id': id,
          'x': x,
          'y': y,
          'text': 'Hi',
        }),
        animate: () async {},
      );
    }
    final a = c.elements.firstWhere((e) => e.id == 'a').rect;
    final b = c.elements.firstWhere((e) => e.id == 'b').rect;
    final union = c.rectForArgs({
      'element_ids': ['a', 'b', 'missing'],
    });
    expect(union, a.expandToInclude(b));
    // A multi-element focus through applyAction frames that union.
    expect(
      await c.applyAction(
        ActionItem('focus_viewport', {
          'element_ids': ['a', 'b'],
        }),
        animate: () async {},
      ),
      a.expandToInclude(b),
    );
  });

  test('plot_function schema has expressions only, no expression', () {
    final schemas = toolSchemas();
    final plot =
        schemas.firstWhere((t) => (t as Map)['name'] == 'plot_function') as Map;
    final params = plot['parameters'] as Map;
    final propsMap = params['properties'] as Map;
    expect(propsMap.containsKey('expression'), isFalse);
    expect(propsMap.containsKey('expressions'), isTrue);
    expect((params['required'] as List), contains('expressions'));
    final focus = schemas.firstWhere(
      (t) => (t as Map)['name'] == 'focus_viewport',
    ) as Map;
    final focusProps = ((focus['parameters'] as Map)['properties'] as Map);
    expect(focusProps.containsKey('element_ids'), isTrue);
  });

  test('camera interpolation pans straight and zooms monotonically', () {
    const viewport = Size(800, 600);
    // Start centred on (200, 200) at scale 0.5.
    final start = BoardController.cameraMatrixAt(
      start: Matrix4.identity(),
      viewportSize: viewport,
      targetCenter: const Offset(200, 200),
      targetScale: 0.5,
      t: 1,
    );
    final mid = BoardController.cameraMatrixAt(
      start: start,
      viewportSize: viewport,
      targetCenter: const Offset(1000, 700),
      targetScale: 2.0,
      t: 0.5,
    );
    // Half-way, the viewed centre is the straight midpoint and the
    // scale is the geometric mean (already zooming in, never out).
    final translation = mid.getTranslation();
    final midScale = mid.storage[0];
    final midCenter = Offset(
      (viewport.width / 2 - translation.x) / midScale,
      (viewport.height / 2 - translation.y) / midScale,
    );
    expect(midCenter.dx, closeTo(600, 0.001));
    expect(midCenter.dy, closeTo(450, 0.001));
    expect(midScale, closeTo(1.0, 0.001));
  });

  test('frameRect does nothing while the student has the camera', () async {
    final c = controller();
    c.cameraTakenByStudent = true;
    final before = c.transform.value.clone();
    await c.frameRect(const Rect.fromLTWH(500, 400, 200, 100));
    expect(c.transform.value, before);
    // A new reply taking the camera back (SessionController resets the
    // flag per reply) makes framing work again.
    c.cameraTakenByStudent = false;
    await c.frameRect(const Rect.fromLTWH(500, 400, 200, 100));
    expect(c.transform.value, isNot(before));
  });

  test(
    'frameRectUnlessCovered only moves when the applied rect was missed',
    () async {
      final c = controller();
      const framed = Rect.fromLTWH(100, 100, 400, 300);
      final before = c.transform.value.clone();
      await c.frameRectUnlessCovered(
        const Rect.fromLTWH(150, 150, 200, 100),
        framed,
      );
      expect(c.transform.value, before);
      // An applied rect largely outside the pre-framed one (e.g. an edit
      // that moved the element) does get framed.
      await c.frameRectUnlessCovered(
        const Rect.fromLTWH(1100, 800, 200, 100),
        framed,
      );
      expect(c.transform.value, isNot(before));
    },
  );

  test(
    'frameRectUnlessCovered skips when applied rect already visible',
    () async {
      final c = controller();
      // Frame a large predicted rect first (one camera move).
      await c.frameRect(const Rect.fromLTWH(100, 100, 400, 300));
      final before = c.transform.value.clone();
      // A smaller applied rect inside that framing needs no second move,
      // even though it overlaps the *raw* predicted rect by <50% is not
      // the criterion - being comfortably on screen is.
      await c.frameRectUnlessCovered(
        const Rect.fromLTWH(180, 180, 60, 40),
        const Rect.fromLTWH(100, 100, 400, 300),
        source: 'test',
      );
      expect(c.transform.value, before);
    },
  );

  test(
    'a second frameRect supersedes the first instead of fighting it',
    () async {
      final c = controller();
      final first = c.frameRect(
        const Rect.fromLTWH(100, 100, 200, 100),
        source: 'first',
      );
      // Let the first animation get under way, then retarget.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final second = c.frameRect(
        const Rect.fromLTWH(1200, 900, 200, 100),
        source: 'second',
      );
      await Future.wait([first, second]);
      // Camera ends at the second target, not pulled back to the first.
      final visible = c.visibleBoardRect();
      expect(visible.contains(const Offset(1300, 950)), isTrue);
    },
  );
}
