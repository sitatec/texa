import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tostore/tostore.dart';

import 'models.dart';

/// Local persistence.
///
/// Collections (sessions, boards, messages, observations) live in
/// tostore **tables** with indexes, so lookups use the engine's query
/// planner instead of loading and filtering whole JSON blobs in Dart.
/// Singletons (settings JSON, memory, logs) stay in the KV store, which
/// is the right tool for single values. The API key is never in either:
/// it lives in platform secure storage (see [loadSettings]).
/// [AppDb.memory] exists only so tests can run without a real store.
class AppDb {
  AppDb._(this._store, this._secure, this._memory, this._tables);
  final ToStore? _store;
  final FlutterSecureStorage? _secure;
  final Map<String, String>? _memory;
  final Map<String, Map<String, Map<String, dynamic>>>? _tables;
  String? _memoryApiKey;

  static const _apiKeySecureKey = 'texa_api_key';

  static List<TableSchema> get _schemas => [
    TableSchema(
      name: 'sessions',
      primaryKeyConfig: const PrimaryKeyConfig(
        name: 'id',
        type: PrimaryKeyType.none,
      ),
      fields: const [
        FieldSchema(name: 'title', type: DataType.text),
        FieldSchema(name: 'model', type: DataType.text),
        FieldSchema(name: 'created_at', type: DataType.text),
        FieldSchema(name: 'updated_at', type: DataType.text),
        FieldSchema(name: 'thumbnail', type: DataType.text),
        FieldSchema(name: 'reasoning', type: DataType.text),
      ],
      indexes: const [
        IndexSchema(fields: ['updated_at']),
      ],
    ),
    TableSchema(
      name: 'boards',
      primaryKeyConfig: const PrimaryKeyConfig(
        name: 'session_id',
        type: PrimaryKeyType.none,
      ),
      fields: const [FieldSchema(name: 'snapshot', type: DataType.text)],
    ),
    TableSchema(
      name: 'messages',
      primaryKeyConfig: const PrimaryKeyConfig(
        name: 'id',
        type: PrimaryKeyType.none,
      ),
      fields: const [
        FieldSchema(name: 'session_id', type: DataType.text),
        FieldSchema(name: 'role', type: DataType.text),
        FieldSchema(name: 'kind', type: DataType.text),
        FieldSchema(name: 'payload', type: DataType.text),
        FieldSchema(name: 'created_at', type: DataType.text),
      ],
      indexes: const [
        IndexSchema(fields: ['session_id']),
        IndexSchema(fields: ['created_at']),
      ],
    ),
    TableSchema(
      name: 'observations',
      primaryKeyConfig: const PrimaryKeyConfig(
        name: 'session_id',
        type: PrimaryKeyType.none,
      ),
      fields: const [
        FieldSchema(name: 'date', type: DataType.text),
        FieldSchema(name: 'content', type: DataType.text),
      ],
      indexes: const [
        IndexSchema(fields: ['date']),
      ],
    ),
  ];

  static Future<AppDb> open() async {
    String? path;
    try {
      path = await getAppDir();
    } catch (_) {
      // Some platforms report no support directory; tostore then uses its
      // own default storage location for the same database.
    }
    final store = await ToStore.open(
      dbPath: path,
      dbName: 'texa',
      schemas: _schemas,
    );
    final db = AppDb._(store, const FlutterSecureStorage(), null, null);
    await db._migrateLegacyKv();
    return db;
  }

  static Future<String?> getAppDir() async =>
      (await getApplicationSupportDirectory()).path;
  factory AppDb.memory() => AppDb._(null, null, {}, {});

  // ---------- KV singletons ----------
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

  // ---------- Table primitives (engine-backed, in-memory for tests) ----------
  Future<void> _upsert(String table, Map<String, dynamic> row) async {
    if (_store != null) {
      await _store.upsert(table, row);
    } else {
      final pk = table == 'boards' || table == 'observations'
          ? 'session_id'
          : 'id';
      _tables![table] ??= {};
      _tables[table]![row[pk].toString()] = Map.of(row);
    }
  }

