import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:texa/app_controller.dart';
import 'package:texa/core/data/db.dart';
import 'package:texa/core/data/models.dart';
import 'package:texa/features/home/home_screen.dart';
import 'package:texa/generated/i18n/translations.g.dart';

void main() {
  testWidgets('creating a session does not rebuild the closing dialog with '
      'disposed controllers', (tester) async {
    final app = AppController(AppDb.memory())
      ..settings = const AppSettings(
        homeWelcomeSeen: true,
        micPermissionDenied: true,
      );
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(home: HomeScreen(app: app)),
      ),
    );
    await tester.pump();
    await tester.tap(find.text(tr.home.newSession).first);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.tap(find.text(tr.home.createSession));
    // Step through the dialog's exit and the session route's entry
    // frame by frame: this transition is what used to rebuild the
    // dialog's text fields after their controllers were disposed.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(AlertDialog), findsNothing);
    expect(app.sessions, hasLength(1));
    expect(app.sessions.single.title, startsWith('Session · '));
  });
}
