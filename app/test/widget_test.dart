import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:texa/app_controller.dart';
import 'package:texa/core/data/db.dart';
import 'package:texa/features/home/home_screen.dart';
import 'package:texa/generated/i18n/translations.g.dart';

void main() {
  testWidgets('Home shows the empty state and New session action', (
    tester,
  ) async {
    final app = AppController(AppDb.memory());
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(home: HomeScreen(app: app)),
      ),
    );
    await tester.pump();
    expect(find.text(tr.home.emptyTitle), findsOneWidget);
    expect(find.text(tr.home.newSession), findsWidgets);
  });
}
