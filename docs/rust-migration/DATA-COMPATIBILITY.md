# 数据兼容性

目标：升级到 Rust 版后，能直接读取 Swift 版留下的账户、实例、模组、世界备份与整合包记录，不要求用户手工迁移。

## 目录布局

Rust 的 `GameDataLayout` 与 Swift 一致：

- 游戏根：官方 `.minecraft`（可通过 `--root` 或 `LINGXI_GAME_ROOT` 覆盖）。
- 数据根：平台应用数据目录（可通过 `--data-root` 或 `LINGXI_DATA_ROOT` 覆盖）。
- 实例：`<dataRoot>/instances/<instance-id>/`，实例游戏目录为 `<dataRoot>/.minecraft/versions/<instance-id>/`。
- 账户：`<dataRoot>/accounts/`（本地账户、Microsoft 账户、active 引用）。
- 备份：`<dataRoot>/backups/<instance-id>/<backup-id>/`。
- 设置：`<dataRoot>/settings.json`。
- 日志：`<instance-game-dir>/logs/`，与 Swift 的 `instanceLogsDirectory` 对齐。

## 已实现兼容

### `instance.json`

`JavaRuntimeRecord` 已按 Swift 字段输出/读取：

- `version`、`majorVersion`、`architecture`、`executable`、`vendor`、`checksum`、`source`
- `component`、`artifactSHA1`、`artifactSHA256`、`executableSHA256`、`recordedAt`
- `source` 缺失或为 `null` 时回退为 `"system"`；`recordedAt` 缺失时使用当前时间。
- Tauri 手动选择 Java 时写入 `source: "manual"` 与完整字段。

### `mods.json`

- Swift 允许 `projectID`、`slug`、`versionID`、`versionNumber`、`sha1`、`sha512`、`license`、`iconURL` 为 `null`；Rust 读取时统一转换为空字符串。
- `ModSource` 的本地来源序列化为 `"local"`，同时接受旧 Rust 的 `"manual"`。
- 因此 Swift 写入的模组列表可直接显示、启停、删除，不再因空字段导致整份 JSON 反序列化失败。

### 世界备份

Swift 备份是目录格式：

```
<dataRoot>/backups/<instance-id>/<backup-id>/
  manifest.json
  world/
```

`manifest.json` 字段：`schemaVersion`、`id`、`instanceID`、`worldName`、`createdAt`、`fileCount`、`totalBytes`、`files[{relativePath,byteCount,sha256}]`。

Rust 现在：

- 新建备份使用相同目录结构，不再只写 zip。
- `list_backups` 优先读取目录 manifest，同时保留旧 zip 读取。
- 恢复时校验 `instanceID`、每个文件的 SHA-256 与大小，复制到临时目录后再次校验，要求 `level.dat` 存在，再原子替换；目标世界已存在时拒绝覆盖。
- 删除备份会校验 manifest 的实例归属。

### `modpack.json`

Swift 的 `ModpackRecord`（`schemaVersion` + `versionID` + `files[].byteCount`）可以通过 `read_manifest` 读取，转换为 Rust 的展示模型：

- 名称使用实例显示名，版本使用 `packVersionID`（没有则 `versionID`）。
- 文件列表保留路径、SHA-1、SHA-512、大小。
- `loaderKind` / `loaderVersion` / `minecraftVersion` 转为 loader 与依赖表。
- **不映射** `modrinthProjectID` 到可更新项目，避免误触更新后用 Rust 格式覆盖旧记录；旧记录是只读展示。

## 单向兼容边界

- Rust 新安装或更新的整合包写 Rust 自有 `modpack.json` 结构，Swift 旧版不能反向读取。升级是单向的：旧数据 → Rust 可读；Rust 新数据不承诺旧 Swift 可读。
- 设置：Swift 使用 `@AppStorage`，Rust 使用 `<dataRoot>/settings.json`。首次运行且没有 `settings.json` 时，macOS 读取 `com.lingxifox.LingXiLauncher` 的 `lingxi.*` 偏好并迁移；已有 Rust 设置不覆盖，损坏文件保留原文件。
- 性能报告：Rust 写入 `<dataRoot>/performance/` 自有报告结构；Swift 旧报告位于 `<dataRoot>/performance/reports/*.json`，Rust 以只读方式解析并展示，不改写旧文件。
- 账户密钥：Microsoft 令牌写入系统凭据存储（macOS Keychain / Windows DPAPI / Linux Secret Service）。macOS 兼容旧 Swift service `com.lingxifox.LingXiLauncher.microsoft` 与小写 UUID account；读取后写入新 service 并删除旧项。

## 测试

`CARGO_HOME=$PWD/.cargo-home cargo test -p launcher-core` 覆盖：

- `worlds::tests::directory_backup_roundtrip`：目录备份 → 列表 → 恢复 → 校验 region 文件 → 删除。
- `modpack::tests::reads_swift_pack_record_without_rewriting`：读取 Swift `modpack.json` 后字段正确，且原文件字节不变。
- `mods`、`modrinth`、`graphics` 等模块的解析/写入测试。
