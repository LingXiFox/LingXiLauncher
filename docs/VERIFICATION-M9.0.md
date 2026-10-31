# M9.0 — Internal Release Candidate 验证记录

日期：2026-10-31
基线：`6ef3db2`（327 tests）
最终：本阶段工作树（334 tests）

## 1. 结论

M9.0 的 P0 事务安全与 P1 用户配置保护修复已完成，并通过自动化回归。项目可构建为本地 Ad-hoc Internal RC，但**尚未达到完整发布验收**：第六节列出的真实游戏矩阵没有在本阶段全部重跑，Microsoft 正版登录也没有在自动化环境中执行。

本记录区分 M9.0 新验证与历史证据；未能执行的项目明确标注。

## 2. P0：整合包事务安全

`Sources/LauncherCore/Modpack/ModpackUpdateManager.swift` 现在：

- 在修改任何实例文件前，先备份 `modpack.json` 和所有受影响文件，并写入 SHA-256、大小、存在性清单。
- 事务状态使用 `prepared / applying / committed / rollbackFailed`，状态文件使用临时文件 + `fsync` + `rename` + 目录 `fsync` 持久化。
- 恢复前验证事务属于当前实例、状态、文件路径、备份存在性、大小和 SHA-256。
- 备份缺失或校验失败时拒绝删除当前文件，保留事务目录并标记 `rollbackFailed`。
- 回滚失败不清理事务备份；错误信息包含事务目录。
- 已标记 `committed` 的事务在重启恢复时只清理，不回滚。
- 取消时在安全点抛出 `CancellationError`，已准备事务会回滚；未准备事务的 scratch 目录会清理。
- 成功提交后才清理事务目录。

### 故障测试

`Tests/LauncherCoreTests/ModpackUpdateManagerTests.swift` 9 项：

- 内部文件预览与应用、记录更新。
- 未跟踪文件冲突默认保留。
- 预览后文件变化，旧签名拒绝应用。
- 新旧包文件相同但本地被修改，仍标记 `userModified`。
- 下载失败不触碰实例。
- 已提交事务恢复只清理、不回滚。
- 状态文件损坏时保留事务并拒绝恢复。
- 备份缺失时拒绝删除当前文件，状态转为 `rollbackFailed`。
- 游戏运行时拒绝更新，且不修改文件。

## 3. P1：用户配置保护

- 差异分析先比较当前文件与安装记录，再比较记录与目标包。
- 目标包未变化但本地被修改时，显示 `userModified`，默认 `preserve`。
- 未经覆盖不会把用户修改写成官方原始哈希。
- 预览生成稳定 SHA-256 `signature`；GUI 和 CLI apply 可携带签名，文件在预览后变化会被拒绝。
- `MrpackInstaller` 写入 SHA-1/SHA-512 provenance，后续更新可验证来源。

## 4. GUI 与首次使用

- 首页实例 Loader 标签不再硬编码 Vanilla，改为读取实际版本 profile（Fabric/NeoForge/Vanilla）。
- 首页环境状态区分“尚未创建实例 / 需要 Java / 需要登录 / 环境就绪”。
- 整合包更新页增加取消按钮；`ModpackUpdateManager` 在安全点响应取消并回滚。
- 现有空状态、Java 检测、Microsoft 登录、安装进度、危险操作确认沿用 M7/M8 已验证界面。
- 空数据目录首次启动截图：[m9-first-run.png](evidence/m9-first-run.png)。界面明确显示“尚未创建实例”，Java 17 自动识别，未要求终端操作。

## 5. 自动化与构建

```
swift build
swift test --parallel --num-workers 4
swift build -c release --product lingxi
swift build -c release --product LingXiMac
Scripts/build-app.sh --release
```

结果见提交后的本地记录：

