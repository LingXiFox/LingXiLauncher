# W1.1 Windows Functional Parity — 阶段验证记录

## 1. 结论

本阶段尚未达到 W1.1 完整验收标准。已完成 **Windows Core/CLI 可构建、Windows ZIP 安全层、双平台 CI 和 18 项 Windows 契约测试**；但 Win32 原子替换、Win32 内核文件锁、Windows OAuth/DPAPI、完整共享 LauncherCoreTests 迁移仍未完成。

不得将本记录表述为 Windows 功能对等完成。

## 2. 已完成

### 平台拆分

- `LauncherCore` 不包含 `#if os(macOS)` / `#if os(Windows)`。
- macOS 行为保留在 `Sources/MacPlatform`。
- Windows 实现位于 `Sources/WindowsPlatform`。
- 平台能力通过 `PlatformRuntime` 注入：host、file lock、system profiler、graphics、credentials、archive、process、OAuth。
- 唯一剩余 Core 条件导入是 `canImport(FoundationNetworking)`，用于 Windows 的 `URLSession` 类型；不是业务分支。

### Windows ZIP

新增 `Sources/WindowsPlatform/WindowsArchiveHandler.swift`：

- 在 Swift 中解析 ZIP central directory，支持 Stored/Deflate 方法标记。
- 预检路径穿越、绝对路径、驱动器路径、反斜杠、`.`/`..`、Windows 保留名、尾随点/空格、大小写冲突。
- 预检条目数量、单条目大小、总解压大小。
- 使用 Windows 系统 `tar.exe` 执行实际解压。
- 解压后再次扫描符号链接、路径和大小，失败清理目标目录。
- 已通过 Windows CI 的真实 ZIP 读取/解压测试。

### Windows 平台基础

- Windows Host：x86_64、`;` 路径分隔符、`%APPDATA%` 数据目录。
- 系统信息：逻辑核心、物理内存。
- 进程检测：`tasklist` / `taskkill`。
- 文件锁：`LockFileEx` 内核级字节锁，10 秒超时、进程退出自动释放；锁文件不删除以避免 inode 竞态。
- 图形探测：明确 unavailable。
- 凭据存储：仍是内存实现。
- OAuth：明确 unsupported。

### 构建与测试

- macOS：**336 tests / 0 failures**。
- Windows：**18 tests / 0 failures**。
- Windows CI：Core、CLI Debug 构建，`PlatformCompatibilityTests`（含 Win32 锁互斥和 ZIP 安全用例）。
- macOS CI：完整测试、Release CLI/GUI、App Bundle、签名、Artifact。
- CI 运行：[41173827305](https://github.com/LingXiFox/LingXiLauncher/actions/runs/41173827305) — success。
- 最终代码提交：`b8f2f48`。

## 3. 未完成（阻塞 W1.1 验收）

1. **Win32 原子替换未实现**：Core 仍使用 Foundation `replaceItemAt` 或是移动操作；Windows 未接入 `MoveFileExW`/`ReplaceFileW`。
2. **Win32 文件锁已实现但仍需跨进程 CLI 验证**：已使用 `LockFileEx` 并通过同进程互斥测试；尚无两个独立 `lingxi` 进程的真实竞争测试。
3. **Windows ZIP 不是完整 ZIP 实现**：`readEntries` 不返回条目内容；依赖 `tar.exe`，尚未覆盖所有 JAR/`.mrpack` 解压路径。
4. **Windows OAuth 未实现**：没有 loopback listener，CLI 登录返回 unsupported。
5. **Windows Token 存储未实现**：仍是 `InMemoryRefreshTokenStore`，不持久化、不具备 DPAPI/Credential Manager 语义。
6. **共享 LauncherCoreTests 未迁移到 Windows**：Windows 仍只跑 18 项契约测试，未覆盖 Manifest、VersionResolver、RuleEvaluator、DependencyResolver、LaunchPlanBuilder、Modrinth、Fabric、NeoForge、Mrpack、ModpackUpdateManager 等共享业务测试。
7. **Java/进程管理不完整**：没有真实 Windows Java 启动、Classpath、natives、stdout/stderr、PID 复用防护验证。
8. **无真实 Windows 游戏/CLI 业务链路验证**：仅 CI 编译和契约测试。
9. **Linux 未接入**。

## 4. 验收状态

| 项目 | 状态 |
|---|---|
| Core 无平台条件分支 | 基本通过（仅 FoundationNetworking 条件导入） |
| macOS 行为不变 | 336 tests 通过，未改 GUI |
| Windows Core/CLI 构建 | 通过 |
| Windows ZIP 安全测试 | 通过（18 项中的 ZIP 用例） |
| Win32 原子替换 | 未完成 |
| Win32 文件锁 | 基本通过，跨进程 CLI 验证待补 |
| Windows OAuth/凭据 | 未完成 |
| 共享 Core 业务测试双平台 | 未完成 |
| macOS CI/CD 保持 | 通过 |
| Windows CI 全绿 | 通过（但仅 18 项） |

**W1.1 仍需继续，不能标记完成。**
