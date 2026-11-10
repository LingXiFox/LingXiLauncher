# LingXiLauncher Rust 迁移验收报告

- 基线分支：`rewrite/rust`
- 基线提交：`13c467c`（Rust/Tauri 完整实现，Swift 已移除）
- 实现提交：`ae9b1a9` `fix: download loader dependencies and validate real launches`
- 文档与 GUI 冒烟：`4195ca9` `test: add GUI smoke and finalize release verification`
- 安装包修复：`605a307` `fix: declare bundle icons for Linux and Windows installers`
- Swift 历史备份：tag `swift-implementation-before-removal` → `6aae3fd`
- 验收环境：macOS Apple Silicon，Java 27/26/21/17/8，Node 26，pnpm，Rust stable
- 状态日期：2026-11-10

本报告只记录实际执行过的验证。没有执行的项目明确标为“未验证”，不以构建成功代替功能通过。

## 1. 交付概览

| 项 | 结果 |
| --- | --- |
| 技术栈 | Rust + Tauri 2 + React 19 + TypeScript |
| Core 依赖 | 不依赖 Tauri、React、WebView；GUI 与 CLI 共用 `launcher-core` |
| 代码规模 | Rust 22,147 行；前端 TS/TSX/CSS 12,266 行 |
| Tauri 命令 | 注册 75 个；前端实际调用 61 个，全部已注册 |
| CLI | 17 个顶层命令，clap 重建 |
| Rust 测试 | 47 项通过（core 41、auth 6） |
| 前端检查 | typecheck、build、GUI 冒烟通过 |
| 真实启动 | Vanilla / Fabric / NeoForge 均到渲染线程 |
| macOS 产物 | `.app` 可启动；`.dmg` 已生成并通过 `hdiutil verify` |
| Windows/Linux | CI 已产出 NSIS/MSI、AppImage/deb/rpm；未在真机安装运行 |
| Swift 运行时代码 | 已移除，仅保留 git tag 与 `docs/archive/swift` 文档 |

## 2. 模块清单

| 模块 | 职责 | 关键文件 |
| --- | --- | --- |
| `launcher-core::layout` | 游戏根/数据根/实例/日志/缓存路径 | `crates/launcher-core/src/layout.rs` |
| `manifest` / `version` | Mojang 版本清单、版本元数据、继承解析 | `manifest.rs`、`version.rs`、`models/version.rs` |
| `install` | 原版下载、校验、natives、加载器安装、进度与取消 | `install/vanilla.rs`、`install/loader.rs`、`install/downloader.rs` |
| `launch` | 参数构建、身份、Java 选择、进程与日志、退出码 | `launch.rs`、`models/launch.rs` |
| `java` | 运行时发现、检查、托管安装 | `java.rs` |
| `mods` / `modrinth` | 本地模组、启停、更新、Modrinth 搜索与下载 | `mods.rs`、`modrinth.rs` |
| `modpack` | mrpack 检查/安装/更新、旧整合包只读兼容 | `modpack.rs` |
| `worlds` | 世界列表、目录备份、校验恢复、删除 | `worlds.rs` |
| `resourcepacks` / `shaders` | 资源包与光影导入、启停、删除 | `resourcepacks.rs`、`shaders.rs` |
| `performance` | 系统画像、建议、基准、旧版基准读取 | `performance.rs` |
| `diagnostics` | 崩溃日志分析、根因、Markdown/JSON 导出 | `diagnostics.rs` |
| `graphics` | `options.txt` 读写、校验、备份 | `graphics.rs` |
| `launcher-auth` | Microsoft PKCE + loopback + 可取消登录 + 刷新 | `service.rs`、`loopback.rs` |
| `launcher-platform` | 钥匙串/DPAPI/Secret Service、系统服务 | `secrets.rs`、`lib.rs` |
| `launcher-cli` | 17 个顶层命令，JSON/人类输出、退出码 | `crates/launcher-cli/src/commands/` |
| `lingxi-desktop` | Tauri 命令、状态、事件、窗口 | `Apps/desktop/src-tauri/src/commands/` |
| React 前端 | 6 个页面、10 类弹窗、主题与组件 | `Apps/desktop/src/` |

