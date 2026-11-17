import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'quick_js_script_runtime.dart';
import 'script_program.dart';
import 'script_traffic.dart';

class ScriptEngineService extends ChangeNotifier {
  static const String runtimeName = 'QuickJS JavaScript';
  static const int _maxConsoleEntries = 500;
  static const int maxProgramsPerRequest = 32;
  static const int maxSourceLength = 16 * 1024;
  static const int maxConsoleMessageLength = 2048;
  static const int maxConsoleOutputBytesPerRequest = 16 * 1024;
  static const Duration maxExecutionDurationPerRequest = Duration(
    milliseconds: 20,
  );
  static final RegExp _headerNamePattern = RegExp(
    r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$",
  );

  ScriptEngineService({JavaScriptScriptRuntime? javaScriptRuntime})
    : _javaScriptRuntime =
          javaScriptRuntime ?? const ForceSniffJavaScriptRuntime() {
    scripts.addAll(_seedPrograms());
  }

  final JavaScriptScriptRuntime _javaScriptRuntime;
  final List<ScriptProgram> scripts = <ScriptProgram>[];
  final List<ScriptConsoleEntry> consoleEntries = <ScriptConsoleEntry>[];
  final Map<String, ScriptExecutionSnapshot> latestSnapshots =
      <String, ScriptExecutionSnapshot>{};
  void Function()? onScriptsChanged;

  ScriptProgram? programById(String id) {
    for (final program in scripts) {
      if (program.id == id) {
        return program;
      }
    }
    return null;
  }

  List<ScriptProgram> enabledProgramsForPhase(ScriptMessagePhase phase) {
    return _enabledProgramsForPhase(scripts, phase);
  }

  void loadPrograms(List<ScriptProgram> programs) {
    final nextPrograms = List<ScriptProgram>.from(programs)
      ..sort(_compareProgramPriority);
    scripts
      ..clear()
      ..addAll(nextPrograms);
    latestSnapshots.removeWhere(
      (scriptId, _) => !scripts.any((program) => program.id == scriptId),
    );
    _notifyScriptsChanged();
  }

  ScriptProgram createBlankProgram() {
    final now = DateTime.now();
    final program = ScriptProgram(
      id: now.microsecondsSinceEpoch.toString(),
      name: 'JavaScript ${scripts.length + 1}',
      source: '''
export default function handle(ctx) {
  ctx.log(`Inspect \${ctx.request.method} \${ctx.request.url}`);
  return ctx.continue();
}
''',
      enabled: false,
      language: ScriptProgramLanguage.javascript,
      phase: ScriptMessagePhase.request,
      priority: 0,
      version: ScriptProgram.currentVersion,
      description: 'A draft JavaScript traffic script.',
      createdAt: now,
      updatedAt: now,
    );
    scripts.add(program);
    scripts.sort(_compareProgramPriority);
    _notifyScriptsChanged();
    return program;
  }

  void saveProgram(ScriptProgram program) {
    final nextProgram = program.copyWith(updatedAt: DateTime.now());
    final index = scripts.indexWhere(
      (existing) => existing.id == nextProgram.id,
    );
    if (index == -1) {
      scripts.add(nextProgram);
      scripts.sort(_compareProgramPriority);
      _notifyScriptsChanged();
      return;
    }
    scripts[index] = nextProgram;
    scripts.sort(_compareProgramPriority);
    _notifyScriptsChanged();
  }

  void setProgramEnabled(String id, bool enabled) {
    final program = programById(id);
    if (program == null) {
      return;
    }
    saveProgram(program.copyWith(enabled: enabled));
  }

  void deleteProgram(String id) {
    scripts.removeWhere((program) => program.id == id);
    latestSnapshots.remove(id);
    _notifyScriptsChanged();
  }

  void clearConsole() {
    consoleEntries.clear();
    notifyListeners();
  }

