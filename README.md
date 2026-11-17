# script_engine

公共 QuickJS 流量脚本引擎，提供单次执行、持久化会话、Promise 任务队列和执行预算。原生构建由 `flutter_native_build` 管理，配置位于 `hook/native-build.toml`。

## 构建和分发

在包根目录执行依赖解析和独立原生构建。

```sh
flutter pub get
dart run flutter_native_build native build --platform macos --linkage dynamic --macos-arch universal
```

双架构归档写入 `prebuild/macos/libforcesniff_quickjs.dylib.zip`。开发时可使用 `--macos-arch arm64` 或 `--macos-arch x64`，单架构归档写入 `prebuild/macos/<arch>/`。原有 `native/build_quickjs.sh --arch ...` 入口转发到上述命令。

应用通过标准 Native Assets Hook 读取与目标架构匹配的归档，登记 `src/third_party/session_native.g.dart`。macOS 最低版本为 11.0，当前分发平台为 macOS。

需要在测试或运行应用时按源码变化自动构建，可创建本地文件 `hook/native-build.local.toml`。

```toml
incremental = true
```

默认读取预编译产物。开启本地开关后使用统一的源码指纹缓存，源码变更触发重建。构建参数或工具链变更后执行独立构建命令。预编译归档和 `prebuild/.source-state/` 源码记录应一同保存。

QuickJS 2026-06-04 的编译源码和许可证位于 `native/quickjs/vendor/`，版本与来源记录见该目录的 `README.md`。构建直接使用包内源码。

## 绑定和验证

```sh
dart run tool/ffigen.dart
flutter test
```

绑定生成入口同时维护显式动态库绑定与 SDK Native Assets 绑定。生成文件位于 `lib/src/third_party/`。

## 运行时原生资产

默认通过 SDK 的 Native Assets 映射加载 QuickJS。ZIP 的解压、架构选择和打包由构建 hook 完成。

显式 `pathResolver` 和 `FORCESNIFF_QUICKJS_DYLIB` 支持已经解压的动态库。使用 ZIP 预编译缓存时，通过 `prebuild/` 和 hook 接入。运行时的 `defaultLibraryPaths()` 仅返回环境中显式配置的动态库路径。