  Future<List<Map<String, dynamic>>> _rows(
    String table, {
    String? whereField,
    Object? whereValue,
    String? orderByDescField,
    String? orderByAscField,
  }) async {
    if (_store != null) {
      final q = _store.query(table);
      if (whereField != null) q.where(whereField, '=', whereValue);
      if (orderByDescField != null) q.orderByDesc(orderByDescField);
      if (orderByAscField != null) q.orderByAsc(orderByAscField);
      final result = await q;
      return result.data;
    }
    var rows = (_tables![table] ?? {}).values
        .map((r) => Map<String, dynamic>.of(r))
        .toList();
    if (whereField != null) {
      rows = rows.where((r) => r[whereField] == whereValue).toList();
    }
    if (orderByDescField != null) {
      rows.sort(
        (a, b) => (b[orderByDescField] as String? ?? '').compareTo(
          a[orderByDescField] as String? ?? '',
        ),
      );
    }
    if (orderByAscField != null) {
      rows.sort(
        (a, b) => (a[orderByAscField] as String? ?? '').compareTo(
          b[orderByAscField] as String? ?? '',
        ),
      );
    }
    return rows;
  }

  Future<void> _deleteWhere(String table, String field, Object value) async {
    if (_store != null) {
      await _store.delete(table).where(field, '=', value);
    } else {
      _tables![table]?.removeWhere((_, r) => r[field] == value);
    }
  }

  Future<void> _clearTable(String table) async {
    if (_store != null) {
      await _store.clear(table);
    } else {
      _tables![table]?.clear();
    }
  }

  /// One-time migration of the pre-table KV layout into tables.
  Future<void> _migrateLegacyKv() async {
    try {
      if (await get('migrated_tables_v1') != null) return;
      final rawSessions = await get('sessions');
      if (rawSessions != null && (await _rows('sessions')).isEmpty) {
        final sessions = (jsonDecode(rawSessions) as List)
            .map((e) => Session.fromJson(e as Map<String, dynamic>))
            .toList();
        for (final s in sessions) {
          await _upsert('sessions', _sessionRow(s));
          final board = await get('board_${s.id}');
          if (board != null) {
            await _upsert('boards', {'session_id': s.id, 'snapshot': board});
          }
          final msgs = await get('messages_${s.id}');
          if (msgs != null) {
            for (final m in (jsonDecode(msgs) as List)) {
              await _upsert(
                'messages',
                _messageRow(ChatMessage.fromJson(m as Map<String, dynamic>)),
              );
            }
          }
        }
      }
      final rawObs = await get('observations');
      if (rawObs != null && (await _rows('observations')).isEmpty) {
        for (final o in (jsonDecode(rawObs) as List)) {
          final obs = SessionObservation.fromJson(o as Map<String, dynamic>);
          await _upsert('observations', {
            'session_id': obs.sessionId,
            'date': obs.date.toIso8601String(),
            'content': obs.content,
          });
        }
      }
      await put('migrated_tables_v1', '1');
    } catch (_) {
      // Migration is best-effort; the app starts clean rather than crashing.
    }
  }

  // ---------- Settings + secure API key ----------
  Future<AppSettings> loadSettings() async {
    final s = await get('settings');
    if (s == null) return const AppSettings();
    try {
      final j = Map<String, dynamic>.from(jsonDecode(s) as Map);
      final legacyKey = j.remove('apiKey') as String?;
      var apiKey = await _readApiKey() ?? legacyKey ?? '';
      if (legacyKey != null && legacyKey.isNotEmpty) {
        // Migrate a plaintext key from the old settings blob into secure
        // storage and rewrite the blob without it.
        await _writeApiKey(legacyKey);
        await put('settings', jsonEncode(j));
        apiKey = legacyKey;
      }
      final parsed = AppSettings.fromJson(j);
      return parsed.copyWith(apiKey: apiKey);
    } catch (_) {
      return const AppSettings();
    }
  }

  Future<String?> _readApiKey() async {
    if (_secure != null) return _secure.read(key: _apiKeySecureKey);
    return _memoryApiKey;
  }

  Future<void> _writeApiKey(String key) async {
    if (_secure != null) {
      if (key.isEmpty) {
        await _secure.delete(key: _apiKeySecureKey);
      } else {
        await _secure.write(key: _apiKeySecureKey, value: key);
      }
    } else {
      _memoryApiKey = key.isEmpty ? null : key;
    }
  }

  Future<void> saveSettings(AppSettings s) async {
    await _writeApiKey(s.apiKey.trim());
    await put('settings', jsonEncode(s.toJson()));
  }

  // ---------- Sessions ----------
  Map<String, dynamic> _sessionRow(Session s) => {
    'id': s.id,
    'title': s.title,
    'model': s.model,
    'created_at': s.createdAt.toIso8601String(),
    'updated_at': s.updatedAt.toIso8601String(),
    'thumbnail': s.thumbnailBase64,
    'reasoning': s.reasoningEffort,
  };

