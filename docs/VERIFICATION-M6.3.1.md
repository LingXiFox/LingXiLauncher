# M6.3.1 + CI 验证记录

验证日期：2026-10-29  
环境：macOS 27.2、Apple Silicon arm64、Swift 6.4.2、Xcode 27  
测试基线：**275 tests, 0 failures, 0 skipped**  
Release：CLI + SwiftUI GUI 构建成功，`dist/LingXiMac.app` ad-hoc 签名校验通过

## 1. 整合包失败/取消后的重试

### 问题

`MrpackInstaller` 曾在所有退出路径清理 `MrpackPackage.extractionRoot`；GUI 仍持有已解析的 package，重试时 overrides 已不存在。另一方面，安装失败后直接启用 Modrinth 来源追踪，可能在重试前产生额外网络请求或把不完整状态写入实例。

### 修复

- 安装失败、下载失败、取消时**保留**已验证的 extractionRoot；成功提交后删除。
- staging 目录每次尝试使用独立 UUID，并在本次尝试结束时清理；不与 package 生命周期混用。
- `MrpackInstallRequest` 增加 `traceModrinthSources`（默认 false）；只有调用方明确请求才做哈希来源查询。
- GUI 的「重试安装」继续使用同一个 `MrpackPackage`，不重新解析、不重新下载 overrides。
- GUI `.onDisappear` 若安装仍在运行，先取消并等待 installer 停止，再清理 extractionRoot；安装中按关闭不会制造悬空任务。
- 连续取消、失败后重试、成功重试均由 `MrpackTests` 覆盖；GUI 按钮和 DebugAutomation 的 `mrpack.cancel` / `mrpack.retry` 绑定同一个 `install()` / `installTask` 路径。

回归测试：

```text
testNetworkFailureLeavesNoInstanceAndRetryUsesSamePackage
testCancellationPreservesPackageAndRetrySucceeds   # 连续两次取消后再次成功
testExistingInstanceIsNeverTouchedByNewPackInstall
```

## 2. 整合包模组来源追踪

新增 `Sources/LauncherCore/Modpack/MrpackSourceTracer.swift`：

- 从 external files 中筛出 `mods/*.jar`，只使用安装前 SHA-1/SHA-512。
- 通过 Modrinth 官方 `POST /v2/version_files`（`algorithm=sha1` 或 `sha512`）批量查询版本；若接口不可用，导入仍成功，文件保持 `local`。
- 只有返回版本的 `files[].hashes` 与本地文件哈希一致才接受项目/版本身份；随后读取项目标题、slug、许可证和图标。
- `ModRepository.attachSource` 写入 `projectID`、`versionID`、版本号、来源 `modrinth`、许可证和原始哈希；不会伪造来源。
- 未识别文件保持 `source = "local"`，不参与 Modrinth 更新检测；已识别文件会出现在 `lingxi mod updates` / GUI 更新列表。
- 来源查询失败作为 warning 返回，不导致已提交实例被删除；查询过程中的取消会走安装失败回滚路径。

回归测试：`M6ModrinthTests.testMrpackSourceTracingUsesVerifiedHashesAndKeepsUnknownLocal`，验证一个命中哈希的模组变为 `modrinth`，另一个无匹配文件保持 `local`。

## 3. `.mrpack` 兼容性

### 可信下载域

`MrpackParser` 按 Modrinth format 1 规范接受以下 **HTTPS** 下载域：

- `cdn.modrinth.com`
- `github.com`
- `raw.githubusercontent.com`
- `gitlab.com`

每个候选 URL 必须满足：HTTPS、无 user/password、端口为空或 443、host 在允许集合中。下载仍由 `Downloader` 执行大小限制、SHA-512 优先 / SHA-1 回退校验，并经过重定向安全策略（拒绝非 HTTPS、凭据、非标准端口和超过 3 次跳转）。解析器只接受带有至少一种哈希和明确 `fileSize` 的文件。

### optional 客户端文件

- `env.client == "optional"` 不再默认安装。
- 解析后 GUI 显示可选文件开关，默认关闭；只有用户显式勾选才下载并提交。
- `MrpackPackage.selectedFiles(includingOptionalPaths:)` 是唯一选择入口；下载数量、字节数、staging 和报告都使用同一集合。
- `env.client == "unsupported"` 仍跳过；`required` 仍必须安装。

回归测试：

```text
testOptionalClientFilesRequireExplicitSelection
testTrustedDownloadHostsAndRedirectSafety
testRedirectPolicyRejectsInsecureOrCredentialedTargets
```

## 4. 数据安全

- 安装始终创建新实例；`OneStopInstaller` 的现有目标检测在下载前拒绝已有实例。
- 所有 external 文件先进入 `dataRoot/cache/mrpack/<archive-sha256>/`，校验通过后才进入 staging。
- 提交阶段先备份被替换文件，失败回滚；只有全部成功才清除 package extractionRoot。
- 失败/取消不会删除已有实例、模组、配置或存档；`testExistingInstanceIsNeverTouchedByNewPackInstall` 覆盖已有实例保护。
- ZIP 安全规则继续覆盖路径穿越、绝对路径、反斜杠、符号链接、ZIP64、条目数/大小上限。

## 5. GitHub Actions CI

工作流：`.github/workflows/ci.yml`

- 触发：push `main`、pull request、`workflow_dispatch`。
- Runner：GitHub 官方 `xcode-27`（Apple Silicon arm64）。
- 权限：仅 `contents: read`；checkout 不持久化凭据。
- 并发：同 workflow/ref 取消旧运行；60 分钟超时。
- 步骤：
  1. `swift build`（Debug）
  2. `swift test`（完整 XCTest，失败即停）
  3. Release CLI + GUI 构建
  4. `Scripts/build-app.sh --release`
  5. Info.plist、Bundle 可执行文件、arm64、ad-hoc 签名校验
  6. 压缩并上传 `LingXiMac-ci-<sha>.zip` Artifact（保留 7 天）
- 不执行 Microsoft 登录、真实 Minecraft 下载或图形桌面游戏启动。
- Artifact 仅为 CI 测试产物，**不是** Developer ID 签名或公证发行版。

本地等价验证：

```text
swift build
swift test
swift build -c release --product lingxi
swift build -c release --product LingXiMac
Scripts/build-app.sh --release
plutil -lint dist/LingXiMac.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 dist/LingXiMac.app
```

本地结果：Debug 构建通过；**275 tests / 0 failures / 0 skipped**；Release CLI/GUI 通过；App Bundle 为 arm64、Info.plist 合法、ad-hoc 签名 `valid on disk` 且满足 designated requirement。

## 6. 范围与后续

本阶段没有新增 Forge/NeoForge/Quilt/CurseForge；没有改动 Microsoft 认证、Keychain、系统 Java 或正式发行签名。真实 CI 运行链接在首次 push 后补充到 Actions 页面和 README 徽章。