  /// Projects native execution evidence into console and snapshot presentation.
  void recordNativeExecution(
    ScriptExecutionReport report, {
    List<Map<String, dynamic>> logs = const [],
  }) {
    for (final snapshot in report.evaluatedScripts) {
      latestSnapshots[snapshot.scriptId] = snapshot;
    }
    for (final entry in logs) {
      final snapshot = report.evaluatedScripts
          .where((item) => item.scriptId == entry['scriptId'])
          .firstOrNull;
      if (snapshot == null) continue;
      consoleEntries.add(
        ScriptConsoleEntry(
          id: '${DateTime.now().microsecondsSinceEpoch}_${consoleEntries.length}',
          scriptId: snapshot.scriptId,
          scriptName: snapshot.scriptName,
          requestId: snapshot.requestId,
          phase: snapshot.phase,
          level: ScriptConsoleLevel.info,
          message: entry['message'] as String? ?? '',
          timestamp: snapshot.timestamp,
        ),
      );
    }
    for (final snapshot in report.evaluatedScripts) {
      if (snapshot.errorMessage == null) continue;
      consoleEntries.add(
        ScriptConsoleEntry(
          id: '${DateTime.now().microsecondsSinceEpoch}_${consoleEntries.length}',
          scriptId: snapshot.scriptId,
          scriptName: snapshot.scriptName,
          requestId: snapshot.requestId,
          phase: snapshot.phase,
          level: ScriptConsoleLevel.error,
          message: snapshot.errorMessage!,
          timestamp: snapshot.timestamp,
        ),
      );
    }
    if (consoleEntries.length > _maxConsoleEntries) {
      consoleEntries.removeRange(0, consoleEntries.length - _maxConsoleEntries);
    }
    notifyListeners();
  }

  Future<ScriptExecutionReport> executeRequestScripts(
    ScriptTraffic request, {
    List<ScriptProgram>? programs,
  }) {
    return _execute(
      request,
      phase: ScriptMessagePhase.request,
      programs: _enabledProgramsForPhase(
        programs ?? scripts,
        ScriptMessagePhase.request,
      ),
      allowMutations: true,
    );
  }

  Future<ScriptExecutionReport> executeResponseScripts(
    ScriptTraffic request, {
    List<ScriptProgram>? programs,
  }) {
    return _execute(
      request,
      phase: ScriptMessagePhase.response,
      programs: _enabledProgramsForPhase(
        programs ?? scripts,
        ScriptMessagePhase.response,
      ),
      allowMutations: false,
    );
  }

  Future<ScriptExecutionReport> evaluateRequestScripts(
    ScriptTraffic request, {
    required List<ScriptProgram> programs,
  }) {
    return _execute(
      request,
      phase: ScriptMessagePhase.request,
      programs: _enabledProgramsForPhase(programs, ScriptMessagePhase.request),
      allowMutations: true,
      recordConsole: false,
      recordSnapshots: false,
    );
  }

  Future<ScriptExecutionReport> evaluateResponseScripts(
    ScriptTraffic request, {
    required List<ScriptProgram> programs,
  }) {
    return _execute(
      request,
      phase: ScriptMessagePhase.response,
      programs: _enabledProgramsForPhase(programs, ScriptMessagePhase.response),
      allowMutations: false,
      recordConsole: false,
      recordSnapshots: false,
    );
  }

  Future<ScriptExecutionReport> previewProgram(
    String programId,
    ScriptTraffic request, {
    ScriptMessagePhase phase = ScriptMessagePhase.request,
  }) async {
    final program = programById(programId);
    if (program == null || program.phase != phase) {
      return const ScriptExecutionReport();
    }
    return _execute(
      request,
      phase: phase,
      programs: <ScriptProgram>[program],
      allowMutations: phase == ScriptMessagePhase.request,
    );
  }

