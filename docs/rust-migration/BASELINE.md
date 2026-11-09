# Rust 迁移基线

## 基线标识

- 仓库：LingXiLauncher
- 分支：`rewrite/rust`
- 基线 commit：`2178abffc35495bfc82b8068b430f1359341c5ad`
- commit 标题：`build: scaffold Rust workspace with core models, installer downloader and auth`
- 记录时间：2026-11-09

## 迁移目标

按 `LXL.md` 将 Swift 6 + SwiftUI 启动器迁移为 Rust + Tauri 2 + React + TypeScript：

- core 不依赖 Tauri、React 或 WebView，GUI 与 CLI 共用同一个 core。
- macOS 与 Windows 为主要交付平台，Linux 做构建验证。
- 页面、功能、数据三一致；不允许占位页、无效按钮或模拟数据。
- 最终运行时代码与构建流程不再依赖 Swift。

## 基线时的仓库状态

| 项目 | 基线状态 |
| --- | --- |
| Rust workspace | 已建立 `crates/launcher-core`、`launcher-auth`、`launcher-platform`、`launcher-cli`、`apps/desktop/src-tauri` |
| Swift 代码 | `Sources/`、`Apps/LingXiMac/`、`Tests/` 仍为完整旧实现，约 35,405 行 Swift |
| Swift 测试 | 旧 XCTest 源码中约 357 个 `func test` 测试函数 |
| React 前端 | 只有 5 个页面雏形（Home、Instances、Downloads、Accounts、Logs），缺入口、App、设置页和全部弹窗 |
| Tauri 命令 | 约 35 个，仅覆盖引导、账户、实例、启动、设置、版本安装 |
| CLI | `crates/launcher-cli/src/main.rs` 只有 3 行版本打印 stub |
| core 编译 | 早期 `cargo test --workspace` 仅 18 个测试通过；mods、modrinth、modpack、resourcepacks、shaders、worlds、performance 等文件尚未全部加入模块树 |
| 文档 | `docs/` 下只有旧验证材料，没有 `docs/rust-migration/` |
| CI | `.github/workflows/ci.yml` 与 `release.yml` 仍是 Swift/Xcode 流程 |

## 基线测量

- Rust + Tauri 源码：约 21,497 行（`crates/` 与 `apps/desktop/src-tauri/src`，不含构建产物）。
- React/TypeScript 源码：约 7,641 行（`Apps/desktop/src`）。
- Swift 源码：约 35,405 行（`Sources/` 与 `Apps/LingXiMac/`）。

## 基线缺口

1. `launcher-core` 多数业务模块未参与编译，Tauri 只暴露基础命令。
2. React 前端缺 `main.tsx`、`App.tsx`、`SettingsPage` 与 10 类弹窗。
3. 前端服务层已声明 mods、Modrinth、mrpack、worlds、资源包、光影、性能、诊断命令，但后端尚未实现。
4. CLI 尚未迁移任何旧命令。
5. 数据兼容尚未验证：实例日志路径、`instance.json`、`mods.json`、世界备份、`modpack.json` 均与 Swift 旧格式存在差异。
6. 没有 Rust/Tauri CI，也没有可复现的打包与三平台构建验证。

## 构建环境（本次迁移实测）

| 工具 | 版本 |
| --- | --- |
| macOS | Apple Silicon |
| Rust | 1.99.1 |
| Node.js | 26.13.0 |
| pnpm | 9.15.9 |

Rust 构建使用仓库内 `CARGO_HOME`，避免沙箱写入用户目录：

```bash
CARGO_HOME=$PWD/.cargo-home cargo test --workspace
```
