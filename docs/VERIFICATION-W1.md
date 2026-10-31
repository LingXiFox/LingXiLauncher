# W1 跨平台 Core 验证记录

## 1. 结论

`LauncherCore` 已从仅 macOS 的构建拆分为：

- 平台无关的 `LauncherCore`；
- macOS 实现 `MacPlatform`；
- Windows 实现 `WindowsPlatform`；
- macOS SwiftUI 客户端 `LingXiMac`；
- 各平台独立 CLI 入口。

macOS ARM64 上完整 336 项 XCTest 通过；Windows x86_64 上 Core/CLI 构建通过，新增的 16 项平台兼容测试全部通过。CI 使用独立的 `windows-2022` Runner，因为当前 `windows-2025` Runner 的 Swift 6.2.1 工具链与 VS18 STL 不兼容（clang 19 对 clang 20 标准库）。

## 2. 架构变化

### LauncherCore

Core 不再包含 Darwin、Security、Compression、Metal、OpenGL、CryptoKit 或平台 `#if os` 分支。平台能力通过 `PlatformRuntime` 注入：

- `PlatformHostProviding`：OS、CPU 架构、路径分隔符、默认数据目录；
- `FileLocking` / `FileLockToken`：跨进程实例锁；
- `SystemProfiling`：硬件、进程身份、资源采样；
- `GraphicsProbing`：OpenGL 能力探测；
- `RefreshTokenStoring`：凭据存储；
- `ArchiveHandling`：ZIP 读取与安全解压；
- `ProcessInspecting`：进程存活与终止；
- `OAuthAuthorizing` / `BrowserOpening`：登录流程。

`Crypto`（官方 `apple/swift-crypto` 3.15.1）用于 SHA-1、SHA-256、SHA-512、HMAC 与 PKCE。

### MacPlatform

新增并迁移：

- `MacHost`、`MacFileLocking`、`MacSystemProfiler`、`MacGraphicsProbe`；
- `MacKeychainCredentialStore`；
- `MacOAuthAuthorizer`；
- `MacArchiveHandler`；
- `MacProcessInspector`；
- `MacPlatform.install()`。

macOS 的 Keychain、OpenGL 4.1、ZIP/Compression 行为保持原语义；M9.1 的发布功能未改变。

### WindowsPlatform

新增：

- `WindowsHost`：`;` 路径分隔符、`%APPDATA%\LingXiLauncher` 默认数据目录；
- `WindowsFileLocking`：独占锁文件；
- `WindowsSystemProfiler`、`WindowsProcessInspector`；
- `WindowsGraphicsProbe`：当前明确返回“不支持探测”，不伪造 GPU 能力；
- Windows CLI 入口。

Windows 当前是 **Core/CLI 可构建、可测试**，不是完整 GUI 发行版。尚不支持 Windows GUI、Microsoft 回环登录、Keychain 等价凭据存储、ZIP 安装和图形探测；这些能力会返回明确错误，不会伪造成功。

## 3. 构建与测试

本地 macOS ARM64：

```text
swift build                                      success
swift test                                       336 tests, 0 failures
swift build -c release --product lingxi          success
swift build -c release --product LingXiMac       success
Scripts/build-app.sh --release                   success
codesign --verify --deep --strict                valid
```

App：

- `dist/LingXiMac.app`，约 16 MB；
- `arm64`；
- `CFBundleShortVersionString = 0.1.0`；
- Ad-hoc 签名，未公证。

Windows x86_64 CI：

```text
swift build --product LauncherCore               success
swift build --product lingxi                     success
swift test --filter PlatformCompatibilityTests   16 tests, 0 failures
```

平台测试覆盖：host context/arch/path separator、默认数据目录、系统内存与核心数、当前进程探测、文件锁互斥/重入、图形探针不崩溃、凭据存储往返、路径穿越拒绝、归档限额与 Runtime 注入。

## 4. CI

- 运行：[CI #41165462029](https://github.com/LingXiFox/LingXiLauncher/actions/runs/41165462029) — **success**
- macOS job：Debug 构建、336 tests、Release CLI/GUI、App Bundle、签名、Artifact。
- Windows job：`windows-2022`、Swift 6.2.1、Core/CLI Debug 构建、16 项平台兼容测试。
- 最终代码提交：`714835d`（文档提交见仓库历史）。

## 5. 已知限制

1. Windows 未做真实游戏启动/GUI 验证；CI 只证明 Core/CLI 构建与平台契约测试。
2. Windows 的 ZIP、OAuth、图形探测和持久凭据仍为明确 unsupported；Windows 玩家暂不能完成完整安装/登录流程。
3. Linux 平台尚未接入 CI；`PlatformRuntime` 已有 Foundation fallback，但没有发行级验证。
4. 现有 macOS 完整测试中的平台专属测试不会在 Windows 重跑；Windows 以 16 项跨平台契约测试为准。
5. `swift-crypto` 是新增的官方第三方包；这是 W1 为消除 CryptoKit 平台绑定所做的必要依赖，已固定在 3.15.1。

## 6. 验收判定

- Core 平台条件分支清除：**通过**
- macOS 完整构建/测试/打包：**通过**
- Windows Core/CLI 构建：**通过**
- Windows 15+ 兼容测试：**通过（16 项）**
- Windows 完整功能/真实游戏：**未完成，按已知限制记录**
