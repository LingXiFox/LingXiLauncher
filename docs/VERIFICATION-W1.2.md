# W1.2 Cross-Platform Core Completion — 阶段记录

## 结论

W1.2 **尚未完成**。本阶段 Stage A 的文件安全基础已落地，Stage B/C/D 仍待继续；不得标记 W1.2 完成。

## 已完成（Stage A 部分）

### 平台原子替换

- 新增 `FileReplacing` / `FoundationFileReplacing` 平台协议。
- macOS：`MacFileReplacing`，保留 Foundation `replaceItemAt` 行为。
- Windows：`WindowsFileReplacing`，使用 `MoveFileExW(REPLACE_EXISTING | WRITE_THROUGH)`。
- `FabricInstaller`、`NeoForgeInstaller` 的 profile 替换已改走平台接口。
- 明确边界：这是**单文件替换**，不是跨文件事务原子性。
- Windows CI 已验证目标存在/不存在两种替换。

### Win32 文件锁

- `WindowsFileLocking` 使用 `LockFileEx(LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY)`。
- 10 秒重试超时；锁文件永久保留，避免删除锁文件造成 inode 竞态。
- 进程退出自动释放；同一测试进程互斥已验证。
- 仍未完成两个独立 CLI 进程的竞争测试。

### Windows ZIP

- central directory 解析、预检路径穿越、保留名、大小写冲突、符号链接、大小/数量限制。
- `readEntries()` 现在通过独立临时目录解压并返回**真实文件内容**，与 macOS 语义一致。
- `extract()` 拒绝符号链接，使用系统 `tar.exe` 解压并在事后校验。
- 仍需：解压到独立 staging 后提交、压缩炸弹实际比例测试、natives/JAR/mrpack 真实样本矩阵。

## 验证

- macOS：**336 tests / 0 failures**；Release CLI/GUI、App Bundle、arm64、ad-hoc 签名通过。
- Windows：**19 tests / 0 failures**；Core/CLI Debug、Release CLI 构建在 CI。
- CI：[41175243536](https://github.com/LingXiFox/LingXiLauncher/actions/runs/41175243536) — success。
- 代码提交：`1c2d336`。

## 未完成

1. Windows OAuth loopback 与 DPAPI/Credential Manager。
2. 共享 `LauncherCoreTests` 在 Windows 实际运行。
3. Windows Java 真实进程、Classpath、natives、PID 复用验证。
4. Windows CLI 端到端业务链路。
5. 跨进程锁竞争测试。
6. ZIP staging 提交与完整恶意样本矩阵。
7. Windows 系统信息/进程资源真实采样。

## 验收状态

| 项目 | 状态 |
|---|---|
| 共享 Core 无 OS 业务分支 | 通过 |
| macOS 回归 | 336 tests 通过 |
| Windows 原子替换 | 基础实现通过 |
| Windows 文件锁 | 基础实现通过；跨进程测试待补 |
| Windows ZIP 内容语义 | 基础实现通过 |
| Windows OAuth/凭据 | 未实现 |
| 共享 Core 测试双平台 | 未完成 |
| Windows CLI 端到端 | 未完成 |
| 双平台 CI | 当前提交通过 |

**W1.2 仍需继续，不能标记完成。**
