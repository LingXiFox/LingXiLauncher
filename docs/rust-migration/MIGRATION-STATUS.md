# 迁移状态

- 基线：`13c467c`（rewrite/rust 上 Rust/Tauri 完整实现，Swift 已移除）
- 实现提交：`ae9b1a9`（Fabric/NeoForge 依赖下载与真实启动修复）
- 状态日期：2026-11-10
- 环境：macOS Apple Silicon（M 系列），Java 27/26/21/17/8，Node 26，pnpm，Rust stable

状态标记：**通过** = 有可复现命令或产物；**部分** = 代码路径已实现但只做了有限验证；**未验证** = 没有执行过；**不适用** = 本机无法执行。

## 总览

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| Rust 质量门禁 | 通过 | `cargo fmt --all -- --check`、`cargo clippy --workspace --all-targets -- -D warnings`、`cargo test --workspace`（47 项） |
| 前端质量门禁 | 通过 | `pnpm typecheck`、`pnpm build`、`pnpm test:gui` |
| 前端 GUI 冒烟 | 通过（浏览器层） | `scripts/gui-smoke.mjs` 驱动构建产物，覆盖启动、导航、实例详情、模组/图形/安装弹窗、设置校验、账户、日志 |
| Tauri 真实窗口 | 通过 | macOS Release 1280×821 截图，19 张页面/弹窗截图在 `docs/rust-migration/screenshots` |
| 真实 Vanilla 启动 | 通过（到渲染线程） | Minecraft 1.21.11，Java 21，日志出现 `Created atlas`；未进入世界 |
| 真实 Fabric 启动 | 通过（到渲染线程） | Fabric 0.20.1 + 1.21.11，日志出现 `Created atlas` |
| 真实 NeoForge 启动 | 通过（到渲染线程） | NeoForge 21.11.48 + 1.21.11，日志出现 `Created atlas` |
| macOS 安装包 | 通过 | `.app` 已 ad-hoc 签名并启动；`.dmg` 已生成并通过 `hdiutil verify` |
| Windows/Linux 构建 | 通过（CI 可执行文件） | CI ubuntu/windows `cargo build` 通过；未生成安装包 |
| Microsoft 真机登录 | 未验证 | 需要真实账号与浏览器授权，本轮未执行 |
| 进入世界/联机/长时间稳定性 | 未验证 | 只验证到主菜单渲染线程 |
| Tauri WebView 进程内自动化 | 未验证 | 已完成 Chrome CDP 的前端冒烟，不是 WebView 内驱动 |

## 1. 构建与质量门禁

