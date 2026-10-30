# M8.1 Data Integrity & Resource Ecosystem — 验证记录

## 状态

本记录只描述**本机实际完成并验证**的内容。M8.1 的整合包更新事务与真实资源包进游戏验证尚未完成，不能把合成测试当作真实验证。

## 自动化测试

```text
swift test --parallel --num-workers 4
Executed 322 tests, with 0 failures (0 unexpected)
```

新增/加强：

- `InstanceBackupTests.testCopyInstanceCopiesOwnedDataAndOptionalSavesWithoutChangingSource`
  - 复制 `mods.json`、`shaderpacks.json`
  - 保留禁用模组目录
  - 原实例不被修改
- `InstanceBackupTests.testBackupIncludesHiddenFilesAndVerifiesThem`
  - 世界隐藏文件进入 Manifest 和 SHA-256 校验
- `InstanceBackupTests.testModpackSourceIsNeverGuessedAndRoundTrips`
  - 有来源记录时往返；无 `projectID` 时拒绝猜测项目
- `InstanceBackupTests.testWorldDuringWriteFailureLeavesOriginalRecoverable`
  - 恢复失败保留原世界与恢复目录
- `InstanceBackupTests.testRestoreRefusedWhileGameRuns`
  - 运行状态拒绝恢复
- `InstanceBackupTests.testCorruptBackupIsRejectedWithoutTouchingCurrentWorld`
- `InstanceBackupTests.testSymlinkedWorldAndTraversalBackupIDAreRejected`
- `M81ResourcePackTests`
  - 本地 ZIP 导入/列表/删除
  - 未管理文件冲突拒绝
  - `pack.mcmeta` 缺失和路径穿越拒绝
  - `options.txt` 其他键保留、启用状态更新

## 已实现

### 实例复制

- 从实例元数据目录复制 `mods.json`、`shaderpacks.json`、`modpack.json`（如存在）。
- 复制 game directory 下的 `mods/`、`mods-disabled/`、`shaderpacks/`、`config/`、`options.txt`、资源包等实例自有数据。
- 新实例使用新 ID；不复制全局 `libraries/`、`assets/` 和下载缓存。
- 只清理新实例，源实例保持不变。
- 运行中复制含 `saves/` 时拒绝。

### 世界备份

- 备份和世界列表不再跳过隐藏文件。
- 使用 `flock` 做跨进程备份锁，降低两个启动器并发操作的风险。
- 源目录前后快照，复制后的每个目标文件重新计算 SHA-256；源文件在备份期间变化时拒绝提交。
- 恢复前完整校验 Manifest 和所有文件；恢复使用暂存目录与恢复点，失败尝试回滚。
- 回滚失败时保留恢复目录并在错误建议中给出路径，不自动删除唯一可恢复数据。

### 资源包

- `ResourcePackManager`：Modrinth 搜索、版本选择、下载、SHA-1/SHA-512 校验、安装、更新检查、删除。
- ZIP 校验：拒绝路径穿越、异常压缩比、缺少/非法 `pack.mcmeta`，不只看 ZIP 头。
- 安装到 `<gameDir>/resourcepacks/`，元数据写入 `<instance>/resourcepacks.json`。
- 本地 ZIP 导入；未管理文件冲突拒绝。
- `options.txt` 启用状态只对已人工验证的 1.20.1–1.21.11 支持；其他版本只提示游戏内启用。
- GUI `ResourcePacksView` 与 CLI `lingxi resourcepack ...` 复用 Core API。

### 整合包生命周期（部分）

- `.mrpack` 安装成功后写入 `<instance>/modpack.json`，记录版本 ID、Minecraft/Loader、归档哈希和文件清单。
- 不根据名称猜项目；`projectID` 必须通过可信来源显式关联。
- `ModpackLifecycleManager` 支持来源关联、更新版本查询、差异预览结构和用户修改标记。
- **未实现**：整合包更新执行事务、GUI 更新差异页面、真实 `.mrpack` 更新验证。

## GitHub Actions 实跑

- 运行：[CI #40981813313](https://github.com/LingXiFox/LingXiLauncher/actions/runs/40981813313)（commit `3613d2a`）— **success**。
- 日志：`Executed 322 tests, with 0 failures (0 unexpected)`；XCTest skip 0。
- Debug/Release、App Bundle、Info.plist、arm64 与 `Signature=adhoc` 均通过。
- 产物：`LingXiMac-ci-3613d2a...zip`，仅供 CI 测试，不是公证发行版。

## 构建与签名

```text
swift build
swift build -c release --product lingxi
swift build -c release --product LingXiMac
Scripts/build-app.sh --release
```

- ARM64 App Bundle：`dist/LingXiMac.app`
- Ad-hoc 签名校验通过
- 未做 Developer ID / Apple 公证

## 未验证范围

- 真实 Modrinth 资源包下载并在 Minecraft 内启用/截图。
- 真实 `.mrpack` 的新版本更新预览与更新执行。
- Fabric/NeoForge 复制实例的实际启动。
- 多启动器进程并发备份的实机竞争测试（仅实现锁和单元测试）。
- 磁盘空间耗尽和断电式中断的真机测试（仅实现失败路径测试）。

## 下一阶段必须完成

1. 整合包更新事务和 GUI 差异预览/确认/回滚。
2. 真实资源包安装与游戏内截图。
3. 真实复制实例启动、真实世界备份恢复。
4. 相应验收记录与 CI 实跑链接。
