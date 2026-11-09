# 功能一致性矩阵

图例：Core = `launcher-core`；GUI = Tauri 命令 + React 页面/弹窗；CLI = `lingxi` 子命令。

| 能力 | Core | GUI | CLI | 状态与说明 |
| --- | --- | --- | --- | --- |
| 版本清单/详情 | `manifest.rs`、`version/` | 下载页、安装向导 | `version list` / `version inspect` | 已实现；详情包含 Java、库、主类、资源索引、客户端 jar |
| 原版安装 | `install/vanilla.rs` | 安装向导 | `install vanilla` | 已实现；支持 official/mirror/auto/local-cache-only、并发与进度 |
| Fabric 安装 | `install/loader.rs` | 安装向导 | `install fabric` | 已实现；默认最新 stable，可指定 loader |
| NeoForge 安装 | `install/loader.rs` | 安装向导 | `install neoforge` | 已实现；需要 Java 21+ |
| 游戏启动 | `launch.rs` | 首页启动、实例页启动 | `launch` | 已实现启动计划、身份、日志、退出码；真实游戏启动尚未在本机验证 |
| Java 管理 | `java.rs` | 设置页 | `java list/install`、`doctor` | 已实现发现、检查、托管安装 |
| 本地账户 | `models/account.rs` | 账户页 | `account local ...` | 已实现创建/删除/激活与离线 UUID |
| Microsoft 登录 | `launcher-auth` | 账户页 | `account microsoft login/...` | 已实现 PKCE + loopback + 可取消登录；真实账号登录未在本次执行 |
| 实例管理 | `models/instance.rs` | 实例页、工具弹窗 | `instance create/list/copy` | 已实现创建、列表、复制、删除、内存/JVM 参数 |
| 模组管理 | `mods.rs`、`modrinth.rs` | 模组弹窗 | `mod ...` | 已实现搜索、安装、启停、删除、更新检查 |
| mrpack 导入 | `modpack.rs` | 整合包弹窗 | `mrpack inspect/install` | 已实现完整流程：解包、原版、Fabric/NeoForge；Quilt/Forge 明确拒绝 |
| 整合包更新 | `modpack.rs` | 更新弹窗 | `modpack update ...` | 已实现检查/预览/应用/中断恢复；旧 Swift `modpack.json` 只读 |
| 资源包 | `resourcepacks.rs` | 资源包弹窗 | `resourcepack ...` | 已实现搜索、安装、导入、启停、删除、更新检查 |
| 光影包 | `shaders.rs` | 光影弹窗 | `shader ...` | 已实现搜索、安装、导入、启停、删除、更新检查 |
| 世界与备份 | `worlds.rs` | 工具弹窗 | `world ...` | 已实现列表、目录格式备份、恢复、删除；兼容旧 zip 备份 |
| 崩溃诊断 | `diagnostics.rs` | 诊断页/崩溃弹窗 | `diagnose` | 已实现 13 类规则、证据、根因、Markdown/JSON 导出 |
| 性能 | `performance.rs` | 性能弹窗、设置页 | `performance ...` | 已实现系统画像、推荐、应用、基准与报告 |
| 图形设置 | `graphics.rs` | 图形弹窗 | `graphics status/setup` | 已实现 options.txt 读写、Iris/Sodium 安装；GUI 与 CLI 共用 |
| 日志 | `layout.rs`、启动模块 | 日志页 | 启动输出、`diagnose` | 已实现 launcher/game/latest 日志读取、打开目录、定位文件 |
| 设置 | settings JSON | 设置页 | 全局 `--source` 等 | 已实现 Java、内存、下载源、镜像、外观 |
| 文件校验 | `install/hashing.rs` | 诊断页间接使用 | `verify` | 已实现逐文件 SHA-1/大小校验，可选修复 |

## CLI 命令面

`lingxi --help` 注册 17 个顶层命令：

`version`、`doctor`、`launch`、`account`、`java`、`instance`、`diagnose`、`install`、`mod`、`mrpack`、`modpack`、`graphics`、`shader`、`resourcepack`（别名 `resourcepacks`）、`performance`（别名 `perf`）、`world`、`verify`。

## GUI 命令面

Tauri 注册 75 个命令；前端 `api.ts` 实际调用 61 个。未直接调用的命令是扩展能力（例如 `preview_launch`、`inspect_java`、旧账户列表兼容命令），不是占位实现。

## 明确未验证

- 真实 Minecraft 客户端启动、进入世界、渲染与多人联机。
- Microsoft 真实账号登录与令牌刷新。
- Modrinth 真实下载在受限网络下的完整性（接口解析已用真实 payload 单测）。
- Tauri Release 安装包在 macOS/Windows/Linux 的产物验证。
- GUI 自动化测试（当前没有测试框架依赖）。
