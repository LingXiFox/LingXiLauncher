# M3 Microsoft 认证 + M5-Alpha SwiftUI GUI 真机验证记录

日期：2026-10-27（Asia/Shanghai）
主机：macOS 27.2 / Apple Silicon arm64
工具链：Xcode 27.2 / Swift 6.4.2
游戏：Minecraft Java Edition 1.20.1（`.dev-sandbox`，未提交仓库）
Java：Microsoft OpenJDK 17.0.20.1 arm64

## 1. 配置

- Entra 应用（public client）：`LingXi Launcher`
- Client ID：`4c990be6-c02d-4f0d-84f6-c3d6785f2a36`（公开标识，已内嵌于 `MicrosoftAppRegistration`）
- Authority：`https://login.microsoftonline.com/consumers`
- Redirect URI：`http://localhost`（运行时随机端口）
- Scopes：`XboxLive.signin`、`offline_access`
- **无 Client Secret，无 `auth.json`**

Minecraft AppID 审核：项目所有者确认已于 **2026-10-26** 通过 Mojang 官方审核并加入 API Allow List。

## 2. CLI 真实登录

```bash
swift build
.build/debug/lingxi account microsoft login \
  --root .dev-sandbox/mc --data-root .dev-sandbox/data
```

实际结果（完整输出见 `.dev-sandbox/evidence/cli-login.txt`）：

```text
Starting Microsoft sign-in (a browser window will open)…
  Opening the system browser…
  Waiting for the Microsoft callback…
  Exchanging the authorization code…
  Authenticating with Xbox Live…
  Authorizing with XSTS…
  Signing in to Minecraft Services…
  Verifying Minecraft ownership and profile…
Microsoft sign-in complete
--------------------------
  player                 Ling_Xi_Fox
  uuid                   ee1d1605-5048-42b2-925f-d1032b1909dd
  xuid                   2535406936984702
  ownership              verified
  token storage          refresh token saved in macOS Keychain
```

验证点：

- 系统浏览器 + localhost 回调真实完成；Authorization Code + PKCE S256（单元测试覆盖 verifier/challenge 与 state 拒绝）。
- Xbox Live → XSTS → Minecraft Services → entitlements/profile 全链路成功。
- 玩家 UUID 与档案名来自 Minecraft Services，不是本地伪造。
- 所有权由 `mcstore` entitlements 与 profile 联合验证；结果 `ownsGame=true`。
- 只把 refresh token 写入 Keychain（service `com.lingxifox.LingXiLauncher.microsoft`）；账号 JSON 仅包含 UUID/name/xuid/ownership/时间，不含 token。
- 新进程 `account microsoft status` 与真实 `launch` 均通过 Keychain 刷新成功，证明跨进程恢复。

XUID 说明：本账号的 XUID 通过独立 XSTS audience（`http://xboxlive.com`）+ Xbox profile service 获取。若该请求不可用，代码允许以显式 `0` 继续启动本地游戏，在线功能可能受限；不会伪造所有权。

## 3. CLI 正版启动

```bash
.build/debug/lingxi launch \
  --instance dev-1201 \
  --identity microsoft:ee1d1605-5048-42b2-925f-d1032b1909dd \
  --java /Library/Java/JavaVirtualMachines/microsoft-17.jdk/Contents/Home/bin/java \
  --root .dev-sandbox/mc --data-root .dev-sandbox/data
```

结果：

- 新进程先从 Keychain 读取 refresh token，刷新 Microsoft/Xbox/Minecraft 会话；日志出现 `Refreshing Microsoft session for Ling_Xi_Fox...`。
- 游戏窗口 `Minecraft 1.20.1` 启动；`latest.log` 出现 `Setting user: Ling_Xi_Fox`。
- 无 `InvalidCredentialsException` 等正版认证失败；启动器收到正常退出码 **0**。
- 启动器日志的 argv 预览将 `--accessToken` 显示为 `<redacted>`；账号元数据无 token。

## 4. GUI 构建与真机操作

