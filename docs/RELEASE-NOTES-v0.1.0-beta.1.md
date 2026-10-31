# LingXi Launcher v0.1.0-beta.1

首个 macOS Apple Silicon 公开测试基线（Pre-release）。最低系统要求 macOS 14，仅支持 arm64。

## 安装

1. 下载 `LingXiLauncher-v0.1.0-beta.1-macOS-arm64.zip`。
2. 使用 `SHA256SUMS.txt` 校验 ZIP。
3. 解压后将 `LingXiMac.app` 移动到 `/Applications`。
4. 本构建使用 **Ad-hoc 签名，未经 Apple 公证**。首次打开请在 Finder 中右键 App → **打开** → 再次确认 **打开**；或前往 **系统设置 → 隐私与安全性** 允许一次。不要永久关闭 Gatekeeper。

## 兼容性与功能

- Vanilla、Fabric、NeoForge 安装与启动。
- Microsoft 正版认证流程；自动化环境未执行真实交互登录。
- Modrinth 模组、资源包、光影与 `.mrpack` 整合包事务更新。
- Iris + Sodium 光影环境和 Shader Pack 管理。
- 实例复制、世界备份/恢复、崩溃诊断、性能工作台。
- 现有实例目录布局不变。

## 已知限制

- 未使用 Developer ID 签名，未公证；不能标记为稳定版或正式发行版。
- Microsoft 真实交互登录需要在有用户交互的机器上验证。
- 目标整合包更改 Minecraft/Loader 时阻止自动更新，应新建实例。
- 没有游戏内 FPS 采样时性能工作台明确显示不可用，不伪造数据。
- 世界备份默认手动，不自动创建大型备份。
- 仅支持 macOS 14+ Apple Silicon；Windows 尚未移植。

## 校验

- 完整 XCTest：336 tests，0 failures。
- Release CLI/GUI、ARM64 App Bundle、Info.plist 与 Ad-hoc 签名由 CD 再次验证。
- 任一检查失败时 CD 不会创建 Release。
