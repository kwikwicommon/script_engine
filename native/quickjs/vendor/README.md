# QuickJS 源码

本目录包含构建流量脚本运行库所需的 QuickJS 2026-06-04 C 源码和头文件，保留上游文件内容与版权声明。许可证见 `LICENSE`，版本见 `VERSION`。

上游归档为 [quickjs-2026-06-04.tar.xz](https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz)，SHA-256 为 `b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a`。引入时已校验归档摘要。

需要编译的文件由包根目录 `hook/native-build.toml` 的 `[c] sources` 声明。版本升级时同步更新本目录、`VERSION`、构建配置中的 `CONFIG_VERSION`、来源记录和预编译归档。
