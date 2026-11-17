import 'dart:io';

import 'package:flutter_native_build/flutter_native_build.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:script_engine/script_engine.dart';

void main() {
  test(
    'runtime sources contain no prebuild unpacking or package discovery',
    () {
      final source = File('lib/src/quick_js_script_runtime.dart')
          .readAsStringSync();
      expect(source, isNot(contains('_extractPrebuild')));
      expect(source, isNot(contains('package_config.json')));
      expect(source, isNot(contains("Process.runSync('unzip'")));
    },
  );

  test('default paths contain only an explicit environment override', () {
    final path = Platform.environment['FORCESNIFF_QUICKJS_DYLIB']?.trim();
    expect(
      QuickJsFfiScriptRuntime.defaultLibraryPaths(),
      path == null || path.isEmpty ? <String>[] : [path],
    );
  });

  test('an explicit resolver controls its library selection', () {
    final runtime = QuickJsFfiScriptRuntime(pathResolver: () => const []);
    expect(runtime.isAvailable, isFalse);
    expect(runtime.openSession, throwsStateError);
  });

  test(
    'SDK asset and explicit unpacked libraries own independent sessions',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'quickjs-native-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final artifact = await resolvePrebuildArtifact(
        artifact: File('prebuild/macos/libforcesniff_quickjs.dylib'),
        extractionDirectory: temporary,
        compressed: true,
      );
      expect(artifact, isNotNull);
      final runtimes = [
        const QuickJsFfiScriptRuntime(),
        QuickJsFfiScriptRuntime(pathResolver: () => [artifact!.file.path]),
      ];
      for (final runtime in runtimes) {
        expect(runtime.isAvailable, isTrue);
        final session = runtime.openSession();
        expect(
          session.evaluate(
            'globalThis.nativeAssetProbe = 42;',
            const Duration(seconds: 1),
          ),
          isA<Map>(),
        );
        session.close();
        session.close();
        expect(
          () => session.evaluate('1', const Duration(seconds: 1)),
          throwsStateError,
        );
      }
    },
    skip: !Platform.isMacOS,
  );
}
