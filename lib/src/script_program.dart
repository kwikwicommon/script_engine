enum ScriptMessagePhase { request, response }

enum ScriptConsoleLevel { info, success, warning, error }

enum ScriptProgramLanguage { javascript, legacyFlowScript }

class ScriptProgram {
  static const Object _sentinel = Object();
  static const int currentVersion = 1;

  final String id;
  final String name;
  final String source;
  final bool enabled;
  final ScriptProgramLanguage language;
  final ScriptMessagePhase phase;
  final int priority;
  final int version;
  final String? description;
  final DateTime createdAt;
  final DateTime updatedAt;

  const ScriptProgram({
    required this.id,
    required this.name,
    required this.source,
    required this.enabled,
    this.language = ScriptProgramLanguage.javascript,
    this.phase = ScriptMessagePhase.request,
    this.priority = 0,
    this.version = currentVersion,
    this.description,
    required this.createdAt,
    required this.updatedAt,
  });

  factory ScriptProgram.fromJson(Map<String, dynamic> json) {
    return ScriptProgram(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      source: json['source'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? false,
      language: _languageFromJson(json['language']),
      phase: _phaseFromJson(json['phase']),
      priority: (json['priority'] as num?)?.toInt() ?? 0,
      version: (json['version'] as num?)?.toInt() ?? currentVersion,
      description: json['description'] as String?,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  ScriptProgram copyWith({
    String? id,
    String? name,
    String? source,
    bool? enabled,
    ScriptProgramLanguage? language,
    ScriptMessagePhase? phase,
    int? priority,
    int? version,
    Object? description = _sentinel,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return ScriptProgram(
      id: id ?? this.id,
      name: name ?? this.name,
      source: source ?? this.source,
      enabled: enabled ?? this.enabled,
      language: language ?? this.language,
      phase: phase ?? this.phase,
      priority: priority ?? this.priority,
      version: version ?? this.version,
      description: identical(description, _sentinel)
          ? this.description
          : description as String?,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'source': source,
      'enabled': enabled,
      'language': language.name,
      'phase': phase.name,
      'priority': priority,
      'version': version,
      'description': description,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  static ScriptMessagePhase _phaseFromJson(Object? rawValue) {
    final value = rawValue?.toString().trim().toLowerCase();
    for (final phase in ScriptMessagePhase.values) {
      if (phase.name == value) {
        return phase;
      }
    }
    return ScriptMessagePhase.request;
  }

  static ScriptProgramLanguage _languageFromJson(Object? rawValue) {
    final value = rawValue?.toString().trim().toLowerCase();
    if (value == null || value.isEmpty) {
      return ScriptProgramLanguage.legacyFlowScript;
    }
    for (final language in ScriptProgramLanguage.values) {
      if (language.name.toLowerCase() == value) {
        return language;
      }
    }
    return ScriptProgramLanguage.javascript;
  }
}

typedef FlowScriptProgram = ScriptProgram;

class ScriptConsoleEntry {
  final String id;
  final String scriptId;
  final String scriptName;
  final String requestId;
  final ScriptMessagePhase phase;
  final ScriptConsoleLevel level;
  final String message;
  final DateTime timestamp;

  const ScriptConsoleEntry({
    required this.id,
    required this.scriptId,
    required this.scriptName,
    required this.requestId,
    required this.phase,
    required this.level,
    required this.message,
    required this.timestamp,
  });
}

class ScriptExecutionSnapshot {
  final String scriptId;
  final String scriptName;
  final String requestId;
  final ScriptMessagePhase phase;
  final bool matched;
  final String? actionType;
  final String? errorMessage;
  final List<String> matchedConditions;
  final Map<String, String> variables;
  final DateTime timestamp;

  const ScriptExecutionSnapshot({
    required this.scriptId,
    required this.scriptName,
    required this.requestId,
    required this.phase,
    required this.matched,
    required this.actionType,
    this.errorMessage,
    required this.matchedConditions,
    required this.variables,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'scriptId': scriptId,
      'scriptName': scriptName,
      'requestId': requestId,
      'phase': phase.name,
      'matched': matched,
      'actionType': actionType,
      if (errorMessage != null) 'errorMessage': errorMessage,
      'matchedConditions': matchedConditions,
      'variables': variables,
      'timestamp': timestamp.toIso8601String(),
    };
  }
}

class ScriptExecutionReport {
  final List<ScriptExecutionSnapshot> matchedScripts;
  final List<ScriptExecutionSnapshot> evaluatedScripts;
  final Map<String, dynamic>? action;
  final String? actionScriptId;
  final String? actionScriptName;
  final List<String> errors;

  const ScriptExecutionReport({
    this.matchedScripts = const <ScriptExecutionSnapshot>[],
    this.evaluatedScripts = const <ScriptExecutionSnapshot>[],
    this.action,
    this.actionScriptId,
    this.actionScriptName,
    this.errors = const <String>[],
  });

  bool get hasMatches => matchedScripts.isNotEmpty;
  bool get hasAction => action != null;
  bool get hasErrors => errors.isNotEmpty;
}
