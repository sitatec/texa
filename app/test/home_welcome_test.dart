import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:texa/app_controller.dart';
import 'package:texa/core/data/db.dart';
import 'package:texa/core/data/models.dart';
import 'package:texa/features/home/home_screen.dart';
import 'package:texa/generated/i18n/translations.g.dart';

Future<void> _pumpHome(WidgetTester tester, AppController app) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(home: HomeScreen(app: app)),
    ),
  );
  // First frame (schedules the welcome check), the persisted claim,
  // then the dialog's entry transition.
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

FilledButton _dialogButton(WidgetTester tester) => tester.widget(
  find.descendant(
    of: find.byType(AlertDialog),
    matching: find.byType(FilledButton),
  ),
);

void main() {
  test('homeWelcomeSeen persists through the local db', () async {
    final db = AppDb.memory();
    await db.saveSettings(const AppSettings(homeWelcomeSeen: true));
    expect((await db.loadSettings()).homeWelcomeSeen, isTrue);
    // Settings saved before the flag existed still default to unseen.
    expect(const AppSettings().homeWelcomeSeen, isFalse);
  });

  testWidgets('welcome shows once, is not barrier dismissible, and its only '
      'CTA unlocks after a visible 5 second countdown', (tester) async {
    final app = AppController(AppDb.memory());
    await _pumpHome(tester, app);

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text(tr.home.welcomeTitle), findsOneWidget);
    expect(find.text(tr.home.welcomeGuideTitle), findsOneWidget);
    expect(find.text(tr.home.welcomeGuideBody), findsOneWidget);
    expect(find.text(tr.home.welcomeQuietTitle), findsOneWidget);
    expect(find.text(tr.home.welcomeQuietBody), findsOneWidget);

    // Exactly one call to action, counting down and disabled.
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(FilledButton),
      ),
      findsOneWidget,
    );
    expect(find.text('${tr.common.gotIt} (5)'), findsOneWidget);
    expect(_dialogButton(tester).onPressed, isNull);

    // Tapping outside does not dismiss it.
    await tester.tapAt(const Offset(20, 20));
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);

    // The countdown is visible as it ticks down.
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('${tr.common.gotIt} (1)'), findsOneWidget);
    expect(_dialogButton(tester).onPressed, isNull);

    // After 5 seconds the CTA unlocks and dismisses the dialog.
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(tr.common.gotIt), findsOneWidget);
    expect(_dialogButton(tester).onPressed, isNotNull);
    await tester.tap(find.text(tr.common.gotIt));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsNothing);

    // It was claimed in the local db, so it never shows again -
    // not even for a fresh Home instance.
    expect(app.settings.homeWelcomeSeen, isTrue);
    expect((await app.db.loadSettings()).homeWelcomeSeen, isTrue);
    await _pumpHome(tester, app);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('welcome does not show when already seen', (tester) async {
    final app = AppController(AppDb.memory())
      ..settings = const AppSettings(homeWelcomeSeen: true);
    await _pumpHome(tester, app);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
