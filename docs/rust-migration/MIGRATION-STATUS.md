# 迁移状态

## 阶段

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| P0 | 基线勘察、Swift 功能/数据盘点 | 完成 |
| P1 | `launcher-core` 全模块编译、测试补齐 | 完成 |
| P2 | Tauri 命令与前端契约对齐 | 完成 |
| P3 | React 入口、页面、10 类弹窗 | 完成 |
| P4 | CLI clap 重建（17 个顶层命令） | 完成 |
| P5 | Swift 数据兼容 | 完成（见边界） |
| P6 | 质量门禁、文档、CI | 完成（本机；CI 未远端执行） |
| P7 | 三平台打包、真实游戏启动、Swift 移除 | 本机窗口与 Swift 移除完成；三平台安装包与真实启动待验证 |

## 已验证

在本机 macOS Apple Silicon 执行：

| 检查 | 结果 |
| --- | --- |
| `cargo fmt --all -- --check` | 通过 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 通过（0 warning） |
| `cargo test --workspace` | 通过（launcher-core 39 项、launcher-auth 6 项） |
| `cargo check -p lingxi-desktop` | 通过 |
| `cd Apps/desktop && pnpm typecheck` | 通过（tsconfig + tsconfig.node） |
| `cd Apps/desktop && pnpm build` | 通过（78 modules，JS 284.74 kB / CSS 79.84 kB） |
| `cargo build --release -p lingxi-desktop --features custom-protocol` | 通过，启动后窗口正常渲染 |
| CLI `lingxi --help` | 17 个顶层命令正常输出 |
| CLI 冒烟 | `version list/inspect --json`（1.7.10、1.20.1、1.21.11、26.3）、`doctor`、`launch --dry-run`、`diagnose`、`performance status/benchmark/tune`、`graphics status`、`mod search/install/enable/disable/remove`、`mrpack inspect`、`resourcepack/shader search`、`world list/backup/restore/delete` 可运行；Sodium 模组真实下载并安装 |
| Tauri 命令/前端契约 | 前端 61 个调用全部有注册命令，无缺失 |
| 界面截图 | 19 张页面/弹窗截图，见 UI-PARITY.md |

## 未验证

- 真实 Minecraft 游戏启动、进入世界、渲染、多人联机。
- Microsoft 真实账号登录。
- Tauri Release 安装包（macOS `.app`/`.dmg`、Windows `.msi`/`.exe`、Linux `.deb`/`.AppImage`）。
- GUI 自动化测试；当前没有 Vitest/Playwright 测试依赖。
- Windows/Linux 实机运行；CI 只提供构建验证配置，尚未在远端执行。
- CLI 资源包真实下载安装在测试网络下未跑完；Modrinth 搜索与模组真实安装已验证。

## 已知差异与风险

1. 旧 Swift 整合包记录只读；Rust 新记录不保证旧 Swift 可读。
2. 性能历史报告不做字段迁移。
3. Swift 设置不迁移，Rust 首次运行使用默认设置。
4. 真实游戏启动需要用户本机已安装对应版本与 Java；本次未执行，报告不得标记为通过。
5. Tauri CLI 未安装，打包命令尚未在本机执行。

## 最终验收清单

- [x] Rust core 与 CLI 共用实现
- [x] Tauri 命令与前端类型契约对齐
- [x] React 页面与弹窗无占位
- [x] Swift 旧数据主要格式可读
- [x] fmt / clippy / test / typecheck / build
- [x] 本机 Tauri Release 二进制启动与 19 张界面截图
- [ ] Tauri Release 三平台产物
- [ ] 真实游戏启动
- [ ] GUI 自动化测试
- [x] 移除 Swift 源码与旧 CI（Swift 源码保留在 git 历史与 `swift-implementation-before-removal` tag）
- [x] 最终 commit 与验收报告（随本次收尾提交）