## 3. 10 项发布级验收

| # | 验收项 | 状态 | 证据与说明 |
| --- | --- | --- | --- |
| 1 | CI 路径大小写修复并跑绿 | 通过 | 根 `Cargo.toml` member 已改为 `Apps/desktop/src-tauri`（`1208718`）。run `42762969758` 与 `42763836261` 的 Rust、CLI、macOS 15、Ubuntu、Windows 五个 job 全部 success |
| 2 | Linux 凭据安全、Windows DPAPI、macOS Keychain 旧凭据兼容 | 部分 | 代码路径全部实现并复核（见 §5）；本机只验证 macOS 构建，未在 Windows/Linux 真机读写凭据，未触碰真实账户 |
| 3 | Swift 设置/性能历史迁移 | 部分 | 设置只在 `settings.json` 缺失时读 `defaults` 域；旧性能报告只读展示。代码复核完成，未用真实用户偏好域做端到端测试 |
| 4 | GUI 离线启动与 Swift 安全策略一致 | 通过 | GUI 仅允许 Microsoft 启动；本地账户 disabled 并提示 CLI。与 Swift 策略一致 |
| 5 | Windows 物理内存与平台功能 | 部分 | 三级 PowerShell/wmic/CIM 读取已实现；CI 交叉编译通过；无 Windows 真机运行 |
| 6 | 统一 Rust/Tauri/前端/安装包版本 | 通过 | Cargo workspace、Tauri bundle、CLI 均为 0.10.0 |
| 7 | 隔离目录真实安装启动 Vanilla/Fabric/NeoForge | 通过（到渲染线程） | 三种版本均安装成功并启动到 `Created atlas`；未进入世界/联机 |
| 8 | Microsoft 正版登录与刷新令牌 | 未验证 | 需要真实账号与浏览器授权，本轮未执行 |
| 9 | 新旧截图视觉对比 + GUI 自动化 | 部分 | 首页新旧并排见 `VISUAL-COMPARISON.md`；19 张新 UI 截图；`pnpm test:gui` 通过。旧版只能截首页；自动化是 Chrome CDP，不是 WebView 进程内 |
| 10 | macOS .app/.dmg 与 CI Windows/Linux 安装包 | 通过（测试构建） | macOS 本地 `.dmg` ad-hoc 签名并通过 `hdiutil verify`；CI run `42763846132` 三平台打包全部 success，产出 `.dmg`、MSI/NSIS、AppImage/deb/rpm，均未正式签名 |
| 11 | 更新验收报告，列真实通过/失败/未验证 | 通过 | 本报告与 `MIGRATION-STATUS.md` |

## 4. 构建、测试与质量门禁

