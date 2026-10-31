# M9.0 — Internal Release Candidate 验证记录

日期：2026-10-31
基线：`6ef3db2`（327 tests）
最终：本阶段工作树（333 tests）

## 1. 结论

M9.0 的 P0 事务安全与 P1 用户配置保护修复已完成，并通过自动化回归。项目可构建为本地 Ad-hoc Internal RC，但**尚未达到完整发布验收**：第六节列出的真实游戏矩阵没有在本阶段全部重跑，Microsoft 正版登录也没有在自动化环境中执行。

本记录不把历史验证当成 M9.0 新验证。

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

- Debug tests：**333 tests, 0 failures**
- Release CLI/GUI：通过
- App Bundle：`dist/LingXiMac.app`，arm64，Ad-hoc 签名通过
- CI：见提交后的 Actions 运行链接

## 6. 真实游戏验证矩阵

| 项目 | 状态 | 说明 |
|---|---|---|
| Vanilla 1.21.1 | 未在 M9.0 重跑 | M3–M5 历史验证；本阶段未重新下载 |
| Fabric 1.20.1 | 未在 M9.0 重跑 | M8.2 真实更新实例已验证到标题界面 |
| NeoForge 1.21.1 | 未在 M9.0 重跑 | M7.2 真实启动 + JEI 已验证 |
| Fabric + Iris + Sodium | 未在 M9.0 重跑 | M7.1 真实光影/世界验证 |
| Modrinth 资源包加载 | 未在 M9.0 重跑 | M8.1 仅实现与单元测试 |
| 复制实例后启动 | 未在 M9.0 重跑 | M7.3 复制 Core 测试 |
| 世界备份/恢复 | 未在 M9.0 重跑 | M7.3 真实备份/恢复验证 |
| `.mrpack` 更新 | 未在 M9.0 重跑 | M8.2 真实 5.4.0→5.3.3 更新并启动 |
| 更新失败恢复 | 自动化故障测试通过 | 未做真实进程崩溃注入 |
| Microsoft 正版登录 | 未在 M9.0 重跑 | 需要真实账号，未自动化 |

历史截图和日志仍保留在 `docs/evidence/`；它们不能替代 M9.0 新验证，本报告明确区分。

## 7. 已知问题

1. 目标包要求 Fabric/NeoForge Loader 版本变化时，更新被阻止并建议新建实例；不自动升级 Loader。
2. 手动 `modpack.json` 关联 Modrinth 项目/版本仍可能被用户误用；未关联时更新明确不可用。
3. 性能工作台无法可靠采集 FPS，界面明确显示不可用，不伪造数据。
4. App 为 Ad-hoc 签名，未做 Developer ID/公证；不得标记为正式发行版。
5. 真实 Microsoft 登录、完整 10 项矩阵和真实进程中断恢复尚未在 M9.0 执行。
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
- [ ] 10 项真实游戏矩阵全部重跑
- [ ] Microsoft 正版登录实测
- [ ] 公证/Developer ID（明确排除）