  Future<ScriptExecutionReport> _execute(
    ScriptTraffic request, {
    required ScriptMessagePhase phase,
    required List<ScriptProgram> programs,
    required bool allowMutations,
    bool recordConsole = true,
    bool recordSnapshots = true,
  }) async {
    final matchedSnapshots = <ScriptExecutionSnapshot>[];
    final evaluatedSnapshots = <ScriptExecutionSnapshot>[];
    final errors = <String>[];
    final mergedHeaders = <String, String>{};
    final removedHeaders = <String>{};
    String? targetUrl;
    String? body;
    Map<String, dynamic>? terminalAction;
    String? terminalScriptId;
    String? terminalScriptName;
    final budget = _ScriptExecutionBudget(
      maxConsoleOutputBytes: maxConsoleOutputBytesPerRequest,
      maxExecutionDuration: maxExecutionDurationPerRequest,
    );
    final executablePrograms = programs
        .take(maxProgramsPerRequest)
        .toList(growable: false);
    if (programs.length > maxProgramsPerRequest) {
      errors.add(
        'Script budget exceeded: only $maxProgramsPerRequest scripts can execute for one request.',
      );
    }

    for (final program in executablePrograms) {
      final timeError = budget.checkTime();
      if (timeError != null) {
        errors.add(timeError);
        break;
      }
      if (program.language == ScriptProgramLanguage.javascript) {
        final execution = await _executeJavaScriptProgram(
          program,
          request,
          phase,
          allowMutations: allowMutations,
          recordConsole: recordConsole,
          budget: budget,
        );
        if (execution.errorMessage != null) {
          errors.add(execution.errorMessage!);
        }
        final snapshot = ScriptExecutionSnapshot(
          scriptId: program.id,
          scriptName: program.name,
          requestId: request.id,
          phase: phase,
          matched: true,
          actionType: execution.actionType,
          errorMessage: execution.errorMessage,
          matchedConditions: const <String>['javascript.handle'],
          variables: const <String, String>{},
          timestamp: DateTime.now(),
        );
        evaluatedSnapshots.add(snapshot);
        if (recordSnapshots) {
          latestSnapshots[program.id] = snapshot;
          notifyListeners();
        }
        matchedSnapshots.add(snapshot);
        if (execution.addedHeaders.isNotEmpty) {
          for (final entry in execution.addedHeaders.entries) {
            mergedHeaders.removeWhere(
              (key, _) => key.toLowerCase() == entry.key.toLowerCase(),
            );
            mergedHeaders[entry.key] = entry.value;
            removedHeaders.removeWhere(
              (header) => header.toLowerCase() == entry.key.toLowerCase(),
            );
          }
        }
        if (execution.removedHeaders.isNotEmpty) {
          for (final header in execution.removedHeaders) {
            mergedHeaders.removeWhere(
              (key, _) => key.toLowerCase() == header.toLowerCase(),
            );
            removedHeaders.add(header);
          }
        }
        if (execution.targetUrl != null && execution.targetUrl!.isNotEmpty) {
          targetUrl = execution.targetUrl;
        }
        if (execution.body != null) {
          body = execution.body;
        }
        if (execution.terminalAction != null) {
          terminalAction = execution.terminalAction;
          terminalScriptId = program.id;
          terminalScriptName = program.name;
          break;
        }
        if (execution.stopProcessingScripts || execution.stopAllScripts) {
          break;
        }
        continue;
      }
      final snapshot = _legacyFlowScriptSnapshot(program, request, phase);
      errors.add(snapshot.errorMessage!);
      evaluatedSnapshots.add(snapshot);
      if (recordSnapshots) {
        latestSnapshots[program.id] = snapshot;
        notifyListeners();
      }
      if (recordConsole) {
        _appendConsoleEntry(
          program: program,
          requestId: request.id,
          phase: phase,
          level: ScriptConsoleLevel.error,
          message: snapshot.errorMessage!,
        );
      }
    }

    if (terminalAction != null) {
      return ScriptExecutionReport(
        matchedScripts: matchedSnapshots,
        evaluatedScripts: evaluatedSnapshots,
        action: terminalAction,
        actionScriptId: terminalScriptId,
        actionScriptName: terminalScriptName,
        errors: errors,
      );
    }

    if (targetUrl != null ||
        body != null ||
        mergedHeaders.isNotEmpty ||
        removedHeaders.isNotEmpty) {
      return ScriptExecutionReport(
        matchedScripts: matchedSnapshots,
        evaluatedScripts: evaluatedSnapshots,
        action: <String, dynamic>{
          'type': 'modify',
          'url': ?targetUrl,
          'body': ?body,
          if (mergedHeaders.isNotEmpty) 'headers': mergedHeaders,
          if (removedHeaders.isNotEmpty)
            'removeHeaders': removedHeaders.toList(growable: false),
        },
        actionScriptId: matchedSnapshots.isEmpty
            ? null
            : matchedSnapshots.last.scriptId,
        actionScriptName: matchedSnapshots.isEmpty
            ? null
            : matchedSnapshots.last.scriptName,
        errors: errors,
      );
    }

    return ScriptExecutionReport(
      matchedScripts: matchedSnapshots,
      evaluatedScripts: evaluatedSnapshots,
      errors: errors,
    );
  }

