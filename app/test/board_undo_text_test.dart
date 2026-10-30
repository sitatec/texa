import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:texa/features/study_session/ai/ai_actions.dart';
import 'package:texa/features/study_session/board/board_models.dart';
import 'package:texa/features/study_session/board_controller.dart';

BoardElement _stroke(String id, List<Offset> points) => BoardElement(
  id: id,
  kind: BoardElementKind.stroke,
  owner: BoardOwner.student,
  color: const Color(0xFF000000),
  strokeWidth: 24,
  points: points,
);

List<Offset> _line() => [for (var i = 0; i <= 10; i++) Offset(i * 20.0, 0)];

void main() {
  group('erase undo/redo', () {
    test('one erase drag is exactly one undo step', () {
      final c = BoardController();
      c.elements = [_stroke('line', _line())];
      expect(c.canUndo, isFalse);

      // A drag: many erase points, like the pointer reports.
      c.beginErase();
      c.eraseAt(const Offset(80, 0), 15);
      c.eraseAt(const Offset(100, 0), 15);
      c.eraseAt(const Offset(120, 0), 15);
      c.endErase();
      expect(c.elements.length, greaterThan(1));

      // A single undo brings the whole line back...
      c.undo();
      expect(c.elements, hasLength(1));
      expect(c.elements.single.points, _line());
      expect(c.canUndo, isFalse);
      expect(c.canRedo, isTrue);

      // ...and a single redo replays the whole drag.
      c.redo();
      expect(c.elements.length, greaterThan(1));
      expect(c.canRedo, isFalse);
    });

    test('a standalone erase is undoable on its own', () {
      final c = BoardController();
      c.elements = [_stroke('line', _line())];
      c.eraseAt(const Offset(100, 0), 15);
      expect(c.elements.length, 2);
      c.undo();
      expect(c.elements.single.points, _line());
    });

    test('an erase drag that hits nothing costs no undo step', () {
      final c = BoardController();
      c.elements = [_stroke('line', _line())];
      c.beginErase();
      c.eraseAt(const Offset(500, 500), 15);
      c.endErase();
      expect(c.canUndo, isFalse);
      expect(c.elements.single.points, _line());
    });
  });

  group('free text sizing', () {
    test('short text is one measured line, not the old fixed box', () async {
      final c = BoardController();
      final rect = await c.applyAction(
        ActionItem('write_text', {
          'element_id': 'label',
          'x': 60.0,
          'y': 60.0,
          'text': 'Hi',
        }),
        animate: () async {},
      );
      final el = c.elements.single;
      expect(el.kind, BoardElementKind.text);
      expect(rect, el.rect);
      // Not the old fixed 520x90 defaults.
      expect(el.width, lessThan(120));
      expect(el.height, lessThan(60));
    });

    test('long text wraps at the board edge and grows taller', () async {
      final c = BoardController();
      await c.applyAction(
        ActionItem('write_text', {
          'element_id': 'note',
          'x': 1400.0,
          'y': 60.0,
          'text':
              'This is a much longer piece of board text that cannot fit '
              'on one line before the edge of the board arrives',
        }),
        animate: () async {},
      );
      final el = c.elements.single;
      expect(el.rect.right, lessThanOrEqualTo(1600));
      expect(el.height, greaterThan(60)); // wrapped onto several lines
    });

    test('multi-line text is one element with one line per line', () async {
      final c = BoardController();
      await c.applyAction(
        ActionItem('write_text', {
          'element_id': 'steps',
          'x': 60.0,
          'y': 60.0,
          'text': 'Step one\nStep two\nStep three',
        }),
        animate: () async {},
      );
      // A single write_text call, newlines preserved: not split into
      // separate elements, and measured as three lines tall.
      expect(c.elements, hasLength(1));
      final el = c.elements.single;
      expect(el.text, 'Step one\nStep two\nStep three');
      expect(el.height, greaterThan(100));
      expect(el.width, lessThan(400));
    });

    test('edited text is re-measured', () async {
      final c = BoardController();
      await c.applyAction(
        ActionItem('write_text', {
          'element_id': 'label',
          'x': 60.0,
          'y': 60.0,
          'text': 'Hi',
        }),
        animate: () async {},
      );
      final before = c.elements.single.width;
      await c.applyAction(
        ActionItem('edit_element', {
          'element_id': 'label',
          'text': 'A considerably longer label than before',
        }),
        animate: () async {},
      );
      expect(c.elements.single.width, greaterThan(before));
      expect(c.elements.single.text, 'A considerably longer label than before');
    });
  });
}
