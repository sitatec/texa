import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:texa/app_controller.dart';
import 'package:texa/core/data/db.dart';
import 'package:texa/core/data/models.dart';
import 'package:texa/features/home/home_screen.dart';
import 'package:texa/features/study_session/board/board_models.dart';
import 'package:texa/features/study_session/board/board_widget.dart';
import 'package:texa/features/study_session/board_controller.dart';
import 'package:texa/generated/i18n/translations.g.dart';

BoardSnapshot _snapshotWithText({
  double progress = 1,
  List<double> viewport = const [1, 0, 0],
  List<double> viewportSize = const [],
}) => BoardSnapshot(
  elements: [
    BoardElement(
      id: 'e1',
      kind: BoardElementKind.text,
      owner: BoardOwner.ai,
      x: 100,
      y: 50,
      width: 400,
      height: 60,
      text: 'Fractions',
      progress: progress,
    ),
  ],
  viewport: viewport,
  viewportSize: viewportSize,
  registry: const {},
);

Session _session() => Session(
  id: 's1',
  title: 'Fractions lesson',
  model: 'm1',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 2),
);

void main() {
  group('default session title', () {
    test('formats the creation date and time', () {
      expect(
        defaultSessionTitle(DateTime(2026, 3, 7, 9, 5)),
        'Session · 7/3, 09:05',
      );
    });

    test('createSession uses the given title, trimmed', () async {
      final app = AppController(AppDb.memory());
      final s = await app.createSession('m1', title: '  Algebra help  ');
      expect(s.title, 'Algebra help');
    });

    test('createSession falls back to the default title', () async {
      final app = AppController(AppDb.memory());
      final s = await app.createSession('m1', title: '   ');
      expect(s.title, matches(r'^Session · \d{1,2}/\d{1,2}, \d{2}:\d{2}$'));
    });
  });

  test('refreshSessions loads the persisted board for previews', () async {
    final db = AppDb.memory();
    final app = AppController(db);
    await db.saveSessions([_session()]);
    await db.saveBoard('s1', _snapshotWithText().encode());
    await app.refreshSessions();
    expect(app.boardPreviews['s1']?.elements.single.text, 'Fractions');
  });

  group('board camera', () {
    test('snapshot round-trips the camera and its viewport size', () {
      final back = BoardSnapshot.decode(
        _snapshotWithText(
          viewport: const [2, -100, -50],
          viewportSize: const [800, 600],
        ).encode(),
      );
      expect(back.viewport, [2, -100, -50]);
      expect(back.cameraViewportSize, const Size(800, 600));
    });

    test('BoardController.snapshot records the current camera', () {
      final c = BoardController();
      addTearDown(c.dispose);
      c.viewportSize = const Size(900, 650);
      c.transform.value = Matrix4.identity()
        ..scaleByDouble(2, 2, 1, 1)
        ..setTranslationRaw(-100, -50, 0);
      final snap = c.snapshot(null);
      expect(snap.viewport, [2, -100, -50]);
      expect(snap.viewportSize, [900, 650]);
    });
  });

  testWidgets('BoardPreview renders elements at full opacity', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 340,
            height: 255,
            child: BoardPreview(snapshot: _snapshotWithText(progress: 0.3)),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Fractions'), findsOneWidget);
    final opacity = tester.widget<Opacity>(
      find.ancestor(of: find.text('Fractions'), matching: find.byType(Opacity)),
    );
    expect(opacity.opacity, 1);
  });

  testWidgets('BoardPreview preserves the zoom and pan from closing', (
    tester,
  ) async {
    // Closed zoomed 2x into the board, panned so the element at
    // board (100, 50) sat at viewport (100, 50) of an 800x600
    // viewport. The 340x255 preview is that viewport at 0.425x, so
    // the element must land at (42.5, 21.25) - not at the
    // whole-board fit position (21.25, 10.6).
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 340,
            height: 255,
            child: BoardPreview(
              snapshot: _snapshotWithText(
                viewport: const [2, -100, -50],
                viewportSize: const [800, 600],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final topLeft = tester.getTopLeft(find.text('Fractions'));
    expect(topLeft.dx, closeTo(42.5, 0.5));
    expect(topLeft.dy, closeTo(21.25, 0.5));
  });

  testWidgets('Home renders the board preview for a session', (tester) async {
    final app = AppController(AppDb.memory())
      ..settings = const AppSettings(homeWelcomeSeen: true)
      ..sessions = [_session()]
      ..boardPreviews = {'s1': _snapshotWithText()};
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(home: HomeScreen(app: app)),
      ),
    );
    await tester.pump();
    expect(find.byType(BoardPreview), findsOneWidget);
    expect(find.text('Fractions'), findsOneWidget);
  });

  testWidgets('New session dialog prefills the default session title', (
    tester,
  ) async {
    final app = AppController(AppDb.memory())
      ..settings = const AppSettings(homeWelcomeSeen: true);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(home: HomeScreen(app: app)),
      ),
    );
    await tester.pump();
    await tester.tap(find.text(tr.home.newSession).first);
    await tester.pumpAndSettle();
    final titleField = tester.widget<TextField>(find.byType(TextField).first);
    expect(titleField.decoration?.labelText, tr.home.sessionName);
    expect(
      titleField.controller?.text,
      matches(r'^Session · \d{1,2}/\d{1,2}, \d{2}:\d{2}$'),
    );
  });
}