```bash
Scripts/build-app.sh
# 开发沙盒（直接执行 bundle 内二进制以传入环境变量）
LINGXI_DATA_ROOT="$PWD/.dev-sandbox/data" \
LINGXI_GAME_ROOT="$PWD/.dev-sandbox/mc" \
  ./dist/LingXiMac.app/Contents/MacOS/LingXiMac
```

`xcodebuild -scheme LingXiMac -destination 'platform=macOS' build` 也通过。

已实际操作并截图（证据在 `.dev-sandbox/evidence/`，因含 Mojang 美术资源未提交）：

| 页面/操作 | 证据 | 结果 |
|---|---|---|
| 首页 + 正版账户 + Java 17 自动选择 | `gui-home-microsoft.png` | 显示 `Ling_Xi_Fox · Microsoft`、Java 17.0.20.1 arm64 |
| 账户页 | `gui-accounts-microsoft.png` | UUID、`所有权已验证`、最近验证时间；本地 DevPlayer 明确标注未验证且 GUI 不提供启动 |
| GUI 内发起 Microsoft 登录 | 实际操作 | 浏览器完成 OAuth，状态依次经过 Xbox Live/XSTS/Minecraft/所有权，账户更新成功 |
| 实例页 | `gui-instances-microsoft.png` | 实例详情、单一 `.minecraft` 隔离路径、自动/手动内存入口、启动/删除 |
| 下载页 | `gui-downloads-verify.png` | 官方 1.20.1 安装（缓存命中）后 **3636 个文件完整性验证通过** |
| GUI 启动游戏 | `gui-logs-live-microsoft.png` | 直接从 GUI 启动，实时输出 `Setting user: Ling_Xi_Fox`；进程树为 GUI → java，无 `lingxi` 子进程 |
| 正常退出 | `gui-logs-exit-0.png` | `Game exited with code 0 (exited)`，侧栏恢复“未运行” |
| 游戏主菜单 | `mc-main-menu-microsoft.png` | 1.20.1 主菜单完整渲染 |

GUI 的启动路径使用 `LaunchService`（LauncherCore），与 CLI 共享 VersionResolver/DependencyResolver/LaunchPlanBuilder/GameProcessController；GUI 不执行 CLI、不解析 CLI 输出。

## 5. 退出/登出

- CLI `account microsoft logout --account <uuid>` 成功删除账号元数据与 Keychain refresh token；随后 status 为空。
- 已重新登录恢复账户用于最终验证。
- GUI 的“退出”按钮调用同一个 `MicrosoftAuthenticationService.signOut`（未在截图中单独演示）。

## 6. 测试

```text
swift test
Executed 231 tests, 0 failures
```

覆盖：配置/内嵌注册、PKCE RFC 7636 向量、OAuth URL/表单、state 不匹配拒绝、真实 loopback 回调、Xbox/XSTS/Minecraft/所有权/403/404、refresh 过期、Keychain round-trip、账户元数据无 token、皮肤/披风 Profile 解析、LaunchService 失败事件、单一 `.minecraft` 迁移、自动/手动内存、M2.5 回归。

## 7. 已知限制（不得当作已验收）

1. 真实登录使用了本机浏览器已有的 Microsoft 会话（SSO），未在全新浏览器配置下重走“输入密码 + 首次 consent”页面。
2. 游戏只验证到主菜单并正常退出 0；未创建新世界、未验证世界内玩法/多人/Realms。
3. 1.20.1 返回 Realms “Client incompatible” 提示，是旧版本对新 Realms 的兼容性提示，不是认证失败；未用最新版本复测。
4. GUI 取消下载路径已实现（Task cancellation + 下载器检查），但本次未在真实大文件下载中途执行取消。
5. GUI 下载的本次操作是 1.20.1 缓存命中 + 全量验证；大文件全新下载的 M2 CLI 路径已在此前验证，GUI 进度回调未做全新大文件实测。
6. 未测试 Intel Mac、未做 Developer ID 签名/公证；当前 `.app` 为 ad-hoc 签名。
7. XUID 依赖额外的 Xbox profile 请求；失败时占位 `0` 会限制在线功能。
8. Fabric/M4 未实现。
