import 'package:flutter/foundation.dart';

import 'data/db.dart';
import 'data/models.dart';
import 'features/turn/model_provisioning.dart';
import 'features/turn/sherpa_speech.dart';

/// App-wide state: settings, sessions and speech readiness.
class AppController extends ChangeNotifier {
  AppController(this.db);
  final AppDb db;
  final ModelProvisioningService provisioning = ModelProvisioningService();
  final SherpaSpeech speech = SherpaSpeech();
  AppSettings settings = const AppSettings();
  List<Session> sessions = [];
  bool speechReady = false;

  Future<void> init() async {
    settings = await db.loadSettings();
    sessions = await db.loadSessions();
    await tryInitSpeech();
  }

  /// Initialises on-device speech when its models are already provisioned.
  Future<void> tryInitSpeech() async {
    try {
      if (await provisioning.isReady) {
        speechReady = await speech.initTts(await provisioning.kokoroDir);
      }
    } catch (e) {
      debugPrint('Texa speech init: $e');
      speechReady = false;
    }
    notifyListeners();
  }

  /// Path to the installed Silero model, when provisioned.
  Future<String?> sileroVadPath() async {
    try {
      return await provisioning.isReady ? await provisioning.vadPath : null;
    } catch (_) {
      return null;
    }
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

  Future<Session> createSession(String model) async {
    final now = DateTime.now();
    final session = Session(
      id: newId(),
      title:
          'Session · ${now.day}/${now.month}, ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
      model: model,
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
