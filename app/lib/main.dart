import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';

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
}