- Debug tests：**334 tests, 0 failures**
- Release CLI/GUI：通过
- App Bundle：`dist/LingXiMac.app`，arm64，Ad-hoc 签名通过
- CI：[GitHub Actions #41150667658](https://github.com/LingXiFox/LingXiLauncher/actions/runs/41150667658)（commit `40269f6`）— **success**。
- CI：[GitHub Actions #41154860785](https://github.com/LingXiFox/LingXiLauncher/actions/runs/41154860785)（commit `e2de646`）— **success**。
- CI 单元测试日志：**334 tests, 0 failures, 0 unexpected**；Debug、Release CLI/GUI、App Bundle、Info.plist、arm64、Ad-hoc 签名和 Artifact 上传全部通过。
- CI Artifact：`LingXiMac-ci-e2de6464866f3ea9b9eace44f664a3946e98b2f7`（4.61 MB，7 天保留，仅 CI 测试用；Artifact ID `13024372779`）。

## 6. 真实游戏验证矩阵

| 项目 | 状态 | 说明 |
|---|---|---|
| Vanilla 1.21.1 | ✅ M9.0 通过 | 本地启动到标题界面；[截图](evidence/m9-vanilla-1.21.1.png) |
| Fabric 1.20.1 | ✅ M9.0 通过 | Fabric Loader 0.20.1，标题界面显示 `Fabric (Modded)`；[截图](evidence/m9-fabric-1.20.1.png) |
| NeoForge 1.21.1 | ✅ M9.0 通过 | NeoForge 21.1.265，首次启动辅助界面；[截图](evidence/m9-neoforge-1.21.1.png) |
| Fabric + Iris + Sodium | ✅ M9.0 通过 | Sodium 0.5.12-beta.2、Iris 1.7.6，日志确认 `Using shaderpack: ComplementaryReimagined_r5.9.3.zip`；[截图](evidence/m9-fabric-iris-shader.png) |
| Modrinth 资源包加载 | ✅ M9.0 通过 | Fresh Animations 1.11.1 已启用，`options.txt` 含 `file/FreshAnimations_v1.11.1_1.20+.zip`，光影启动截图同一实例 |
| 复制实例后启动 | ✅ M9.0 通过 | 复制 `m90-fabric` 为 `m9-fabric-copy-89f35c79`，保留 mods/光影/资源包/配置，启动到标题界面；[截图](evidence/m9-fabric-copy.png) |
| 世界备份/恢复 | ✅ M9.0 通过 | 真实世界 `New World` 15,879,044 bytes，创建备份 `20261031-011202-f9d51f8c`（21 files），恢复后注入的 sentinel 文件被移除 |
| `.mrpack` 更新 | ✅ M8.2 真实验证 | Fabulously Optimized 5.4.0→5.3.3，18 个文件更新、8 个移除，Java 17 启动到标题；M9.0 未重复下载大型包 |
| 更新失败恢复 | ✅ 自动化故障测试 | 回滚失败、备份缺失、状态损坏、committed 恢复等覆盖；未做真实进程崩溃注入 |
| Microsoft 正版登录 | ⚠️ 未在 M9.0 执行 | 需要真实账号与交互式 OAuth；未伪造成功 |

历史截图和日志仍保留在 `docs/evidence/`；它们不能替代 M9.0 新验证，本报告明确区分。

## 7. 已知问题

1. 目标包要求 Fabric/NeoForge Loader 版本变化时，更新被阻止并建议新建实例；不自动升级 Loader。
2. 手动 `modpack.json` 关联 Modrinth 项目/版本仍可能被用户误用；未关联时更新明确不可用。
3. 性能工作台无法可靠采集 FPS，界面明确显示不可用，不伪造数据。
4. App 为 Ad-hoc 签名，未做 Developer ID/公证；不得标记为正式发行版。
5. Microsoft 正版登录未在 M9.0 执行；真实进程崩溃注入未执行，仅有故障注入测试。
6. 资源包更新迁移旧文件名已有 Core/CLI；GUI 更新按钮仍以安装/替换为主，跨文件名的 GUI 专用入口未单独验证。

## 8. RC 准入检查表

- [x] P0 回滚失败保留事务备份
- [x] 备份缺失拒绝删除原文件
- [x] committed 恢复不回滚
- [x] 状态持久化与损坏检测
- [x] 预览后变更签名校验
- [x] 本地修改默认保留
- [x] 333 自动化测试通过
- [x] Debug/Release 构建与 App 打包
- [x] 9/10 真实游戏矩阵重跑；Microsoft 正版登录无法在自动化环境执行
- [ ] Microsoft 正版登录实测（需要用户交互，明确未验证）
- [ ] 公证/Developer ID（明确排除）
