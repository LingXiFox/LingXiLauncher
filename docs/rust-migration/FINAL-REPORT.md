# 最终验收报告

## 结论

Rust + Tauri 2 + React + TypeScript 实现已完成并取代 Swift 实现。Swift 源码、测试、旧应用包与构建脚本已从工作树移除，历史保留在 tag `swift-implementation-before-removal`（指向 `6aae3fd`）。

- 迁移基线：`2178abf`
- 最终代码提交：`dd67a28`（`5e75fc9` 为验证状态文档收尾）
- 当前分支：`rewrite/rust`
- 生产构建：`CARGO_HOME=$PWD/.cargo-home cargo build --release -p lingxi-desktop --features custom-protocol`

## 模块

| 部分 | 内容 |
| --- | --- |
| `crates/launcher-core` | 版本清单与解析、Java 发现、原版/Fabric/NeoForge 安装、启动计划与进程、实例、账户、Modrinth、模组、整合包、世界与备份、资源包、光影、图形 options.txt、性能、崩溃诊断 |
| `crates/launcher-platform` | macOS/Windows/Linux 平台上下文、系统服务、密钥存储适配 |
| `crates/launcher-auth` | Microsoft OAuth PKCE、loopback 回调、可取消登录、令牌刷新 |
| `crates/launcher-cli` | clap 17 个顶层命令，GUI 与 CLI 共用 core |
| `Apps/desktop/src-tauri` | 75 个 Tauri 命令、事件、应用状态 |
| `Apps/desktop/src` | React 入口、6 个页面、10 类弹窗、19 张界面截图 |

当前源码规模：Rust 21,608 行，前端 12,189 行（含 CSS），合计 33,797 行。迁移前 Swift 基线约 35,405 行。

## 一致性与数据

- 页面/弹窗与 SwiftUI 版本的对照见 `UI-PARITY.md`，功能矩阵见 `FEATURE-PARITY.md`。
- Swift 实例、账户、整合包、世界备份、Java 运行时、模组元数据的主要格式可读；边界见 `DATA-COMPATIBILITY.md`。
- 新增 `InstanceManifest.gameVersion`，加载器安装后记录真实 Minecraft 版本，界面不再把 `fabric-loader-x-y` 当作游戏版本显示；旧实例缺少该字段时回退解析 Fabric/Quilt 版本 id。

## 质量门禁（本机 macOS Apple Silicon）

| 命令 | 结果 |
| --- | --- |
| `cargo fmt --all -- --check` | 通过 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 通过 |
| `cargo test --workspace` | 通过：launcher-core 39 项、launcher-auth 6 项 |
| `cd Apps/desktop && pnpm typecheck` | 通过 |
| `cd Apps/desktop && pnpm build` | 通过：78 modules，JS 284.74 kB / CSS 79.84 kB |
| `cargo build --release -p lingxi-desktop --features custom-protocol` | 通过，11 MB 二进制 |
| Release 窗口冒烟 | 通过：1280x821 窗口正常渲染首页、侧栏、实例与账户 |

## CLI 实测

已运行并核对：`version list/inspect --json`（1.7.10、1.20.1、1.21.11、26.3）、`doctor`、`launch --dry-run`（含 JSON）、`diagnose`、`performance status/benchmark/tune`、`graphics status`、`mod search/install/enable/disable/remove`、`mrpack inspect`、`resourcepack/shader search`、`world list/backup/restore/delete`。

真实 Modrinth 操作已验证：Sodium 模组下载并安装；Fabulously Optimized 15.0.0-beta.3 整合包解析（49 个文件、42.0 MiB）；世界目录备份、删除、恢复往返成功。资源包真实下载在测试网络下未跑完，未标记为通过。

## 未验证

- 真实 Minecraft 游戏启动、进入世界、渲染、多人联机。
- Microsoft 真实账号登录。
- Tauri CLI 未安装，未在本机生成 macOS `.app`/`.dmg`、Windows `.msi`/`.exe`、Linux `.deb`/`.AppImage`。
- GUI 自动化测试；仓库没有 Vitest/Playwright 依赖。
- Windows/Linux 实机运行；CI 仅有构建配置，未在远端执行。
- 性能基准对比未做；没有可靠的 Swift 与 Rust 同机同场景数据，不提供估算值。

## 已知问题

1. 旧 Swift 整合包记录只读，Rust 新记录不保证旧 Swift 可读。
2. 性能历史报告不做字段迁移；首次运行使用默认设置。
3. `graphics setup` 需要真实 Fabric 实例；测试实例不是 Fabric 版本，未完成 Iris + Sodium 自动安装验证。
4. Tauri CLI 与三平台安装包属于剩余交付项，安装新工具前需要主人许可。
5. 旧 `docs/VERIFICATION-*.md` 与 `docs/evidence` 保留为 Swift 时代历史证据，不代表当前 Rust 实现已重新验证。

## 验收清单

- [x] Rust core 与 CLI 共用实现
- [x] Tauri 命令与前端类型契约对齐
- [x] React 页面与弹窗无占位、无模拟数据
- [x] Swift 旧数据主要格式可读
- [x] fmt / clippy / test / typecheck / build
- [x] 本机 Tauri Release 二进制启动与 19 张界面截图
- [x] 移除 Swift 源码与旧 CI
- [ ] Tauri Release 三平台安装包
- [ ] 真实游戏启动与 Microsoft 真机登录
- [ ] GUI 自动化测试
