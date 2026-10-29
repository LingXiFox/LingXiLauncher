# M7.3 验证记录：崩溃诊断与实例管理

## 范围

M7.3 同时包含 M7.2 遗留稳定性补丁和新的实例/世界管理能力：

- NeoForge 安装事务：`commit`、`rollback`、`cleanup` 明确分离；成功提交后才清理 `neoforge-backup-UUID`，失败/取消/超时恢复旧 libraries、版本 profile 和实例元数据。
- 光影包文件名冲突：更新只允许替换当前项目明确指定的旧文件；其他项目或未知来源的同名文件在提交前拒绝。
- 更新检测：模组与光影共用 `ModrinthUpdatePolicy`，按 release/beta/alpha 渠道和自然版本号比较，不自动推荐降级。
- `CrashDiagnostics` Core 模块：实例绑定日志采集、12 类确定性规则、根因/连锁错误排序、未知原因回退、Markdown/JSON 脱敏导出。
- `InstanceCopyService`：新实例 ID、复制实例自有数据、可选 `saves`，共享全局 libraries/assets。
- `WorldBackupManager`：独立 `dataRoot/backups/<instance-id>/`、Manifest + SHA-256、路径/符号链接防护、运行中拒绝、分阶段恢复与恢复点。
- SwiftUI「实例管理」：实例管理 / 世界存档 / 启动诊断三个页签；异常退出时自动打开诊断。

## 核心安全语义

### NeoForge 事务

`NeoForgeFileTransaction` 的备份根只位于实例数据根下的 `tmp/neoforge-backup-UUID`，不会清理 Minecraft `libraries/` 或 `versions/` 原文件。事务在写入实例元数据之前保留备份；失败时恢复每个原有文件和 profile，清理只作用于本事务的私有备份。

### 世界恢复

恢复顺序为：

1. `InstanceRuntimeRegistry` 检查实例是否正在运行。
2. 校验备份 Manifest、文件数量、大小和 SHA-256。
3. 在 `saves/` 内创建临时 staging，不直接删除当前世界。
4. 将当前世界移入私有恢复点。
5. 用 staging 替换世界并重新校验。
6. 成功后清理恢复点；任何一步失败则恢复原世界。

路径必须解析符号链接后仍位于实例 `saves/` 内；备份 ID、世界名和实例 ID 均经过路径组件校验。

## 自动化测试

```
swift test --parallel --num-workers 4
Executed 316 tests, with 0 failures (0 unexpected)
```

新增覆盖包括：

- `CrashDiagnosticsTests`：Fabric 缺失依赖、NeoForge 冲突、Java/LWJGL/OpenGL/Iris、未知日志、实例隔离采集、崩溃报告、Token/路径脱敏。
- `InstanceBackupTests`：复制成功/失败回滚、世界备份/恢复/删除、运行中拒绝、损坏备份拒绝、路径穿越/符号链接拒绝、写入失败恢复、旧实例 JSON 兼容。
- `M7StabilityTests`：NeoForge 事务提交清理/回滚、多个光影包同名冲突、混合渠道不降级。
- `M7GraphicsTests`：Sodium+Iris 双模组失败回滚、光影 ZIP/元数据事务回滚、运行中激活拒绝。

## 真实环境验证

环境：macOS 27.2 / Apple Silicon / Java 17（Fabric 1.20.1）。

- Fabric 1.20.1 独立实例 `m73-fabric` 安装：3643 files / 739.1 MB，Fabric Loader 0.20.1。
- 实际创建世界 `New World`（约 17.3 MB），截图：[m7.3-world-ingame.jpg](evidence/m7.3-world-ingame.jpg)。
- 世界备份：21 files / 17,321,236 bytes。
- 在 world 目录写入临时 marker，恢复备份后 marker 消失，世界目录被完整替换。
- 游戏运行中恢复命令返回 `LAUNCH_FAILED`（exit 70），registry 记录被正确写入并在退出后清理。
- 实例复制：`m73-copied-instance-b09b98ff` 复制 `mods`、`resourcepacks`、`options.txt`、`saves`，源实例不被修改；复制实例成功启动到主菜单：[m7.3-copied-instance-title.jpg](evidence/m7.3-copied-instance-title.jpg)。
- NeoForge 21.1.265 / Minecraft 1.21.1 回归启动到标题界面（2 mods）：[m7.3-neoforge-regression.jpg](evidence/m7.3-neoforge-regression.jpg)。
- GUI「实例管理」：实例复制/完整性页 [manage](evidence/m7.3-instance-tools-manage.jpg)；世界列表面 [worlds](evidence/m7.3-instance-tools-worlds.jpg)；启动诊断页 [diagnostics](evidence/m7.3-instance-tools-diagnostics.jpg)。

## 已知限制

- 世界备份默认手动，不自动在每次启动时生成；没有定时清理策略。
- 自动修复入口只展示安全建议；删除模组、覆盖配置或修改世界仍需用户明确确认（当前不自动执行）。
- 帧率无法由外部启动器稳定读取，性能工作台不会用 CPU 占用伪造 FPS。
