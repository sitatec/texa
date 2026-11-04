import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:texa/core/http_client/http_client.dart';

import 'app.dart';
import 'app_controller.dart';
import 'core/data/db.dart';
import 'generated/i18n/translations.g.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // LocaleSettings.useDeviceLocale();
  LocaleSettings.setLocale(.en);
  await TexaHttpClient.setup();
  final db = await AppDb.open();
  final controller = AppController(db);
  await controller.init();
  try {
    final session = await AudioSession.instance;
    await session.configure(
      const AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionMode: AVAudioSessionMode.voiceChat,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.defaultToSpeaker,
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          usage: AndroidAudioUsage.voiceCommunication,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: true,
      ),
    );
  } catch (e) {
    debugPrint('Texa audio session: $e');
  }
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