  ScriptExecutionSnapshot _legacyFlowScriptSnapshot(
    ScriptProgram program,
    ScriptTraffic request,
    ScriptMessagePhase phase,
  ) {
    return ScriptExecutionSnapshot(
      scriptId: program.id,
      scriptName: program.name,
      requestId: request.id,
      phase: phase,
      matched: false,
      actionType: null,
      errorMessage:
          'Legacy FlowScript DSL is no longer executed. Convert this script to JavaScript.',
      matchedConditions: const <String>[],
      variables: const <String, String>{},
      timestamp: DateTime.now(),
    );
  }

  Future<_ProgramExecution> _executeJavaScriptProgram(
    ScriptProgram program,
    ScriptTraffic request,
    ScriptMessagePhase phase, {
    required bool allowMutations,
    required bool recordConsole,
    required _ScriptExecutionBudget budget,
  }) async {
    if (program.source.length > maxSourceLength) {
      return _ProgramExecution(
          addedHeaders: <String, String>{},
          removedHeaders: <String>{},
        )
        ..errorMessage =
            'Script "${program.name}" exceeds the $maxSourceLength character source limit.';
    }
    final result = await _javaScriptRuntime.execute(
      source: program.source,
      request: request,
      phase: phase,
      timeout: budget.remainingExecutionDuration,
    );
    final execution = _ProgramExecution(
      addedHeaders: <String, String>{},
      removedHeaders: <String>{},
    );
    for (final log in result.logs) {
      final budgetedMessage = budget.consumeConsoleMessage(
        _redactSensitiveDiagnostics(log, request),
      );
      if (budgetedMessage == null) {
        execution.errorMessage =
            'Script budget exceeded: console output is limited to $maxConsoleOutputBytesPerRequest bytes per request.';
        execution.stopProcessingScripts = true;
        return execution;
      }
      if (recordConsole) {
        _appendConsoleEntry(
          program: program,
          requestId: request.id,
          phase: phase,
          level: ScriptConsoleLevel.info,
          message: budgetedMessage,
        );
      }
    }
    if (result.errors.isNotEmpty) {
      final diagnostic = _redactSensitiveDiagnostics(
        result.errors.join(' '),
        request,
      );
      execution.errorMessage = diagnostic.length > maxConsoleMessageLength
          ? diagnostic.substring(0, maxConsoleMessageLength)
          : diagnostic;
      execution.stopProcessingScripts = true;
      return execution;
    }
    final elapsedError = budget.checkTime();
    if (elapsedError != null) {
      execution.errorMessage = elapsedError;
      execution.stopProcessingScripts = true;
      return execution;
    }
    _applyJavaScriptAction(
      program,
      result.action ?? const <String, dynamic>{'type': 'continue'},
      execution,
      allowMutations: allowMutations,
    );
    return execution;
  }

