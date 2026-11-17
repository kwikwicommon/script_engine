import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'script_program.dart';
import 'script_traffic.dart';
import 'third_party/session.g.dart';
import 'third_party/session_native.g.dart' as bundled;

abstract interface class JavaScriptScriptRuntime {
  Future<QuickJsScriptResult> execute({
    required String source,
    required ScriptTraffic request,
    required ScriptMessagePhase phase,
    required Duration timeout,
  });
}

class ForceSniffJavaScriptRuntime implements JavaScriptScriptRuntime {
  const ForceSniffJavaScriptRuntime({
    this.ffiRuntime = const QuickJsFfiScriptRuntime(),
    this.cliRuntime = const QuickJsScriptRuntime(),
  });

  final QuickJsFfiScriptRuntime ffiRuntime;
  final JavaScriptScriptRuntime cliRuntime;

  @override
  Future<QuickJsScriptResult> execute({
    required String source,
    required ScriptTraffic request,
    required ScriptMessagePhase phase,
    required Duration timeout,
  }) {
    if (ffiRuntime.isAvailable) {
      return ffiRuntime.execute(
        source: source,
        request: request,
        phase: phase,
        timeout: timeout,
      );
    }
    return cliRuntime.execute(
      source: source,
      request: request,
      phase: phase,
      timeout: timeout,
    );
  }
}

typedef QuickJsFfiLibraryPathResolver = List<String> Function();

class QuickJsFfiScriptRuntime implements JavaScriptScriptRuntime {
  static const int defaultMemoryLimitBytes = 8 * 1024 * 1024;

  const QuickJsFfiScriptRuntime({
    this.pathResolver = defaultLibraryPaths,
    this.memoryLimitBytes = defaultMemoryLimitBytes,
  });

  final QuickJsFfiLibraryPathResolver pathResolver;
  final int memoryLimitBytes;

  bool get isAvailable => _resolveBindings() != null;

  @override
  Future<QuickJsScriptResult> execute({
    required String source,
    // Application-owned library code is kept separate from user source checks.
    String trustedPrelude = '',
    required ScriptTraffic request,
    required ScriptMessagePhase phase,
    required Duration timeout,
  }) async => executeSync(
    source: source,
    trustedPrelude: trustedPrelude,
    request: request,
    phase: phase,
    timeout: timeout,
  );

  QuickJsScriptResult executeSync({
    required String source,
    String trustedPrelude = '',
    required ScriptTraffic request,
    required ScriptMessagePhase phase,
    required Duration timeout,
  }) {
    final host = const QuickJsScriptRuntime();
    final validationError = host._validateSource(source);
    if (validationError != null) {
      return QuickJsScriptResult(errors: <String>[validationError]);
    }

    final bindings = _resolveBindings();
    if (bindings == null) {
      return const QuickJsScriptResult(
        errors: <String>[
          'QuickJS prebuild was not found. Package script_engine/prebuild/macos/libforcesniff_quickjs.dylib.zip or use the CLI fallback.',
        ],
      );
    }

    final runnerSource = host._buildRunner(
      '$trustedPrelude\n$source',
      request,
      phase,
    );
    final sourcePtr = runnerSource.toNativeUtf8();
    ffi.Pointer<ffi.Char> resultPtr = ffi.nullptr;
    try {
      resultPtr = bindings.execute(
        sourcePtr.cast<ffi.Char>(),
        timeout.inMilliseconds,
        memoryLimitBytes,
      );
      if (resultPtr == ffi.nullptr) {
        return const QuickJsScriptResult(
          errors: <String>['Bundled QuickJS runtime returned no result.'],
        );
      }
      final resultJson = resultPtr.cast<Utf8>().toDartString();
      return host._decodeResult(resultJson);
    } catch (error) {
      return QuickJsScriptResult(
        errors: <String>['Bundled QuickJS execution failed: $error'],
      );
    } finally {
      calloc.free(sourcePtr);
      if (resultPtr != ffi.nullptr) {
        bindings.free(resultPtr);
      }
    }
  }

  /// Opens a persistent context with the same memory and interruption limits.
  QuickJsSession openSession() {
    final bindings = _resolveBindings();
    if (bindings == null) {
      throw StateError('Bundled QuickJS runtime is unavailable.');
    }
    return QuickJsSession._(bindings, memoryLimitBytes);
  }

  String buildRunner(
    String source,
    ScriptTraffic request,
    ScriptMessagePhase phase,
  ) => const QuickJsScriptRuntime()._buildRunner(source, request, phase);

  String? validateSource(String source) =>
      const QuickJsScriptRuntime()._validateSource(source);

  _QuickJsApi? _resolveBindings() {
    if (Platform.isMacOS && pathResolver == defaultLibraryPaths) {
      try {
        bundled.ForceSniffQuickJsRuntimeManifestJSON();
        return _QuickJsApi.packaged();
      } catch (_) {
        // Explicit library overrides are resolved below.
      }
    }
    final library = _openLibrary();
    return library == null
        ? null
        : _QuickJsApi.dynamic(QuickJsSessionBindings(library));
  }

