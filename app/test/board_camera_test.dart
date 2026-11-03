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
}