  String _redactSensitiveDiagnostics(String message, ScriptTraffic request) {
    const sensitiveNames = {
      'authorization',
      'proxy-authorization',
      'cookie',
      'set-cookie',
      'x-api-key',
      'api-key',
      'token',
      'access_token',
      'refresh_token',
      'password',
      'secret',
      'api_key',
      'apikey',
    };
    final secrets = <String>{};
    for (final headers in [request.requestHeaders, request.responseHeaders]) {
      for (final entry in headers.entries) {
        if (sensitiveNames.contains(entry.key.toLowerCase()) &&
            entry.value.isNotEmpty) {
          secrets.add(entry.value);
          if (entry.value.toLowerCase().startsWith('bearer ')) {
            secrets.add(entry.value.substring(7));
          }
        }
      }
    }
    final uri = Uri.tryParse(request.url);
    if (uri != null) {
      for (final entry in uri.queryParametersAll.entries) {
        if (sensitiveNames.contains(entry.key.toLowerCase())) {
          secrets.addAll(entry.value.where((value) => value.isNotEmpty));
        }
      }
    }
    final orderedSecrets = secrets.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final secret in orderedSecrets) {
      message = message.replaceAll(secret, '[REDACTED]');
      message = message.replaceAll(Uri.encodeComponent(secret), '[REDACTED]');
    }
    return message;
  }

  void _applyJavaScriptAction(
    ScriptProgram program,
    Map<String, dynamic> action,
    _ProgramExecution execution, {
    required bool allowMutations,
  }) {
    final type = action['type']?.toString().trim().toLowerCase() ?? 'continue';
    switch (type) {
      case 'continue':
        return;
      case 'modify':
        if (!allowMutations) {
          return;
        }
        final headers = action['headers'];
        if (headers is Map) {
          for (final entry in headers.entries) {
            final headerName = _normalizeHeaderName(entry.key.toString());
            if (headerName == null) {
              execution.errorMessage =
                  'JavaScript "${program.name}" ignored invalid header name "${entry.key}".';
              continue;
            }
            final headerValue = entry.value?.toString() ?? '';
            if (!_isSafeHeaderValue(headerValue)) {
              execution.errorMessage =
                  'JavaScript "${program.name}" ignored an unsafe value for header "$headerName".';
              continue;
            }
            execution.addedHeaders[headerName] = headerValue;
            execution.actionType = 'modify';
          }
        }
        final removeHeaders = action['removeHeaders'];
        if (removeHeaders is List) {
          for (final rawHeader in removeHeaders) {
            final headerName = _normalizeHeaderName(rawHeader.toString());
            if (headerName != null) {
              execution.removedHeaders.add(headerName);
              execution.actionType = 'modify';
            }
          }
        }
        final targetUrl = action['url']?.toString();
        if (targetUrl != null && targetUrl.isNotEmpty) {
          if (_isValidTargetUrl(targetUrl)) {
            execution.targetUrl = targetUrl;
            execution.actionType = 'modify';
          } else {
            execution.errorMessage =
                'JavaScript "${program.name}" ignored invalid target URL "$targetUrl".';
          }
        }
        if (action.containsKey('body')) {
          execution.body = action['body']?.toString() ?? '';
          execution.actionType = 'modify';
        }
        return;
      case 'mock':
        if (!allowMutations) {
          return;
        }
        final statusCode = int.tryParse(action['statusCode'].toString());
        if (statusCode == null || !_isValidStatusCode(statusCode)) {
          execution.errorMessage =
              'JavaScript "${program.name}" ignored invalid mock status code ${action['statusCode']}.';
          return;
        }
        final headers = action['headers'] is Map
            ? Map<String, String>.from(
                (action['headers'] as Map).map(
                  (key, value) => MapEntry(key.toString(), value.toString()),
                ),
              )
            : const <String, String>{
                'Content-Type': 'text/plain; charset=utf-8',
              };
        execution.terminalAction = <String, dynamic>{
          'type': 'mock',
          'statusCode': statusCode,
          'headers': headers,
          'body': action['body']?.toString() ?? '',
        };
        execution.actionType = 'mock';
        return;
      case 'drop':
        if (!allowMutations) {
          return;
        }
        execution.terminalAction = const <String, dynamic>{'type': 'drop'};
        execution.actionType = 'drop';
        return;
      default:
        execution.errorMessage =
            'JavaScript "${program.name}" returned unsupported action "$type".';
        return;
    }
  }

  String? _normalizeHeaderName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty ||
        trimmed.startsWith(':') ||
        !_headerNamePattern.hasMatch(trimmed)) {
      return null;
    }
    return trimmed;
  }

  bool _isSafeHeaderValue(String value) {
    return !value.contains('\r') &&
        !value.contains('\n') &&
        !value.contains('\x00');
  }

  bool _isValidStatusCode(int value) {
    return value >= 100 && value <= 599;
  }

  bool _isValidTargetUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return false;
    }
    final scheme = uri.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }

  void _appendConsoleEntry({
    required ScriptProgram program,
    required String requestId,
    required ScriptMessagePhase phase,
    required ScriptConsoleLevel level,
    required String message,
  }) {
    consoleEntries.add(
      ScriptConsoleEntry(
        id: '${DateTime.now().microsecondsSinceEpoch}_${program.id}',
        scriptId: program.id,
        scriptName: program.name,
        requestId: requestId,
        phase: phase,
        level: level,
        message: message,
        timestamp: DateTime.now(),
      ),
    );

    final overflow = consoleEntries.length - _maxConsoleEntries;
    if (overflow > 0) {
      consoleEntries.removeRange(0, overflow);
    }
    notifyListeners();
  }

  List<ScriptProgram> _seedPrograms() {
    final now = DateTime.now();
    return <ScriptProgram>[
      ScriptProgram(
        id: 'seed_request_header_injector',
        name: 'Request Header Injector',
        source: '''
export default function handle(ctx) {
  if (ctx.request.method === "POST" && ctx.request.url.startsWith("https://api.example.com/")) {
    ctx.log(`Inject trace header for \${ctx.request.url}`);
    ctx.request.setHeader("X-ForceSniff-Trace", `trace-\${ctx.request.id}`);
  }
  return ctx.continue();
}
''',
        enabled: false,
        language: ScriptProgramLanguage.javascript,
        phase: ScriptMessagePhase.request,
        priority: 0,
        version: ScriptProgram.currentVersion,
        description: 'Adds a diagnostic header to matching API requests.',
        createdAt: now,
        updatedAt: now,
      ),
      ScriptProgram(
        id: 'seed_response_observer',
        name: 'Response Observer',
        source: '''
export default function handle(ctx) {
  if (ctx.phase === "response" && ctx.response.status === 500) {
    ctx.log(`Observed failing response for \${ctx.request.url}`);
    ctx.log(ctx.response.bodyText);
  }
  return ctx.continue();
}
''',
        enabled: false,
        language: ScriptProgramLanguage.javascript,
        phase: ScriptMessagePhase.response,
        priority: 0,
        version: ScriptProgram.currentVersion,
        description:
            'Records response status and body snippets for matching calls.',
        createdAt: now,
        updatedAt: now,
      ),
    ];
  }

  int _compareProgramPriority(ScriptProgram left, ScriptProgram right) {
    final priorityCompare = right.priority.compareTo(left.priority);
    if (priorityCompare != 0) {
      return priorityCompare;
    }
    final updatedCompare = left.updatedAt.compareTo(right.updatedAt);
    if (updatedCompare != 0) {
      return updatedCompare;
    }
    return left.id.compareTo(right.id);
  }

  List<ScriptProgram> _enabledProgramsForPhase(
    Iterable<ScriptProgram> source,
    ScriptMessagePhase phase,
  ) {
    final programs = source
        .where((program) => program.enabled && program.phase == phase)
        .toList(growable: false);
    programs.sort(_compareProgramPriority);
    return programs;
  }

  void _notifyScriptsChanged() {
    notifyListeners();
    onScriptsChanged?.call();
  }
}