  ffi.DynamicLibrary? _openLibrary() {
    for (final path in pathResolver()) {
      try {
        final library = _openCandidate(path);
        if (library != null) return library;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// Returns an explicitly configured, unpacked native library override.
  static List<String> defaultLibraryPaths() {
    final path = Platform.environment['FORCESNIFF_QUICKJS_DYLIB']?.trim();
    return path == null || path.isEmpty ? const [] : [path];
  }

  static ffi.DynamicLibrary? _openCandidate(String path) {
    final file = File(path);
    if (path.contains('/') && !file.existsSync()) return null;
    return ffi.DynamicLibrary.open(path);
  }
}

class _QuickJsApi {
  _QuickJsApi.packaged()
    : execute = bundled.ForceSniffQuickJsExecute,
      free = bundled.ForceSniffQuickJsFree,
      create = bundled.ForceSniffQuickJsSessionCreate,
      evaluate = bundled.ForceSniffQuickJsSessionEval,
      destroy = bundled.ForceSniffQuickJsSessionDestroy;

  _QuickJsApi.dynamic(QuickJsSessionBindings bindings)
    : execute = bindings.ForceSniffQuickJsExecute,
      free = bindings.ForceSniffQuickJsFree,
      create = bindings.ForceSniffQuickJsSessionCreate,
      evaluate = bindings.ForceSniffQuickJsSessionEval,
      destroy = bindings.ForceSniffQuickJsSessionDestroy;

  final ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char>, int, int) execute;
  final void Function(ffi.Pointer<ffi.Char>) free;
  final ffi.Pointer<ffi.Void> Function(int) create;
  final ffi.Pointer<ffi.Char> Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Char>,
    int,
  )
  evaluate;
  final void Function(ffi.Pointer<ffi.Void>) destroy;
}

class QuickJsScriptRuntime implements JavaScriptScriptRuntime {
  const QuickJsScriptRuntime({this.executablePath});

  final String? executablePath;

  @override
  Future<QuickJsScriptResult> execute({
    required String source,
    required ScriptTraffic request,
    required ScriptMessagePhase phase,
    required Duration timeout,
  }) async {
    // The qjs CLI registers std/os module loaders. Source filtering cannot
    // isolate dynamic code or prevent host filesystem and process access.
    // Only the embedded runtime without host modules may run traffic scripts.
    return const QuickJsScriptResult(
      errors: <String>[
        'QuickJS CLI execution is disabled for untrusted traffic scripts. '
            'Install the bundled QuickJS FFI runtime.',
      ],
    );
  }

  String? _validateSource(String source) {
    if (RegExp(r'\bimport\b').hasMatch(source)) {
      return 'JavaScript imports are not supported in ForceSniff scripts.';
    }
    if (RegExp(r'\b(?:eval|Function)\s*\(|(?<![\w$.])load\s*\(')
        .hasMatch(source)) {
      return 'Dynamic JavaScript loading is not supported in ForceSniff scripts.';
    }
    return null;
  }

  String _buildRunner(
    String source,
    ScriptTraffic request,
    ScriptMessagePhase phase,
  ) {
    final contextJson = jsonEncode(_buildContext(request, phase));
    final normalizedSource = _normalizeModuleSource(source);
    return '''
const __input = $contextJson;
const __logs = [];
const __unhandledRejections = new Map();
globalThis.__forceTrackRejection = (promise, reason, handled) => {
  if (handled) __unhandledRejections.delete(promise);
  else __unhandledRejections.set(promise, String(reason && reason.message ? reason.message : reason));
};
const __mutations = { headers: {}, removeHeaders: [], url: null, body: null };

function __headerGet(headers, name) {
  const target = String(name).toLowerCase();
  for (const key of Object.keys(headers || {})) {
    if (key.toLowerCase() === target) return headers[key];
  }
  return undefined;
}

function __bodyToText(value) {
  if (value === undefined || value === null) return "";
  if (typeof value === "string") return value;
  return JSON.stringify(value);
}

const ctx = {
  phase: __input.phase,
  request: {
    id: __input.request.id,
    method: __input.request.method,
    url: __input.request.url,
    host: __input.request.host,
    path: __input.request.path,
    query: __input.request.query,
    headers: __input.request.headers,
    bodyText: __input.request.bodyText,
    header(name) { return __headerGet(__input.request.headers, name); },
    setHeader(name, value) { __mutations.headers[String(name)] = String(value); },
    removeHeader(name) { __mutations.removeHeaders.push(String(name)); },
    setUrl(value) { __mutations.url = String(value); },
    setBody(value) { __mutations.body = __bodyToText(value); },
  },
  response: {
    status: __input.response.status,
    headers: __input.response.headers,
    bodyText: __input.response.bodyText,
    header(name) { return __headerGet(__input.response.headers, name); },
  },
  log(message) { __logs.push(String(message)); },
  continue() { return { type: "continue" }; },
  modifyRequest(patch) { return Object.assign({ type: "modify" }, patch || {}); },
  mock(statusCode, body, headers) {
    return {
      type: "mock",
      statusCode: Number(statusCode),
      headers: headers || { "Content-Type": "application/json; charset=utf-8" },
      body: __bodyToText(body),
    };
  },
  drop() { return { type: "drop" }; },
};

const console = {
  log(...items) { __logs.push(items.map((item) => __bodyToText(item)).join(" ")); },
  warn(...items) { __logs.push(items.map((item) => __bodyToText(item)).join(" ")); },
  error(...items) { __logs.push(items.map((item) => __bodyToText(item)).join(" ")); },
};

function __normalizeAction(action) {
  if (__mutations.url || __mutations.body !== null ||
      Object.keys(__mutations.headers).length > 0 ||
      __mutations.removeHeaders.length > 0) {
    return {
      type: "modify",
      url: __mutations.url || undefined,
      body: __mutations.body === null ? undefined : __mutations.body,
      headers: __mutations.headers,
      removeHeaders: __mutations.removeHeaders,
    };
  }
  if (action && typeof action === "object") return action;
  return { type: "continue" };
}

try {
$normalizedSource
  const __result = typeof handle === "function" ? handle(ctx) : undefined;
  globalThis.__forceResult = () => ({ action: __normalizeAction(__result), logs: __logs, errors: [...__unhandledRejections.values()] });
  print(JSON.stringify(__forceResult()));
} catch (error) {
  print(JSON.stringify({ errors: [[String(error && error.message ? error.message : error), String(error && error.stack ? error.stack : "")].filter(Boolean).join(" | ")] }));
}
''';
  }

