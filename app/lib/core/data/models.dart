import 'dart:convert';

/// App settings persisted locally.
class AppSettings {
  const AppSettings({
    this.apiKey = '',
    this.captionsDefault = true,
    this.micPermissionDenied = false,
    this.setupComplete = false,
  });
  final String apiKey;
  final bool captionsDefault;
  final bool micPermissionDenied;
  final bool setupComplete;
  AppSettings copyWith({
    String? apiKey,
    bool? captionsDefault,
    bool? micPermissionDenied,
    bool? setupComplete,
  }) => AppSettings(
    apiKey: apiKey ?? this.apiKey,
    captionsDefault: captionsDefault ?? this.captionsDefault,
    micPermissionDenied: micPermissionDenied ?? this.micPermissionDenied,
    setupComplete: setupComplete ?? this.setupComplete,
  );
  Map<String, Object?> toJson() => {
    'captionsDefault': captionsDefault,
    'micPermissionDenied': micPermissionDenied,
    'setupComplete': setupComplete,
  };
  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
    apiKey: j['apiKey'] as String? ?? '',
    captionsDefault: j['captionsDefault'] as bool? ?? true,
    micPermissionDenied: j['micPermissionDenied'] as bool? ?? false,
    setupComplete: j['setupComplete'] as bool? ?? false,
  );
}

/// A tutoring session. Its model never changes after creation.
class Session {
  const Session({
    required this.id,
    required this.title,
    required this.model,
    required this.createdAt,
    this.reasoningEffort,
    required this.updatedAt,
    this.thumbnailBase64,
  });
  final String id;
  final String title;
  final String model;

  /// Reasoning effort chosen at creation (`minimal`..`xhigh`), or null to
  /// send no reasoning parameter at all.
  final String? reasoningEffort;

  final DateTime createdAt;
  final DateTime updatedAt;
  final String? thumbnailBase64;
  Session copyWith({
    String? title,
    DateTime? updatedAt,
    String? thumbnailBase64,
  }) => Session(
    id: id,
    title: title ?? this.title,
    model: model,
    reasoningEffort: reasoningEffort,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    thumbnailBase64: thumbnailBase64 ?? this.thumbnailBase64,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'model': model,
    'reasoningEffort': reasoningEffort,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'thumbnailBase64': thumbnailBase64,
  };
  factory Session.fromJson(Map<String, dynamic> j) => Session(
    id: j['id'] as String,
    title: j['title'] as String? ?? 'Session',
    model: j['model'] as String? ?? '',
    reasoningEffort: j['reasoningEffort'] as String?,
    createdAt:
        DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
    updatedAt:
        DateTime.tryParse(j['updatedAt'] as String? ?? '') ?? DateTime.now(),
    thumbnailBase64: j['thumbnailBase64'] as String?,
  );
}

/// One saved conversation message.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.kind,
    required this.payloadJson,
    required this.createdAt,
  });
  final String id;
  final String sessionId;
  final String role;
  final String kind;
  final String payloadJson;
  final DateTime createdAt;
  Map<String, Object?> toJson() => {
    'id': id,
    'sessionId': sessionId,
    'role': role,
    'kind': kind,
    'payloadJson': payloadJson,
    'createdAt': createdAt.toIso8601String(),
  };
  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
    id: j['id'] as String,
    sessionId: j['sessionId'] as String,
    role: j['role'] as String,
    kind: j['kind'] as String? ?? 'text',
    payloadJson: j['payloadJson'] as String? ?? '{}',
    createdAt:
        DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
  );
  Map<String, dynamic> get payload {
    try {
      final v = jsonDecode(payloadJson);
      return v is Map<String, dynamic> ? v : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }
}

String newId() => DateTime.now().microsecondsSinceEpoch.toString();
String relativeTime(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'Just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  return '${t.day}/${t.month}/${t.year}';
}

/// One session's observation note about the student.
class SessionObservation {
  const SessionObservation({
    required this.sessionId,
    required this.date,
    required this.content,
  });
  final String sessionId;
  final DateTime date;
  final String content;
  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'date': date.toIso8601String(),
    'content': content,
  };
  factory SessionObservation.fromJson(Map<String, dynamic> j) =>
      SessionObservation(
        sessionId: j['sessionId'] as String,
        date: DateTime.tryParse(j['date'] as String? ?? '') ?? DateTime.now(),
        content: j['content'] as String? ?? '',
      );
}