本机实际执行：

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cd Apps/desktop && pnpm typecheck && pnpm build && pnpm test:gui
```

结果：
- fmt：通过。
- clippy：通过，`-D warnings` 无告警。
- test：47 项通过（launcher-core 41、launcher-auth 6）。
- typecheck：通过。
- build：通过；Vite 78 modules，JS 284 kB / gzip 86 kB，CSS 80 kB / gzip 14 kB。
- GUI 冒烟：通过；覆盖启动 shell、导航、实例详情、模组/图形/安装弹窗、设置校验、账户页、日志页。
- Release：`cargo build --release -p lingxi-desktop --features custom-protocol` 通过；未启用 custom-protocol 会白屏，这是 Tauri 2 的 devUrl 行为。
- 打包：`pnpm exec tauri build --bundles app`；`.app` 成功，`.dmg` 由 `diskutil image create` 生成并通过 `hdiutil verify`。
- 三平台安装包：release validation run `42763846132` 的 macOS ARM64、Windows x64、Linux x64 全部 success；产物已汇总到 `target/release/bundle/ci/`。

## 5. 平台与凭证实现

### macOS
- 当前钥匙串：service `LingXiLauncher`，account `microsoft-refresh-token:v1:<uuid>`。
- 旧 Swift 兼容：service `com.lingxifox.LingXiLauncher.microsoft`、account 为小写 UUID；读到旧值后写新 service 并删旧项。
- 设置迁移：`settings.json` 不存在时读 `/usr/bin/defaults read com.lingxifox.LingXiLauncher lingxi.javaPath|source|mirrorConfigPath|defaultMemoryMiB|appearance`；损坏文件保留不覆盖。

### Windows
- DPAPI entropy `LingXiLauncher`；密文 `credentials/<uuid>.bin`，原子替换。
- 兼容旧 Rust 无 entropy 文件与 `%APPDATA%/LingXiLauncher/credentials/<uuid>.bin`。
- 物理内存：PowerShell `Get-CimInstance Win32_ComputerSystem` → `wmic` → `Win32_OperatingSystem`。

### Linux
- `secret-tool` + Secret Service；无 provider 时明确报错，不静默落明文。
- 仅 `LINGXI_ALLOW_PLAINTEXT_SECRETS=1` 允许 0600 文件回退，用于无桌面/CI。

### 安全边界
- 未读取、导出或提交任何真实 refresh token、账户数据库或用户世界。
- 验收使用隔离目录与本地测试账户；真实账户未参与。
- macOS 本地安装包为 ad-hoc 签名；CI 的 macOS/Windows 安装包未签名。均不可作为公开发行包，Developer ID 与公证未执行。

## 6. 真实安装与启动记录

隔离目录：`.tmp/accept/data`、`.tmp/accept/game`。

| 版本 | 安装结果 | 启动结果 |
| --- | --- | --- |
| Vanilla 1.21.11 | 4665 文件，551,983,062 字节，缺失 0，complete | Java 21，`Created atlas`，随后主动终止（143） |
| Fabric 0.20.1 + 1.21.11 | 4673 文件，Fabric 依赖缓存命中 | Java 21，`Created atlas` |
| NeoForge 21.11.48 + 1.21.11 | installer 成功，classpath 98，缺失 0 | Java 21，`Created atlas` |

修复记录：
- Fabric 首次启动缺 8 个 Maven 依赖：`LoaderInstaller` 写 profile 后改为调用 `VanillaInstaller.install` 下载合并依赖。
- NeoForge `releaseTime` 无时区：增加 RFC3339 与 `%Y-%m-%dT%H:%M:%S%.f` 双解析。
- NeoForge installer 要求 `launcher_profiles.json`：安装前写入空 profiles。
- Fabric loader 元数据是嵌套 `{loader:{version,stable}}`：已修正解析。
- 原版 `plan()` 缺版本元数据：先 `metadata_by_id` 再解析。

## 7. UI 一致性

页面：首页、游戏实例、版本下载、账户管理、运行日志、设置。

弹窗：安装向导、模组、整合包导入、整合包更新、图形、性能、资源包、光影、实例工具（实例/世界/诊断）、崩溃报告。

- 19 张真实 Tauri 窗口截图在 `docs/rust-migration/screenshots/`。
- 首页新旧并排对比在 `VISUAL-COMPARISON.md`。
- 保留 SwiftUI 的深/浅主题、侧栏分组、面包屑、卡片、状态胶囊、中文文案与 Fox 标识。
- 增量：实例详情整合包行、整合包更新入口、图形设置 `options.txt` 编辑、性能页旧版基准、诊断页真实检查。
- 未验证：所有弹窗在真实 IPC 下的完整交互、文件选择器、系统钥匙串弹窗。

## 8. 数据兼容

- `instance.json`、实例目录、模组元数据按 Swift 结构读取。
- 旧 `modpack.json` 只读，不在读取时改写，避免误更新覆盖。
- 世界备份使用 Swift 目录格式（`manifest.json` + `world/`），兼容旧 zip；恢复校验实例归属、SHA-256 与文件大小。
- 游戏日志目录统一为实例游戏目录下 `logs`。
- 设置迁移只在没有 Rust `settings.json` 时执行，避免覆盖新配置。
- 详细边界见 `DATA-COMPATIBILITY.md`。

## 9. 性能对比

未做新旧版本运行性能对比。原因：本轮只验证到主菜单渲染线程，没有进入世界，也没有统一场景的帧率/内存采样。现有 `BenchmarkReport` 是合成 CPU/内存基准，不是新旧版本对比数据，不能替代性能结论。

## 10. Swift 清理

- Swift 源码、测试、旧 app、`Package.swift`、旧脚本已从工作树移除（提交 `aceecae`，223 个文件）。
- 运行时代码与构建不再依赖 Swift。
- 历史实现保留在 tag `swift-implementation-before-removal`（`6aae3fd`）。
- `docs/archive/swift` 保留旧开发文档与 Apps README，仅作参考。

## 11. 已知问题与未验证项

1. Microsoft 真实登录、刷新令牌轮换、退出登录未执行。
2. 游戏未进入世界、未联机、未做长时间稳定性与性能对比。
3. Windows/Linux 未在真机安装运行，也未做 WebView 验证；CI 只证明安装包可生成。
4. macOS 产物未做 Developer ID 签名与公证，不能作为公开发行包。
5. GUI 自动化是 Chrome CDP 的前端冒烟，不覆盖真实 Tauri IPC、文件对话框、钥匙串。
6. macOS CI 的 `macos-14` job 启动即 cancelled；切到 `macos-15` 后已全部通过。
7. 旧 Swift 版只能截首页，视觉对比不覆盖全部页面。
8. 资源包/光影的 Modrinth 真实下载未在受限网络下做完整性验证。
9. 旧版 Swift 设置迁移未用真实 `defaults` 域做端到端测试。
10. Windows DPAPI 与 Linux Secret Service 只做代码复核与交叉编译，未做真机凭据读写。

## 12. 复现与产物

```bash
# 质量门禁
CARGO_HOME=$PWD/.cargo-home cargo fmt --all -- --check
CARGO_HOME=$PWD/.cargo-home cargo clippy --workspace --all-targets -- -D warnings
CARGO_HOME=$PWD/.cargo-home cargo test --workspace
cd Apps/desktop && pnpm typecheck && pnpm build && pnpm test:gui