  Session _sessionFromRow(Map<String, dynamic> r) => Session(
    id: r['id'] as String,
    title: r['title'] as String? ?? 'Session',
    model: r['model'] as String? ?? '',
    createdAt:
        DateTime.tryParse(r['created_at'] as String? ?? '') ?? DateTime.now(),
    updatedAt:
        DateTime.tryParse(r['updated_at'] as String? ?? '') ?? DateTime.now(),
    thumbnailBase64: r['thumbnail'] as String?,
    reasoningEffort: r['reasoning'] as String?,
  );

  Future<List<Session>> loadSessions() async {
    final rows = await _rows('sessions', orderByDescField: 'updated_at');
    return rows.map(_sessionFromRow).toList();
  }

  Future<void> saveSessions(List<Session> v) async {
    final keep = <String>{};
    for (final s in v) {
      keep.add(s.id);
      await _upsert('sessions', _sessionRow(s));
    }
    for (final r in await _rows('sessions')) {
      if (!keep.contains(r['id'])) {
        await _deleteWhere('sessions', 'id', r['id'] as Object);
      }
    }
  }

  Future<void> saveBoard(String id, String json) =>
      _upsert('boards', {'session_id': id, 'snapshot': json});

  Future<String?> loadBoard(String id) async {
    final rows = await _rows(
      'boards',
      whereField: 'session_id',
      whereValue: id,
    );
    return rows.isEmpty ? null : rows.first['snapshot'] as String?;
  }

  // ---------- Messages ----------
  Map<String, dynamic> _messageRow(ChatMessage m) => {
    'id': m.id,
    'session_id': m.sessionId,
    'role': m.role,
    'kind': m.kind,
    'payload': m.payloadJson,
    'created_at': m.createdAt.toIso8601String(),
  };

  Future<List<ChatMessage>> loadMessages(String id) async {
    final rows = await _rows(
      'messages',
      whereField: 'session_id',
      whereValue: id,
      orderByAscField: 'created_at',
    );
    return rows
        .map(
          (r) => ChatMessage(
            id: r['id'] as String,
            sessionId: r['session_id'] as String? ?? id,
            role: r['role'] as String? ?? 'ai',
            kind: r['kind'] as String? ?? 'text',
            payloadJson: r['payload'] as String? ?? '{}',
            createdAt:
                DateTime.tryParse(r['created_at'] as String? ?? '') ??
                DateTime.now(),
          ),
        )
        .toList();
  }

  Future<void> saveMessages(String id, List<ChatMessage> v) async {
    final keep = <String>{};
    for (final m in v) {
      keep.add(m.id);
      await _upsert('messages', _messageRow(m));
    }
    for (final r in await _rows(
      'messages',
      whereField: 'session_id',
      whereValue: id,
    )) {
      if (!keep.contains(r['id'])) {
        await _deleteWhere('messages', 'id', r['id'] as Object);
      }
    }
  }

  Future<void> deleteSession(String id) async {
    await _deleteWhere('sessions', 'id', id);
    await _deleteWhere('boards', 'session_id', id);
    await _deleteWhere('messages', 'session_id', id);
    await _deleteWhere('observations', 'session_id', id);
  }

  Future<void> wipeAll() async {
    for (final t in ['sessions', 'boards', 'messages', 'observations']) {
      await _clearTable(t);
    }
    await _writeApiKey('');
    await remove('settings');
    await remove('memory');
    await remove('logs');
  }

  // ---------- Memory & observations ----------
  Future<String> loadMemory() async => await get('memory') ?? '';
  Future<void> saveMemory(String text) => put('memory', text);

  Future<List<SessionObservation>> loadObservations() async {
    final rows = await _rows('observations', orderByDescField: 'date');
    return rows
        .map(
          (r) => SessionObservation(
            sessionId: r['session_id'] as String,
            date:
                DateTime.tryParse(r['date'] as String? ?? '') ?? DateTime.now(),
            content: r['content'] as String? ?? '',
          ),
        )
        .toList();
  }

  Future<void> saveObservation(String sessionId, String content) async {
    if (content.trim().isEmpty) {
      await _deleteWhere('observations', 'session_id', sessionId);
      return;
    }
    await _upsert('observations', {
      'session_id': sessionId,
      'date': DateTime.now().toIso8601String(),
      'content': content,
    });
  }

  /// Full-text (contains) + date-range search over session observations.
  /// Date bounds map to the indexed `date` column; content matching is a
  /// case-insensitive contains over the (small, one-per-session) result
  /// set until embedding search lands (store supports vector indexes).
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

  Future<void> clearLogs() async {
    await remove('logs');
  }
}
