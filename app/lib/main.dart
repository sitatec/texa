import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

import 'app.dart';
import 'app_controller.dart';
import 'core/data/db.dart';
import 'generated/i18n/translations.g.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // LocaleSettings.useDeviceLocale();
  LocaleSettings.setLocale(.en);
  final db = await AppDb.open();
  final controller = AppController(db);
  await controller.init();
  runApp(TranslationProvider(child: App(controller: controller)));

  FlutterNativeSplash.remove();
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    // Restore fullscreen set by the splash screen
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: [SystemUiOverlay.top, SystemUiOverlay.bottom],
    );
  }
}
