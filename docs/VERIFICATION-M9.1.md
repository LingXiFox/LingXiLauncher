# M9.1 Release Engineering 验证记录

基线：`9280f51`（M9.0，334 tests，CI #22）。
发布目标：`v0.1.0-beta.1`，macOS Apple Silicon ARM64，Ad-hoc 签名，Pre-release。

## 1. RC 安全修复

### 原始哈希与当前文件状态

`ModpackFileRecord` 新增：

- `originalSHA256`：已验证整合包提供的原始文件哈希，用户保留修改时不得覆盖。
- `currentSHA256`：最近一次安装/更新后磁盘上的实际哈希。
- `originalHash` / `currentHash`：兼容旧记录的读取入口；旧记录缺少字段时回退到 `sha256`。

更新计划中的 `ModpackUpdateFileChange.currentSHA256` 记录实际磁盘状态，并纳入预览签名。保留用户修改后再次预览，仍以 `originalSHA256` 作为官方基线、`currentSHA256` 作为当前状态，因此连续多次更新仍能识别本地修改。

### 危险 CLI 操作

```bash
lingxi world restore ... --confirm
lingxi world delete ... --confirm
```

缺少 `--confirm` 时在访问实例或备份之前返回 usage error。GUI 仍使用自己的确认对话框。

### 回归测试

新增 `testPreservedUserEditKeepsOfficialOriginalHashAndUpdatesCurrentHash`：

1. 用户修改已管理文件。
2. 预览标记 `userModified`，当前哈希与目标哈希不同。
3. 应用后保留用户文件，官方原始哈希不变，当前哈希更新。
4. 再次预览仍识别用户修改。
5. 预览后再次修改文件，旧签名被拒绝，文件保持不变。

测试总数：**336**，0 failures。

## 2. 版本与构建

- `LauncherInfo.version = 0.1.0-beta.1`
- `CFBundleShortVersionString = 0.1.0`
- `CFBundleVersion = 1`
- `Scripts/build-app.sh`：`codesign` 失败立即退出，并执行 `codesign --verify --deep --strict`。
- 本地 Release CLI/GUI 构建成功。
- App Bundle：`com.lingxifox.LingXiLauncher`，arm64，Ad-hoc，`TeamIdentifier=not set`。
- ZIP：`LingXiLauncher-v0.1.0-beta.1-macOS-arm64.zip`
- 本地 SHA-256：`3fd505efaa676b08d46b01fe477c797361444121b228f9c0562af677a8f0eefc`

> 最终发布包由 GitHub Actions CD 重新构建，最终 SHA-256 以 Release 页面 `SHA256SUMS.txt` 为准。

## 3. CD 设计

`.github/workflows/release.yml`：

- 仅语义化 `v*` Tag 触发发布；`workflow_dispatch` 只构建验证，不创建 Release。
- Tag 必须匹配 `vMAJOR.MINOR.PATCH[-alpha|beta|rc.N]`。
- 校验 `LauncherInfo.version` 与 Tag、Info.plist 基础版本一致。
- Debug build、完整 XCTest（有 skip 即失败）、Release CLI/GUI、`build-app.sh`。
- 校验 Bundle ID、版本、arm64、Ad-hoc 签名。
- ZIP 使用 `ditto` 保留 App 属性；生成 SHA256SUMS 与 Release Notes。
- 发布 Job 仅拥有 `contents: write`；重复 Tag 直接失败。
- 创建 Pre-release，上传 ZIP 与 SHA256SUMS。
- 不执行真实 Microsoft 登录、大型游戏下载或图形启动。

## 4. 真实游戏验证

M9.1 不重复下载大型游戏，沿用 M9.0 已完成的真实证据：

| 项目 | 结果 |
|---|---|
| Vanilla 1.21.1 | ✅ |
| Fabric 1.20.1 | ✅ |
| NeoForge 1.21.1 / 21.1.265 | ✅ |
| Fabric + Iris + Sodium + Complementary | ✅ |
| Modrinth 资源包 | ✅ Fresh Animations |
| 复制实例启动 | ✅ |
| 世界备份/恢复 | ✅ 15,879,044 bytes，21 files |
| `.mrpack` 真实更新 | ✅ 5.4.0 → 5.3.3 |
| 事务故障注入 | ✅ 自动化 |
| Microsoft 正版登录 | ⚠️ 未在自动化环境验证，未伪造成功 |

详见 [M9.0 验证记录](VERIFICATION-M9.0.md) 与 `docs/evidence/`。

## 5. RC 准入检查表

- [x] P0 事务备份持久化、回滚失败保留、committed 恢复只清理。
- [x] P1 原始/当前哈希分离，连续更新可识别用户修改。
- [x] 预览签名覆盖当前实际内容哈希。
- [x] 预览后文件变化拒绝执行。
- [x] 世界恢复/删除要求 `--confirm`。
- [x] 336 tests / 0 failures。
- [x] Debug、Release CLI/GUI、App Bundle、Ad-hoc 签名本地通过。
- [x] 发布工作流版本/Tag/签名/校验和/重复发布保护。
- [x] M9.0 真实游戏矩阵证据保留。
- [ ] Microsoft 真实交互登录（需用户账号）。
- [ ] Apple Developer ID 签名与公证（明确排除）。

## 6. 已知问题

1. Microsoft 登录未在自动化环境完成交互验证。
2. Ad-hoc 构建未经公证，必须按 Release Notes 的手动允许方式打开。
3. 目标整合包更改 Loader/Minecraft 时拒绝自动更新。
4. 真实断电式崩溃未注入；使用状态损坏/备份缺失/恢复失败等故障注入覆盖。
5. 最终 CD 运行链接和 Release 资源 SHA-256 以 GitHub Actions / Release 页面为准。