class _ScriptExecutionBudget {
  final int maxConsoleOutputBytes;
  final Duration maxExecutionDuration;
  final Stopwatch _stopwatch = Stopwatch()..start();
  int _consoleOutputBytes = 0;
  bool _reportedTimeExceeded = false;

  _ScriptExecutionBudget({
    required this.maxConsoleOutputBytes,
    required this.maxExecutionDuration,
  });

  String? checkTime() {
    if (_reportedTimeExceeded || _stopwatch.elapsed <= maxExecutionDuration) {
      return null;
    }
    _reportedTimeExceeded = true;
    return 'Script budget exceeded: execution is limited to ${maxExecutionDuration.inMilliseconds} ms per request.';
  }

  Duration get remainingExecutionDuration {
    final remaining = maxExecutionDuration - _stopwatch.elapsed;
    return remaining < const Duration(milliseconds: 1)
        ? const Duration(milliseconds: 1)
        : remaining;
  }

  bool get isTimeExceeded =>
      _reportedTimeExceeded || _stopwatch.elapsed > maxExecutionDuration;

  String? consumeConsoleMessage(String message) {
    final trimmedMessage =
        message.length > ScriptEngineService.maxConsoleMessageLength
        ? message.substring(0, ScriptEngineService.maxConsoleMessageLength)
        : message;
    final nextBytes = _consoleOutputBytes + utf8.encode(trimmedMessage).length;
    if (nextBytes > maxConsoleOutputBytes) {
      return null;
    }
    _consoleOutputBytes = nextBytes;
    return trimmedMessage;
  }
}

class _ProgramExecution {
  final Map<String, String> addedHeaders;
  final Set<String> removedHeaders;
  String? targetUrl;
  String? body;
  Map<String, dynamic>? terminalAction;
  String? actionType;
  bool stopProcessingScripts;
  bool stopAllScripts;
  String? errorMessage;

  _ProgramExecution({required this.addedHeaders, required this.removedHeaders})
    : targetUrl = null,
      body = null,
      terminalAction = null,
      actionType = null,
      stopProcessingScripts = false,
      stopAllScripts = false,
      errorMessage = null;
}