本机执行并通过：

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cd Apps/desktop && pnpm typecheck && pnpm build && pnpm test:gui
```

- `cargo test --workspace`：launcher-core 41 项、launcher-auth 6 项，共 47 项通过。
- 前端构建：Vite 78 modules；JS 约 284 kB（gzip 86 kB），CSS 约 80 kB（gzip 14 kB）。
- GUI 冒烟：`GUI smoke passed: boot, navigation, instance detail, mods/graphics/install modals, settings validation, accounts, logs`；截图在 `.tmp/gui-smoke/`。
- 生产构建必须启用 custom-protocol：`cargo build --release -p lingxi-desktop --features custom-protocol`。未启用时 Tauri 2 会走 devUrl，Release 窗口白屏。
- 版本统一为 `0.10.0`：Cargo workspace、Tauri bundle、CLI `lingxi --version` 一致。

## 2. 平台与凭证

### macOS
- 刷新令牌写入登录钥匙串，service `LingXiLauncher`，account `microsoft-refresh-token:v1:<uuid>`。
- 兼容旧 Swift 钥匙串：service `com.lingxifox.LingXiLauncher.microsoft`、account 为小写 UUID；读取旧值后写入新 service 并删除旧项。
- 设置迁移：仅当 `settings.json` 不存在时读取 `/usr/bin/defaults read com.lingxifox.LingXiLauncher lingxi.*`；损坏的 `settings.json` 保留原文件并回退默认值，不覆盖。

### Windows
- 刷新令牌使用 DPAPI，entropy `LingXiLauncher`，密文写入数据目录 `credentials/<uuid>.bin`，原子替换。
- 兼容旧 Rust 的无 entropy 文件与 `%APPDATA%/LingXiLauncher/credentials/<uuid>.bin`。
- 物理内存通过 PowerShell `Get-CimInstance Win32_ComputerSystem` → `wmic` → `Win32_OperatingSystem` 三级读取。
- 本机没有 Windows 环境，以上路径只做了代码复核与 CI 交叉编译，**未在 Windows 真机执行**。

### Linux
- 使用 `secret-tool` 访问 Secret Service；没有 provider 时返回 `no Secret Service provider found; install libsecret-tools/secret-tool`。
- 只有显式设置 `LINGXI_ALLOW_PLAINTEXT_SECRETS=1` 才回退到 0600 明文文件，用于无桌面/CI 的受控环境。
- 本机没有 Linux 桌面，**未在 Linux 真机执行**；CI 只验证构建。

### Microsoft 令牌
- `session_for` 优先使用内存缓存，其次读取刷新令牌；刷新后保留新 refresh token。
- `sign_out` 删除钥匙串令牌、账户记录与内存缓存。
- GUI 启动只允许 Microsoft 账户；本地离线账户在桌面端提示改用 CLI：`lingxi launch --identity local:<name>`。
- **未验证**：真实 Microsoft 账号登录、令牌刷新、过期/撤销场景。

## 3. 真实游戏安装与启动

隔离目录：`.tmp/accept/data`、`.tmp/accept/game`；未触碰真实用户实例、世界或账户。

| 版本 | 安装 | 启动证据 | 结果 |
| --- | --- | --- | --- |
| Vanilla 1.21.11 | 4665 文件 / 551,983,062 字节，缺失 0 | Java 21，`Created atlas` | 通过到渲染线程 |
| Fabric 0.20.1 + 1.21.11 | 4673 文件，Fabric 依赖从缓存命中 | Java 21，`Created atlas` | 通过到渲染线程 |
| NeoForge 21.11.48 + 1.21.11 | installer 成功，classpath 98，缺失 0 | Java 21，`Created atlas` | 通过到渲染线程 |

说明：
- 三次都是无头/限时启动，验证进程能完成 JVM、加载器、资源与渲染线程初始化；随后主动终止，**没有进入世界、没有联机、没有长时间运行**。
- Vanilla 终止返回 143，CLI 报 `game exited with 143`，退出码 1；这是主动 SIGTERM，不是崩溃。
- Fabric 首次安装曾因加载器库未下载导致启动缺失 8 个依赖；已在 `LoaderInstaller` 中调用 `VanillaInstaller.install` 下载合并依赖并验证通过。
- NeoForge 的 `releaseTime` 不带时区，已增加宽松时间解析；安装前会写 `launcher_profiles.json`，避免 installer 要求“先运行启动器”。

## 4. 安装包

| 产物 | 路径 | 状态 |
| --- | --- | --- |
| macOS `.app` | `target/release/bundle/macos/LingXi Launcher.app` | ad-hoc 签名，`codesign --verify --deep --strict` 通过，启动截图正常 |
| macOS `.dmg` | `target/release/bundle/dmg/LingXi Launcher_0.10.0_aarch64.dmg` | `hdiutil create` 成功，5.3 MB，UDZO；`hdiutil verify` 校验 VALID |
| Windows 安装包 | 无 | CI 只构建可执行文件，未运行 `tauri build` |
| Linux 安装包 | 无 | CI 只构建可执行文件，未运行 `tauri build` |

macOS 产物未使用 Developer ID 签名，也未公证；不能作为公开发行包。

## 5. CI

- CI 已从 Swift 切换为 Rust/Tauri：fmt、clippy、test、前端 typecheck/build、macOS/Windows/Ubuntu desktop build、CLI 冒烟。
- run `42759274223`：Rust quality、CLI smoke、Ubuntu desktop、Windows desktop 通过；macOS job 启动即 `cancelled`，没有 step 日志。
- run `42761500589`：Rust quality、CLI smoke、Ubuntu desktop、Windows desktop 通过；macOS 仍 `cancelled`，整轮因该 job 被标记 `cancelled`。
- 结论：**Linux/Windows 可执行文件构建通过；macOS CI runner 未完成**。本机 macOS Release 构建与打包已通过。
- `release.yml` 已改为 Tauri 三平台打包，但尚未在 CI 实际产出安装包。

## 6. 视觉与交互

- SwiftUI 旧版与 Rust 新版首页并排对比见 `VISUAL-COMPARISON.md`。
- 19 张真实 Tauri 窗口截图见 `screenshots/`，覆盖首页、实例、下载、账户、日志、设置、安装向导、模组、整合包、整合包更新、图形、性能、资源包、光影、工具（实例/世界/诊断）、崩溃报告。
- 保留的视觉语言：深色/浅色主题、侧栏分组、面包屑、卡片、状态胶囊、中文文案、Fox 标识。
- 增量：实例详情整合包行与更新入口、图形设置直接编辑 `options.txt`、性能页旧版基准记录、诊断页真实检查。
- 限制：旧 Swift 版无法自动点击切页，只能截首页；新版截图使用测试数据目录，不代表用户真实数据。

## 7. 数据兼容

- 实例目录、`instance.json`、`mods` 元数据、旧整合包记录、世界备份目录格式均按 Swift 结构读取或兼容。
- 旧整合包 `modpack.json` 只读，不会在读取时改写；避免误更新覆盖旧记录。
- 日志目录统一为实例游戏目录下的 `logs`，与 Swift 一致。
- 世界备份改为 Swift 的目录格式，同时兼容旧 zip；恢复时校验实例归属、文件 SHA-256 与大小。
- 详见 `DATA-COMPATIBILITY.md`。

## 8. 未验证与已知问题

1. Microsoft 真实账号登录、刷新令牌轮换、退出登录未在真机执行。
2. 游戏只到主菜单渲染线程，未进入世界、未联机、未做长时间稳定性与性能对比。
3. Windows/Linux 只在 CI 构建可执行文件，没有真机运行、安装包或 WebView 验证。
4. macOS 产物未做 Developer ID 签名与公证，不能作为公开发行包。
5. GUI 自动化是 Chrome CDP 的前端冒烟，不是 Tauri WebView 进程内自动化；未覆盖真实 IPC、文件对话框、系统钥匙串。
6. 旧 Swift 版只能截首页，视觉对比不覆盖全部页面。
7. macOS CI job 启动即 cancelled，原因未定位；本机构建不受影响。
8. 资源包/光影的真实 Modrinth 下载未在受限网络下做完整性验证。
9. 旧版 Swift 设置迁移只做了代码路径复核，未用真实 `defaults` 域做端到端测试。

## 9. 复现命令

```bash
# Rust
CARGO_HOME=$PWD/.cargo-home cargo fmt --all -- --check
CARGO_HOME=$PWD/.cargo-home cargo clippy --workspace --all-targets -- -D warnings
CARGO_HOME=$PWD/.cargo-home cargo test --workspace

# 前端
cd Apps/desktop
pnpm typecheck
pnpm build
pnpm test:gui

# 生产二进制与 macOS 打包
cd ../..
CARGO_HOME=$PWD/.cargo-home cargo build --release -p lingxi-desktop --features custom-protocol
cd Apps/desktop
pnpm exec tauri build --bundles app,dmg

# CLI
cargo run -q -p launcher-cli -- --help
```
