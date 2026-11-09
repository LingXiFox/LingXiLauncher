# 开发说明

本文描述 Rust + Tauri 2 + React 版的仓库结构、开发命令与验证方式。Swift 版本已移除，历史实现保留在 git 历史与 `docs/archive/swift/`。

## 仓库结构

```text
Cargo.toml                 # Rust workspace
crates/
  launcher-core/           # 与 GUI/CLI 无关的领域逻辑
  launcher-auth/           # Microsoft OAuth / Xbox / Minecraft Services
  launcher-platform/       # 平台路径、凭据、系统服务
  launcher-cli/            # lingxi 命令行（clap）
Apps/desktop/
  src/                     # React + TypeScript
  src-tauri/               # Tauri 2 命令层
docs/rust-migration/       # 基线、功能/UI/数据一致性与迁移状态
```

依赖方向固定为：`launcher-cli` / `lingxi-desktop` -> `launcher-core` / `launcher-auth` / `launcher-platform`。Core 不依赖 Tauri、React 或 WebView。

## 环境

- Rust 1.82+
- Node.js 20+、pnpm 9+
- macOS：Xcode Command Line Tools
- Linux：WebKitGTK 4.1 等 Tauri 依赖

本仓库把 Cargo 缓存放在项目内，构建时使用：

```bash
export CARGO_HOME="$PWD/.cargo-home"
```

## 常用命令

```bash
CARGO_HOME="$PWD/.cargo-home" cargo check --workspace
CARGO_HOME="$PWD/.cargo-home" cargo fmt --all -- --check
CARGO_HOME="$PWD/.cargo-home" cargo clippy --workspace --all-targets -- -D warnings
CARGO_HOME="$PWD/.cargo-home" cargo test --workspace

cd Apps/desktop
pnpm install --frozen-lockfile
pnpm typecheck
pnpm build
```

生产桌面二进制必须启用 `custom-protocol`，否则 Tauri 会尝试连接开发服务器：

```bash
cd Apps/desktop && pnpm build
cd ../..
CARGO_HOME="$PWD/.cargo-home" cargo build --release -p lingxi-desktop --features custom-protocol
```

## Core 模块

| 模块 | 职责 |
| --- | --- |
| `manifest` / `version` | Mojang 版本清单、版本 JSON、inheritsFrom 合并、规则与参数展开 |
| `install` | 原版下载、校验、解压、Fabric/NeoForge 安装、进度与取消 |
| `launch` | 依赖解析、classpath/natives、启动计划、进程与日志 |
| `models` | 实例、账户、版本、启动、错误等共享模型 |
| `mods` / `modrinth` | 本地模组元数据、Modrinth 搜索与版本选择 |
| `modpack` | `.mrpack` 检查/安装/更新，兼容旧 Swift 记录 |
| `resourcepacks` / `shaders` | 资源包与光影的导入、启停、删除 |
| `worlds` | 世界列表、目录格式备份、SHA-256 校验与恢复 |
| `diagnostics` | 崩溃日志采集、13 类规则、根因与导出 |
| `performance` | 系统画像、基准测试、调优建议与历史 |
| `graphics` | 实例 `options.txt` 读写与未知键保留 |

## 数据目录

- 游戏根：官方 `.minecraft`，可用 `--root` 或 `LINGXI_GAME_ROOT` 覆盖。
- 数据根：平台应用数据目录，可用 `--data-root` 或 `LINGXI_DATA_ROOT` 覆盖。
- 实例：`<dataRoot>/instances/<id>/`，游戏目录为 `<dataRoot>/.minecraft/versions/<id>/`。
- 账户、备份、设置、缓存分别位于 `accounts/`、`backups/`、`settings.json`、`cache/`。

兼容性边界见 [rust-migration/DATA-COMPATIBILITY.md](rust-migration/DATA-COMPATIBILITY.md)。

## 测试

- Core 单元测试：`cargo test -p launcher-core`
- 认证单元测试：`cargo test -p launcher-auth`
- 全工作区：`cargo test --workspace`
- 前端目前以 TypeScript 类型检查与生产构建为门禁；GUI 自动化测试尚未引入。

测试不得依赖真实 Microsoft 账号、真实游戏下载或用户主目录中的私有数据。
