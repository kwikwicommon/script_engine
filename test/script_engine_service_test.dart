import 'package:flutter_test/flutter_test.dart';
import 'package:script_engine/script_engine.dart';

void main() {
  group('ScriptEngineService budgets', () {
    test('rejects oversized JavaScript source', () async {
      final service = ScriptEngineService(
        javaScriptRuntime: const _FakeQuickJsRuntime(
          result: QuickJsScriptResult(),
        ),
      );
      final report = await service.evaluateRequestScripts(
        _request(),
        programs: <ScriptProgram>[
          _javaScriptProgram(
            id: 'oversized',
            source: _text(ScriptEngineService.maxSourceLength + 1),
          ),
        ],
      );

      expect(report.hasErrors, isTrue);
      expect(report.errors.single, contains('source limit'));
    });

    test('limits script count per request', () async {
      final service = ScriptEngineService(
        javaScriptRuntime: const _FakeQuickJsRuntime(
          result: QuickJsScriptResult(),
        ),
      );
      final programs = <ScriptProgram>[
        for (
          var index = 0;
          index <= ScriptEngineService.maxProgramsPerRequest;
          index++
        )
          _javaScriptProgram(
            id: 'extra-$index',
            source:
                'export default function handle(ctx) { return ctx.continue(); }',
          ),
      ];

      final report = await service.evaluateRequestScripts(
        _request(),
        programs: programs,
      );

      expect(
        report.errors.any(
          (error) => error.contains(
            'only ${ScriptEngineService.maxProgramsPerRequest} scripts',
          ),
        ),
        isTrue,
      );
    });

    test('limits console output per request', () async {
      final logLine = _text(ScriptEngineService.maxConsoleMessageLength);
      final service = ScriptEngineService(
        javaScriptRuntime: _FakeQuickJsRuntime(
          result: QuickJsScriptResult(
            logs: <String>[for (var index = 0; index < 9; index++) logLine],
          ),
        ),
      );
      final report = await service.evaluateRequestScripts(
        _request(),
        programs: <ScriptProgram>[
          _javaScriptProgram(
            id: 'console',
            source: 'export default function handle(ctx) { ctx.log("x"); }',
          ),
        ],
      );

      expect(
        report.errors.any((error) => error.contains('console output')),
        isTrue,
        reason: report.errors.join('\n'),
      );
    });

    test(
      'reports legacy FlowScript DSL migration instead of executing it',
      () async {
        final service = ScriptEngineService();
        final report = await service.evaluateRequestScripts(
          _request(),
          programs: <ScriptProgram>[
            _program(
              id: 'legacy',
              source: '''
when url contains /api
mock 200 legacy
''',
            ),
          ],
        );

        expect(report.hasAction, isFalse);
        expect(report.hasMatches, isFalse);
        expect(report.errors.single, contains('no longer executed'));
      },
    );

    test(
      'keeps response JavaScript preview mutation behavior aligned with execution',
      () async {
        final service = ScriptEngineService(
          javaScriptRuntime: _FakeQuickJsRuntime(
            result: const QuickJsScriptResult(
              action: <String, dynamic>{
                'type': 'mock',
                'statusCode': 200,
                'body': 'response-preview',
              },
            ),
          ),
        );
        final program = _javaScriptProgram(
          id: 'response-preview',
          source:
              'export default function handle(ctx) { return ctx.mock(200, "response-preview"); }',
        ).copyWith(phase: ScriptMessagePhase.response);
        service.loadPrograms(<ScriptProgram>[program]);

        final preview = await service.previewProgram(
          'response-preview',
          _request(),
          phase: ScriptMessagePhase.response,
        );
        final execution = await service.evaluateResponseScripts(
          _request(),
          programs: <ScriptProgram>[program],
        );

        expect(preview.hasAction, isFalse);
        expect(execution.hasAction, isFalse);
      },
    );

    test('filters invalid mutation actions from JavaScript output', () async {
      final service = ScriptEngineService(
        javaScriptRuntime: _FakeQuickJsRuntime(
          result: const QuickJsScriptResult(
            action: <String, dynamic>{
              'type': 'modify',
              'headers': <String, String>{'Bad Header': 'value'},
            },
          ),
        ),
      );
      final report = await service.evaluateRequestScripts(
        _request(),
        programs: <ScriptProgram>[
          _javaScriptProgram(
            id: 'invalid-header',
            source:
                'export default function handle(ctx) { return ctx.continue(); }',
          ),
        ],
      );

      expect(report.hasAction, isFalse);
      expect(report.errors, isNotEmpty);
      expect(
        report.errors.any((error) => error.contains('invalid header name')),
        isTrue,
      );
    });

    test(
      'executes JavaScript programs through the QuickJS runtime seam',
      () async {
        final service = ScriptEngineService(
          javaScriptRuntime: _FakeQuickJsRuntime(
            result: const QuickJsScriptResult(
              action: <String, dynamic>{
                'type': 'modify',
                'headers': <String, String>{'X-Debug': '1'},
                'url': 'https://example.com/next',
              },
              logs: <String>['js log'],
            ),
          ),
        );
        final report = await service.evaluateRequestScripts(
          _request(),
          programs: <ScriptProgram>[
            _program(
              id: 'javascript',
              source:
                  'export default function handle(ctx) { return ctx.continue(); }',
            ).copyWith(language: ScriptProgramLanguage.javascript),
          ],
        );

        expect(report.hasAction, isTrue);
        expect(report.action?['type'], 'modify');
        expect(report.action?['headers'], <String, String>{'X-Debug': '1'});
        expect(report.action?['url'], 'https://example.com/next');
      },
    );

    test('rejects CLI execution even when an executable is configured', () async {
      final result = await const QuickJsScriptRuntime(executablePath: '/bin/sh')
          .execute(
            source:
                "import('os').then(os => os.exec(['touch', '/tmp/untrusted']))",
            request: _request(),
            phase: ScriptMessagePhase.request,
            timeout: const Duration(milliseconds: 20),
          );
      expect(result.action, isNull);
      expect(result.errors.single, contains('CLI execution is disabled'));
    });

    test('executes JavaScript with the bundled QuickJS FFI runtime', () async {
      final runtime = QuickJsFfiScriptRuntime();
      if (!runtime.isAvailable) {
        markTestSkipped('bundled QuickJS FFI runtime is not built.');
        return;
      }

      final result = await runtime.execute(
        source: '''
export default function handle(ctx) {
  ctx.log(`ffi=\${ctx.request.host}`);
  return ctx.mock(204, "ffi-ok");
}
''',
        request: _request(),
        phase: ScriptMessagePhase.request,
        timeout: const Duration(seconds: 2),
      );

      expect(result.errors, isEmpty);
      expect(result.logs.single, 'ffi=example.com');
      expect(result.action?['type'], 'mock');
      expect(result.action?['statusCode'], 204);
      expect(result.action?['body'], 'ffi-ok');
    });

    test('passes memory limits to the bundled QuickJS FFI runtime', () async {
      final runtime = QuickJsFfiScriptRuntime(memoryLimitBytes: 1024);
      if (!runtime.isAvailable) {
        markTestSkipped('bundled QuickJS FFI runtime is not built.');
        return;
      }

      final result = await runtime.execute(
        source: '''
export default function handle(ctx) {
  const values = [];
  for (let index = 0; index < 100000; index += 1) values.push(`\${index}`.repeat(32));
  return ctx.continue();
}
''',
        request: _request(),
        phase: ScriptMessagePhase.request,
        timeout: const Duration(seconds: 2),
      );

      expect(result.errors, isNotEmpty);
    });

    test('keeps response JavaScript read-only while recording logs', () async {
      final service = ScriptEngineService(
        javaScriptRuntime: _FakeQuickJsRuntime(
          result: const QuickJsScriptResult(
            action: <String, dynamic>{
              'type': 'mock',
              'statusCode': 599,
              'body': 'blocked',
            },
            logs: <String>['response observed'],
          ),
        ),
      );
      final program =
          _program(
            id: 'response-js',
            source:
                'export default function handle(ctx) { return ctx.mock(599, "blocked"); }',
          ).copyWith(
            language: ScriptProgramLanguage.javascript,
            phase: ScriptMessagePhase.response,
          );
      service.loadPrograms(<ScriptProgram>[program]);

      final report = await service.executeResponseScripts(_request());

      expect(report.hasAction, isFalse);
      expect(service.consoleEntries.single.message, 'response observed');
      expect(service.consoleEntries.single.phase, ScriptMessagePhase.response);
    });
  });
}

ScriptTraffic _request({String? body}) {
  return ScriptTraffic(
    id: 'script-budget-request',
    method: 'GET',
    url: 'https://example.com/api',
    host: 'example.com',
    path: '/api',
    requestBodyText: body ?? '',
  );
}

ScriptProgram _javaScriptProgram({required String id, required String source}) {
  return _program(
    id: id,
    source: source,
  ).copyWith(language: ScriptProgramLanguage.javascript);
}

ScriptProgram _program({required String id, required String source}) {
  return ScriptProgram(
    id: id,
    name: id,
    source: source,
    enabled: true,
    language: ScriptProgramLanguage.legacyFlowScript,
    phase: ScriptMessagePhase.request,
    priority: 0,
    version: ScriptProgram.currentVersion,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );
}

String _text(int length) => List<String>.filled(length, 'x').join();

class _FakeQuickJsRuntime implements JavaScriptScriptRuntime {
  const _FakeQuickJsRuntime({required this.result});

  final QuickJsScriptResult result;

  @override
  Future<QuickJsScriptResult> execute({
    required String source,
    required ScriptTraffic request,
    required ScriptMessagePhase phase,
    required Duration timeout,
  }) async => result;
}
