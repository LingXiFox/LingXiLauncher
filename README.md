# LingXi Launcher

[![CI](https://github.com/LingXiFox/LingXiLauncher/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/LingXiFox/LingXiLauncher/actions/workflows/ci.yml)

LingXi Launcher 是一个面向 **Minecraft: Java Edition** 的桌面启动器，当前实现为 **Rust + Tauri 2 + React + TypeScript**：core 不依赖 GUI，桌面端与 CLI 共用同一套安装、启动、账户、模组、整合包、世界备份、诊断与性能逻辑。

> Swift 实现已从工作树移除，旧源码保留在 git 历史与 `docs/archive/swift/`。已完成的代码与验证范围见 [docs/rust-migration/MIGRATION-STATUS.md](docs/rust-migration/MIGRATION-STATUS.md)。Vanilla/Fabric/NeoForge 已真实启动到渲染线程；Windows/Linux 安装包已由 CI 生成；进入世界/联机、Microsoft 真机登录、Windows/Linux 真机安装运行尚未验证，文档不会把未执行项标成通过。

## 功能

- **版本与安装**：Mojang 版本清单、原版安装、Fabric 与 NeoForge 安装，支持 official / mirror / auto / local-cache-only 下载策略。
- **实例**：创建、复制、删除、内存与 JVM 参数、独立游戏目录、实例级 Java。
- **启动**：Microsoft 正版与本地离线身份、启动计划预览、进程日志、退出码、游戏状态。
- **账户**：本地离线账户、Microsoft OAuth 2.0 + PKCE + loopback 登录、Keychain/凭据存储、可取消登录。
- **模组**：Modrinth 搜索、安装、启停、删除、更新检查，及本地 JAR 导入。
- **整合包**：`.mrpack` 检查与完整安装（原版 + Loader）、更新检查/预览/应用/中断恢复。
- **资源包与光影**：搜索、安装、导入、启停、删除、更新检查；Fabric 下的 Iris + Sodium 图形设置。
- **世界**：世界列表、目录格式备份、SHA-256 校验、分阶段恢复、删除。
- **诊断**：崩溃日志采集、13 类确定性规则、证据与根因、Markdown/JSON 导出、实例健康检查。
- **性能**：系统画像、基准测试、保守调优建议、应用与历史报告。
- **图形**：直接读写实例 `options.txt`，保留未知键并生成备份。

## 仓库结构

```
crates/
  launcher-core/       # 与 GUI/CLI 无关的领域逻辑
  launcher-auth/       # Microsoft OAuth / Xbox / Minecraft Services
  launcher-platform/   # 平台路径、凭据、系统服务
  launcher-cli/        # lingxi 命令行
apps/desktop/
  src/                 # React + TypeScript
  src-tauri/           # Tauri 2 命令层
docs/rust-migration/   # 基线、功能/UI/数据一致性与迁移状态
```

旧的 Swift 实现已从工作树移除，只保留在 git 历史与 `docs/archive/swift/`，不再参与构建、测试或发布。

## 开发

要求：Rust 1.82+、Node.js 20+、pnpm 9+。macOS 需要 Xcode Command Line Tools；Linux 需要 WebKitGTK 4.1 等 Tauri 依赖。

Rust 构建：

```bash
CARGO_HOME=$PWD/.cargo-home cargo check --workspace
CARGO_HOME=$PWD/.cargo-home cargo test --workspace
CARGO_HOME=$PWD/.cargo-home cargo clippy --workspace --all-targets -- -D warnings
```

前端：

```bash
cd Apps/desktop
pnpm install --frozen-lockfile
pnpm typecheck
pnpm build
```

桌面开发（需要 Tauri CLI）：

```bash
cd Apps/desktop
pnpm tauri dev
```

CLI：

```bash
CARGO_HOME=$PWD/.cargo-home cargo run -p launcher-cli -- --help
CARGO_HOME=$PWD/.cargo-home cargo run -p launcher-cli -- java list
CARGO_HOME=$PWD/.cargo-home cargo run -p launcher-cli -- instance list
```

## 数据目录

- 游戏根：官方 `.minecraft`，可用 `--root` 或 `LINGXI_GAME_ROOT` 覆盖。
- 数据根：平台应用数据目录，可用 `--data-root` 或 `LINGXI_DATA_ROOT` 覆盖。
- 实例：`<dataRoot>/instances/<id>/`，游戏目录为 `<dataRoot>/.minecraft/versions/<id>/`。
- 账户：`<dataRoot>/accounts/`；备份：`<dataRoot>/backups/<instance>/`。
- 设置：`<dataRoot>/settings.json`。

Rust 版可以直接读取 Swift 版的实例、模组、世界备份和旧整合包记录；旧整合包记录只读，Rust 新记录不保证旧 Swift 反向读取。细节见 [DATA-COMPATIBILITY.md](docs/rust-migration/DATA-COMPATIBILITY.md)。

## CLI

`lingxi` 提供 17 个顶层命令：`version`、`doctor`、`launch`、`account`、`java`、`instance`、`diagnose`、`install`、`mod`、`mrpack`、`modpack`、`graphics`、`shader`、`resourcepack`、`performance`、`world`、`verify`。

全局选项：`--root`、`--data-root`、`--json`、`--source`、`--mirror-config`。JSON 模式只向 stdout 输出一个最终对象，进度与错误走 stderr；退出码按错误类别区分（参数 2、数据 3、找不到 4、Java 5、网络 6、认证 7、IO 8、哈希 9、取消 130）。

## 验证状态

已在 macOS Apple Silicon 执行并通过：

- `cargo fmt --all -- --check`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo test --workspace`（launcher-core 41 项、launcher-auth 6 项）
- `cargo check -p lingxi-desktop`
- `pnpm typecheck` 与 `pnpm build`
- `cargo build --release -p lingxi-desktop --features custom-protocol`，启动后窗口正常渲染
- CLI `--help`、`version list/inspect --json`（1.7.10、1.20.1、1.21.11、26.3）、`doctor`、`launch --dry-run`、`diagnose`、`performance status/benchmark/tune`、`graphics status`、`mod search/install/enable/disable/remove`、`mrpack inspect`、`resourcepack/shader search`、`world list/backup/restore/delete` 冒烟
界面截图见 [UI 一致性文档](docs/rust-migration/UI-PARITY.md#实际界面截图)。Vanilla/Fabric/NeoForge 已真实启动到渲染线程；macOS `.app`/`.dmg` 已生成并验证，CI 已生成 Windows/Linux 安装包。尚未验证：进入世界/联机、Microsoft 真机登录、Windows/Linux 真机安装运行、Tauri WebView 进程内自动化。


## 文档

- [迁移基线](docs/rust-migration/BASELINE.md)
- [功能一致性](docs/rust-migration/FEATURE-PARITY.md)
- [UI 一致性](docs/rust-migration/UI-PARITY.md)
- [数据兼容性](docs/rust-migration/DATA-COMPATIBILITY.md)
- [迁移状态](docs/rust-migration/MIGRATION-STATUS.md)

## License

MIT，见 [LICENSE](LICENSE)。
