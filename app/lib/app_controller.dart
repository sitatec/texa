import 'package:flutter/foundation.dart';

import 'core/data/db.dart';
import 'core/data/models.dart';
import 'features/study_session/speech/model_provisioning.dart';
import 'features/study_session/speech/sherpa_speech.dart';

/// App-wide state: settings, sessions and speech readiness.
class AppController extends ChangeNotifier {
  AppController(this.db);
  final AppDb db;
  final ModelProvisioningService provisioning = ModelProvisioningService();
  final SherpaSpeech speech = SherpaSpeech();
  AppSettings settings = const AppSettings();
  List<Session> sessions = [];
  bool speechReady = false;
  String memoryText = '';

  Future<void> init() async {
    settings = await db.loadSettings();
    memoryText = await db.loadMemory();
    sessions = await db.loadSessions();
    await tryInitSpeech();
  }

  /// Initialises on-device speech when the selected voice engine's
  /// models are already provisioned. Returns whether TTS is ready.
  Future<bool> tryInitSpeech() async {
    try {
      final engine = settings.ttsEngineOrDefault;
      speechReady = false;
      if (await provisioning.isReadyFor(engine)) {
        final paths = await provisioning.ttsPathsFor(engine);
        speechReady = await speech.initTts(
          engine,
          model: paths.model,
          voices: paths.voices,
          tokens: paths.tokens,
          lexicon: paths.lexicon,
        );
      }
    } catch (e) {
      debugPrint('Texa speech init: $e');
      speechReady = false;
    }
    notifyListeners();
    return speechReady;
  }

  /// Switches the voice engine (Settings): persists the choice,
  /// downloads the newly selected engine first if needed, then
  /// restarts TTS with it.
  Future<void> changeTtsEngine(
    TtsEngine engine, {
    void Function(String label, double fraction)? onProgress,
  }) async {
    if (!await provisioning.isReadyFor(engine)) {
      await provisioning.provision(onProgress ?? (_, _) {}, engine: engine);
    }
    await saveSettings(settings.copyWith(ttsEngine: engine));
    await tryInitSpeech();
  }

  /// Path to the installed Silero model, when provisioned.
  Future<String?> sileroVadPath() async {
    try {
      return await provisioning.isVadReady ? await provisioning.vadPath : null;
    } catch (_) {
      return null;
    }
  }

  /// Path to the installed Smart Turn model, when provisioned.
  Future<String?> smartTurnPath() async {
    try {
      return await provisioning.isVadReady ? await provisioning.smartTurnPath : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveMemory(String text) async {
    memoryText = text;
    await db.saveMemory(text);
    notifyListeners();
  }

  Future<void> saveSettings(AppSettings s) async {
    settings = s;
    await db.saveSettings(s);
    notifyListeners();
  }

  Future<void> refreshSessions() async {
    sessions = await db.loadSessions();
    notifyListeners();
  }

  Future<Session> createSession(String model, {String? reasoningEffort}) async {
    final now = DateTime.now();
    final session = Session(
      id: newId(),
      title:
          'Session · ${now.day}/${now.month}, ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
      model: model,
      reasoningEffort: reasoningEffort,
      createdAt: now,
      updatedAt: now,
    );
    sessions = [session, ...sessions];
    await db.saveSessions(sessions);
    notifyListeners();
    return session;
  }

  Future<void> renameSession(Session s, String title) async {
    final i = sessions.indexWhere((e) => e.id == s.id);
    if (i < 0) return;
    sessions[i] = sessions[i].copyWith(title: title);
    await db.saveSessions(sessions);
    notifyListeners();
  }

  Future<void> deleteSession(Session s) async {
    sessions = sessions.where((e) => e.id != s.id).toList();
    await db.deleteSession(s.id);
    notifyListeners();
  }

  Future<void> wipeAll() async {
    await db.wipeAll();
    settings = const AppSettings();
    sessions = [];
    notifyListeners();
  }
}
