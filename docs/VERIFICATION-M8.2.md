# M8.2 Modpack Lifecycle & Data Safety — 验证记录

## 状态

本记录只报告实际完成的内容。**整合包更新事务、真实 `.mrpack` 内容差异、GUI 更新页和真实 Minecraft 更新验证尚未完成**，不能标记为 M8.2 完成。

## 自动化测试

```text
swift test
Executed 323 tests, with 0 failures (0 unexpected)
```

## 已完成

### 实例复制

- `InstanceCopyService` 新增复制 `<instance>/resourcepacks.json`。
- `mods.json`、`shaderpacks.json`、`resourcepacks.json`、`modpack.json` 均从实例元数据目录复制。
- 复制测试增加资源包元数据逐字节断言。
- 启用/禁用模组、光影 ZIP、资源包 ZIP、可选 `saves/` 仍保持隔离。
- 不复制全局 `libraries/`、`assets/` 或下载缓存。

### 资源包删除事务

- 删除前将 managed ZIP 移动到同目录事务备份。
- 删除时同步从受支持版本的 `options.txt` 移除 `file/<name>`。
- 元数据写入失败时恢复 ZIP、`options.txt` 和旧元数据。
- 运行中仍通过 `InstanceRuntimeRegistry` 拒绝操作。
- 未管理文件不会被删除。

### 整合包版本身份

- `ModpackRecord` 新增 `packVersionID`、`modrinthProjectID`、`modrinthVersionID`。
- 旧 `versionID` 只作为 `.mrpack` 内部 `versionId` 读取，不再当成 Modrinth API 版本 ID。
- 旧 `modpack.json` 无新字段时可解码；`checkUpdate` 对缺少可信 Modrinth 版本 ID 的记录返回明确错误。
- 手动关联项目只写项目 ID，不推断当前 Modrinth 版本。
- 新增旧数据迁移与“不猜测版本”测试。

## 未完成

- 目标 `.mrpack` 下载、哈希/大小校验、`MrpackParser` 解析与真实内部文件差异。
- `ModpackUpdateManager` 的 preflight/download/stage/snapshot/commit/rollback/validate 事务。
- 用户修改检测、冲突策略、更新恢复目录和未完成事务恢复。
- GUI 更新差异预览与执行；CLI 更新预览/确认/恢复。
- 真实 Modrinth 资源包进入游戏、真实实例复制启动、真实 `.mrpack` 更新与故障注入。
- 资源包跨文件名更新仍会保留旧文件；当前 `allowReplace` 只处理同名替换。

## 风险

- 资源包更新跨文件名时未完成迁移，可能残留旧 ZIP 和旧启用记录。
- 无实例级资源包更新锁；并发更新仍可能竞争。
- 世界备份和实例复制只有合成测试，没有 M8.2 真实运行证据。

## 构建

```text
swift build
swift test
swift build -c release --product lingxi
swift build -c release --product LingXiMac
Scripts/build-app.sh --release
```

均通过；ARM64 App Bundle 与 ad-hoc 签名有效。CI 链接在提交后补充。