# Release 与 macOS 打包
cd ../..
CARGO_HOME=$PWD/.cargo-home cargo build --release -p lingxi-desktop --features custom-protocol
cd Apps/desktop
pnpm exec tauri build --bundles app,dmg

# CLI
cargo run -q -p launcher-cli -- --help
```

产物：
- `target/release/lingxi-desktop`
- `target/release/bundle/macos/LingXi Launcher.app`
- `target/release/bundle/dmg/LingXi Launcher_0.10.0_aarch64.dmg`
  SHA-256 `f3459759511d6c5b88125cc3d7186c7d98adea72f48770004f98cadcc49f4844`
- `LingXi Launcher.app/Contents/MacOS/lingxi-desktop`
  SHA-256 `c8bfe2833f21e1f7df08cb5e4f9f19c0c015927fd11311e3f0f8a4ffa196be14`
- 三平台 CI 安装包（`target/release/bundle/ci/`）：
  - `windows/LingXi Launcher_0.10.0_x64-setup.exe`：`8080b712ad1ad2cc695f8f1366dfb0a58c40c557cc637ac40c8a267de5ba3eca`
  - `windows/LingXi Launcher_0.10.0_x64_en-US.msi`：`36baa08dd78ca8ea85f85ae69950081e070c83bd5fb7898cb28af92f577b5bfd`
  - `linux/LingXi Launcher_0.10.0_amd64.AppImage`：`6be4d1fce9ade3e4ca1a2caabab5d3323e542425345110efc97c3918f3c6ed89`
  - `linux/LingXi Launcher_0.10.0_amd64.deb`：`7af9ccaf130629662433d69a2644dc3947426f59798c7a8367a145b7ed4083ce`
  - `linux/LingXi Launcher-0.10.0-1.x86_64.rpm`：`71bd728318f7ccfc5ea0642f31c8014c91b1cdfb54aaff54200f410daae21f3c`

文档：
- `docs/rust-migration/BASELINE.md`
- `docs/rust-migration/FEATURE-PARITY.md`
- `docs/rust-migration/UI-PARITY.md`
- `docs/rust-migration/DATA-COMPATIBILITY.md`
- `docs/rust-migration/MIGRATION-STATUS.md`
- `docs/rust-migration/VISUAL-COMPARISON.md`