  String _normalizeModuleSource(String source) {
    return source
        .replaceFirst(
          RegExp(r'\bexport\s+default\s+function\s+handle\s*\('),
          'function handle(',
        )
        .replaceFirst(
          RegExp(r'\bexport\s+default\s+function\s*\('),
          'function handle(',
        )
        .replaceFirst(RegExp(r'\bexport\s+default\s+'), 'const handle = ');
  }

  Map<String, dynamic> _buildContext(
    ScriptTraffic request,
    ScriptMessagePhase phase,
  ) {
    return <String, dynamic>{
      'phase': phase.name,
      'request': <String, dynamic>{
        'id': request.id,
        'method': request.method,
        'url': request.url,
        'host': request.host,
        'path': request.path,
        'query': request.query,
        'headers': request.requestHeaders,
        'bodyText': request.requestBodyText,
      },
      'response': <String, dynamic>{
        'status': request.statusCode,
        'headers': request.responseHeaders,
        'bodyText': request.responseBodyText,
      },
    };
  }

  QuickJsScriptResult _decodeResult(String stdout) {
    final lines = stdout
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty) {
      return const QuickJsScriptResult();
    }
    try {
      final decoded = jsonDecode(lines.last);
      if (decoded is! Map) {
        return const QuickJsScriptResult(
          errors: <String>['QuickJS returned a non-object result.'],
        );
      }
      final map = Map<String, dynamic>.from(decoded);
      return QuickJsScriptResult(
        action: map['action'] is Map
            ? Map<String, dynamic>.from(map['action'] as Map)
            : null,
        logs: ((map['logs'] as List?) ?? const <Object?>[])
            .map((item) => item.toString())
            .toList(growable: false),
        errors: ((map['errors'] as List?) ?? const <Object?>[])
            .map((item) => item.toString())
            .toList(growable: false),
      );
    } catch (error) {
      return QuickJsScriptResult(
        errors: <String>['QuickJS returned invalid JSON: $error'],
      );
    }
  }
}

class QuickJsScriptResult {
  const QuickJsScriptResult({
    this.action,
    this.logs = const <String>[],
    this.errors = const <String>[],
  });

  final Map<String, dynamic>? action;
  final List<String> logs;
  final List<String> errors;
}

/// Native allocations remain owned by this session and are released by close.
class QuickJsSession {
  QuickJsSession._(this._bindings, int memoryLimitBytes) {
    _handle = _bindings.create(memoryLimitBytes);
    if (_handle == ffi.nullptr) {
      throw StateError('QuickJS session allocation failed.');
    }
  }

  final _QuickJsApi _bindings;
  late ffi.Pointer<ffi.Void> _handle;

  Map<String, dynamic> evaluate(String source, Duration timeout) {
    if (_handle == ffi.nullptr) throw StateError('QuickJS session is closed.');
    final input = source.toNativeUtf8();
    ffi.Pointer<Utf8> output = ffi.nullptr;
    try {
      output = _bindings
          .evaluate(_handle, input.cast(), timeout.inMilliseconds)
          .cast<Utf8>();
      if (output == ffi.nullptr) {
        throw StateError('QuickJS returned no result.');
      }
      return Map<String, dynamic>.from(
        jsonDecode(output.toDartString()) as Map,
      );
    } finally {
      calloc.free(input);
      if (output != ffi.nullptr) _bindings.free(output.cast());
    }
  }

  void close() {
    if (_handle == ffi.nullptr) return;
    _bindings.destroy(_handle);
    _handle = ffi.nullptr;
  }
}
