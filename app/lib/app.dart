import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_controller.dart';
import 'core/theme.dart';
import 'features/home/home_screen.dart';
import 'features/setup/setup_screen.dart';
import 'generated/i18n/translations.g.dart';

/// Root app: setup gate, then Home.
class App extends StatelessWidget {
  const App({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => MaterialApp(
        title: tr.app.title,
        debugShowCheckedModeBanner: false,
        theme: lightTheme,
        // darkTheme: darkTheme,
        localizationsDelegates: const [
          ...GlobalMaterialLocalizations.delegates,
        ],
        home:
            (controller.settings.apiKey.isEmpty ||
                !controller.settings.setupComplete)
            ? SetupScreen(
                app: controller,
                onDone: () => controller.refreshSessions(),
              )
            : HomeScreen(app: controller),
      ),
    );
  }
}
