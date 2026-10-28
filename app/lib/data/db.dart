import 'dart:convert';

import 'package:path_provider/path_provider.dart';
import 'package:tostore/tostore.dart';

import 'models.dart';

/// Local persistence backed by tostore on every platform.
/// [AppDb.memory] exists only so tests can run without a real store.
class AppDb {
  AppDb._(this._store, this._memory);
  final ToStore? _store;
  final Map<String, String>? _memory;
  static Future<AppDb> open() async {
    String? path;
    try {
      path = await getAppDir();
    } catch (_) {
      // Some platforms report no support directory; tostore then uses its
      // own default storage location for the same database.
    }
    return AppDb._(await ToStore.open(dbPath: path, dbName: 'texa'), null);
  }

  static Future<String?> getAppDir() async =>
      (await getApplicationSupportDirectory()).path;
  factory AppDb.memory() => AppDb._(null, {});
  Future<void> put(String key, String value) async {
    if (_store != null) {
      await _store.setValue(key, value);
    } else {
      _memory![key] = value;
    }
  }

  Future<String?> get(String key) async {
    if (_store != null) {
      final v = await _store.getValue(key);
      return v?.toString();
    }
    return _memory![key];
  }

  Future<void> remove(String key) async {
    if (_store != null) {
      await _store.removeValue(key);
    } else {
      _memory!.remove(key);
    }
  }

  Future<AppSettings> loadSettings() async {
    final s = await get('settings');
    if (s == null) return const AppSettings();
    try {
      return AppSettings.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return const AppSettings();
    }
  }

  Future<void> saveSettings(AppSettings s) =>
      put('settings', jsonEncode(s.toJson()));
  Future<List<Session>> loadSessions() async {
    final s = await get('sessions');
    if (s == null) return [];
    try {
      return (jsonDecode(s) as List)
          .map((e) => Session.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    } catch (_) {
      return [];
    }
  }

  Future<void> saveSessions(List<Session> v) =>
      put('sessions', jsonEncode(v.map((e) => e.toJson()).toList()));
  Future<void> saveBoard(String id, String json) => put('board_$id', json);
  Future<String?> loadBoard(String id) => get('board_$id');
  Future<List<ChatMessage>> loadMessages(String id) async {
    final s = await get('messages_$id');
    if (s == null) return [];
    try {
      return (jsonDecode(s) as List)
          .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveMessages(String id, List<ChatMessage> v) =>
      put('messages_$id', jsonEncode(v.map((e) => e.toJson()).toList()));
  Future<void> deleteSession(String id) async {
    final all = await loadSessions();
    await saveSessions(all.where((e) => e.id != id).toList());
    await remove('board_$id');
    await remove('messages_$id');
  }

  Future<void> wipeAll() async {
    await saveSessions([]);
    await remove('settings');
    await put('sessions', '[]');
  }

  Future<String> loadMemory() async => await get('memory') ?? '';
  Future<void> saveMemory(String text) => put('memory', text);
  Future<List<SessionObservation>> loadObservations() async {
    final raw = await get('observations');
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => SessionObservation.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.date.compareTo(a.date));
    } catch (_) {
      return [];
    }
  }

  Future<void> saveObservation(String sessionId, String content) async {
    final all = await loadObservations();
    all.removeWhere((e) => e.sessionId == sessionId);
    if (content.trim().isNotEmpty) {
      all.add(
        SessionObservation(
          sessionId: sessionId,
          date: DateTime.now(),
          content: content,
        ),
      );
    }
    await put('observations', jsonEncode(all.map((e) => e.toJson()).toList()));
  }

  /// Full-text (contains) + date-range search over session observations.
  /// The MVP substitute for embedding search; date-only filtering is the
  /// guaranteed baseline if text matching finds nothing.
  List<SessionObservation> searchObservations(
    List<SessionObservation> all, {
    String? query,
    DateTime? from,
    DateTime? to,
  }) {
    return all.where((o) {
      if (from != null && o.date.isBefore(from)) return false;
      if (to != null && o.date.isAfter(to)) return false;
      if (query != null && query.trim().isNotEmpty) {
        return o.content.toLowerCase().contains(query.trim().toLowerCase());
      }
      return true;
    }).toList();
  }

  Future<void> appendLog(String line) async {
    final s = await get('logs') ?? '';
    final lines = (s.isEmpty ? <String>[] : s.split('\n'))
      ..add('${DateTime.now().toIso8601String()} $line');
    if (lines.length > 300) lines.removeRange(0, lines.length - 300);
    await put('logs', lines.join('\n'));
  }

  Future<String> loadLogs() async => await get('logs') ?? '';
}
