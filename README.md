# LingXi Launcher

[![CI](https://github.com/LingXiFox/LingXiLauncher/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/LingXiFox/LingXiLauncher/actions/workflows/ci.yml)

macOS Apple Silicon 原生 **Minecraft: Java Edition** 启动器。当前进度：**M0 + M1 + M2 + M2.5 + M3 + M5-Alpha + M6.1 + M6.1.1 + M6.2 + M6.2.1 + M6.3 + M6.3.1 + M7.1 + M7.1.1 + M7.2 + M7.3 + M8**。

- **M3 Microsoft 正版认证已实现并通过真机验证**：OAuth 2.0 Authorization Code + PKCE S256、系统浏览器、localhost 回调、Xbox Live → XSTS → Minecraft Services → 所有权/档案、Keychain 存储与刷新。
- **M5-Alpha SwiftUI GUI 可用**：首页 / 游戏实例 / 版本下载 / 账户管理 / 运行日志 / 设置，直接调用 LauncherCore，不执行 CLI。
- 已使用真实 Microsoft 正版账号完成所有权、Keychain 刷新与 CLI/GUI 启动验证（1.20.1 主菜单，正常退出 0）。
- **M6.1 一站式安装**：VersionResolver 支持 `inheritsFrom` 合并；Fabric Loader（官方 meta/Maven）安装；JavaManager 按元数据检测/下载托管 Temurin；GUI 安装向导默认创建新实例，更新现有实例需显式确认并备份。
- **M6.2 Modrinth 模组管理**：Fabric 实例的 Modrinth 搜索、兼容性过滤、依赖自动解析、JAR 哈希校验、本地启用/禁用/删除、更新检测与原子更新；GUI 实例详情提供双视图。
- **M6.1.1 稳定性**：托管 JDK 完整校验后安全替换（失败恢复旧版本）；向导切换版本/Loader 后即时重验 Java；补充 Fabric 1.16.5/1.20.1/1.21.11/26.3 真实元数据矩阵。
- **M6.2.1 模组稳定性**：依赖冲突只在启用的实际版本上判定；更新保留禁用状态；更新检测按渠道和自然版本号而非仅日期；DebugAutomation 仅 Debug + 会话 token。
- **M6.3 整合包**：按 Modrinth format 1 解析 `.mrpack`，安全 ZIP/overrides、外部文件哈希下载、OneStop 安装、独立新实例；M6.3.1 修复失败/取消后的同包重试，支持官方下载域、可选客户端文件和 Modrinth 哈希来源追踪；GUI/Finder 拖放导入。
- **M7.1 图形与光影**：Fabric 1.20.1 上可安装兼容的 Iris + Sodium；独立的 `shaderpacks/` 管理器支持 Modrinth 搜索、版本选择、哈希校验、启用/停用、替换/更新和本地 ZIP 导入。Iris 配置只修改 `config/iris.properties` 的 `shaderPack` / `enableShaders`，并保留注释和未知键；macOS 的 OpenGL 4.1 限制会在 GUI 中明确提示，不宣传不存在的 Metal 光追。
- **M7.1.1 图形稳定性**：Iris + Sodium 安装使用模组目录事务快照；Sodium 替换后 Iris 下载/校验失败会恢复两者旧版本。光影更新在游戏运行时拒绝；同一项目的 `已安装` 与 `可更新` 汇成一个更新动作，替换前完整下载校验并保留旧 ZIP；Core 的运行时注册表让 CLI/GUI 共享同一保护逻辑。
- **M7.2 NeoForge 与稳定性**：安装向导支持 NeoForge 官方 Maven 版本选择；隔离 staging 中调用官方 `--install-client`，验证生成 profile、runtime libraries 和 patched client JAR 后再事务提交。Modrinth 搜索/安装/更新、`.mrpack` 的 `neoforge` 依赖、图形/光影 loader 过滤均支持 NeoForge。真实 1.21.1 + NeoForge 21.1.265 + JEI 已验证到主菜单。
- **M7.3 崩溃诊断与实例管理**：实例绑定的 latest.log/crash-reports/启动器日志采集，确定性 Java/Loader/模组/LWJGL/OpenGL/Iris/内存/文件诊断，未知原因不编造；支持 Markdown/JSON 脱敏导出、异常退出自动打开诊断。新增实例复制、世界存档备份/校验/分阶段恢复/恢复点、运行中拒绝修改；GUI 的「实例管理」提供实例、世界、启动诊断三个页签。
- **M8 性能工作台**：启动器侧真实采集启动、资源重载、世界加载/区块生成和渲染阶段；记录硬件/Java/Loader/模组上下文，报告持久化与对比，基于实际数据的保守调优建议、确认后应用和恢复。没有游戏内帧计数器时明确标记 FPS 不可用，不用 CPU 占用伪造帧率；仅在 Apple Silicon 原生运行。
- Fabric 与 NeoForge 已通过真实安装/启动验证；Forge/Quilt 未实现。本地离线身份仅保留给 CLI 技术验证，GUI 不提供绕过所有权的启动入口。
- **GitHub Actions CI**：Debug 构建、**316 项**完整 XCTest、Release CLI/GUI、App Bundle 与 ad-hoc 签名校验、ZIP Artifact 上传；不执行真实登录、游戏下载或图形启动。Artifact 仅用于测试，不是公证发行版。

详见 [docs/VERIFICATION-M8.md](docs/VERIFICATION-M8.md)、[docs/VERIFICATION-M7.3.md](docs/VERIFICATION-M7.3.md)、[docs/VERIFICATION-M7.2.md](docs/VERIFICATION-M7.2.md)、[docs/VERIFICATION-M7.1.md](docs/VERIFICATION-M7.1.md)、[docs/VERIFICATION-M6.3.md](docs/VERIFICATION-M6.3.md)、[docs/VERIFICATION-M6.2.md](docs/VERIFICATION-M6.2.md)、[docs/VERIFICATION-M6.1.md](docs/VERIFICATION-M6.1.md)、[docs/VERIFICATION-M3-M5.md](docs/VERIFICATION-M3-M5.md) 与 [docs/VERIFICATION-M2.5.md](docs/VERIFICATION-M2.5.md)。调试 GUI 可使用 [docs/DEBUG-AUTOMATION.md](docs/DEBUG-AUTOMATION.md) 的 opt-in 接口。这是一个**开发中**项目，不是已发布产品。

## 设计边界

- `LauncherCore` 是独立 Swift library，不依赖 SwiftUI/AppKit/CLI 参数解析，不进行用户交互。
- `lingxi` 只是薄外壳：解析 argv → 调用 Core API → 映射退出码。
- `LingXiMac` 直接调用同一个 library，**不会**通过执行 CLI 获取核心功能。
- 零第三方依赖：Foundation / CryptoKit / Compression / Security（系统框架）。

```text
LingXiMac (SwiftUI)              lingxi (CLI)
        │                             │
        └──────────────┬──────────────┘
                       ▼
                 LauncherCore
   VersionResolver · RuleEvaluator · ArgumentResolver
   DependencyResolver · JavaRuntimeInspector · LaunchPlanBuilder
   GameProcessController · InstanceRepository
   MicrosoftOAuthClient · XboxMinecraftAuthenticator
   KeychainRefreshTokenStore · MicrosoftAuthenticationService
   LaunchService · VanillaInstaller · FabricInstaller · NeoForgeInstaller · OneStopInstaller
   JavaManager · InstallationVerifier
   ModrinthClient · ModManager · ModRepository
   Modpack/MrpackParser · Modpack/MrpackInstaller
   Shader/ShaderPackManager · Shader/GraphicsSetupManager
   Shader/ShaderPackRepository · Shader/IrisConfigurationStore
   CrashDiagnostics · InstanceCopyService · WorldBackupManager
   Performance/BenchmarkRunner · Performance/PerformanceTuningEngine
```

## 快速开始

CI 使用 GitHub 官方 `xcode-27` Apple Silicon Runner，执行 Debug 构建、完整单元测试、Release CLI/GUI 构建、`Scripts/build-app.sh` 打包及 Info.plist/App Bundle/ad-hoc 签名校验，并上传临时 Artifact。CI Artifact 仅用于验证，**不是** Developer ID 签名或公证发行版。

要求：macOS 14+、Apple Silicon、Swift 6 工具链（Xcode 26/27 自带）。开发期游戏文件全部放在仓库内 `.dev-sandbox/`（已 gitignore），不写系统目录。

```bash
swift build
swift test

# 1) 生成可双击的 .app（ad-hoc 签名）
Scripts/build-app.sh
open dist/LingXiMac.app
```

开发沙盒中的 GUI（需通过环境变量指定数据目录；直接运行 bundle 内二进制）：

```bash
LINGXI_DATA_ROOT="$PWD/.dev-sandbox/data" \
LINGXI_GAME_ROOT="$PWD/.dev-sandbox/mc" \
  ./dist/LingXiMac.app/Contents/MacOS/LingXiMac
```

Xcode 也可构建 SwiftPM scheme：

```bash
xcodebuild -scheme LingXiMac -destination 'platform=macOS' build
```

### 实例、世界与诊断（CLI）

```bash
# 复制实例；--saves 可选，新实例使用新的 ID
swift run lingxi instance copy m73-fabric --name 'Copied Instance' --saves \
  --root .dev-sandbox/mc --data-root .dev-sandbox/data

# 世界列表 / 备份 / 恢复 / 删除（备份位于 dataRoot/backups，不写入游戏目录）
swift run lingxi world list   --instance m73-fabric --root .dev-sandbox/mc --data-root .dev-sandbox/data
swift run lingxi world backup --instance m73-fabric --world 'New World' \
  --root .dev-sandbox/mc --data-root .dev-sandbox/data
swift run lingxi world restore --instance m73-fabric --backup <backup-id> \
  --root .dev-sandbox/mc --data-root .dev-sandbox/data

# 崩溃诊断与脱敏报告
swift run lingxi diagnose --instance m73-fabric --root .dev-sandbox/mc --data-root .dev-sandbox/data

# 性能基准（GUI 性能工作台调用同一 Core API）
swift run lingxi performance benchmark --instance m73-fabric --runs 1 --timeout 90 \
  --root .dev-sandbox/mc --data-root .dev-sandbox/data
swift run lingxi performance reports --instance m73-fabric --root .dev-sandbox/mc --data-root .dev-sandbox/data
```

所有世界恢复都会先检查运行状态与备份校验，再使用 staging/恢复点；游戏运行时拒绝操作。

### Microsoft 登录（CLI）

Client ID 已内嵌于 `Sources/LauncherCore/Authentication/MicrosoftAppRegistration.swift`，**不需要 `auth.json`、不需要 Client Secret**。登录会打开系统浏览器，在 localhost 随机端口接收回调。

```bash
swift run lingxi account microsoft login \
  --root .dev-sandbox/mc --data-root .dev-sandbox/data

swift run lingxi account microsoft status \
  --root .dev-sandbox/mc --data-root .dev-sandbox/data

swift run lingxi account list \
  --root .dev-sandbox/mc --data-root .dev-sandbox/data
```

正版会话启动：

```bash
swift run lingxi launch --instance dev-1201 \
  --identity microsoft:<uuid|player-name> \
  --java /Library/Java/JavaVirtualMachines/microsoft-17.jdk/Contents/Home/bin/java \
  --root .dev-sandbox/mc --data-root .dev-sandbox/data
```

登录失败、无所有权、Xbox 限制、Keychain 错误都会显式报错，**绝不回退到本地身份**。

## 安装器（M2 + M6.1，无需登录）

```bash
lingxi version list [--type release|snapshot|all] [--source official|auto|mirror|local-cache-only]
lingxi install vanilla --version <id> --instance <id> [--source auto] [--name "..."]
                       [--mirror-config <path>] [--concurrency 4] [--java <path>]
lingxi install fabric --version 1.20.1 --instance fabric-1201 --loader 0.20.1 --java <jdk17/bin/java>
lingxi java list
lingxi java install --major 17 --yes     # optional managed Temurin; requires explicit --yes
lingxi verify --instance <id>

lingxi mod search --instance <id> --query sodium
lingxi mod install --instance <id> --project sodium
lingxi mod list --instance <id>
lingxi mod updates --instance <id>
lingxi mod enable|disable|remove --instance <id> --file <mod.jar>

lingxi mrpack inspect --file <pack.mrpack>
lingxi mrpack install --file <pack.mrpack> --name <display-name> --java <jdk>

lingxi graphics status --instance <id>
lingxi graphics setup --instance <id> [--replace]
lingxi shader search --instance <id> --query complementary
lingxi shader install --instance <id> --project <id|slug> [--version <id>]
lingxi shader import --instance <id> --file <pack.zip>
lingxi shader list --instance <id>
lingxi shader updates --instance <id>
lingxi shader enable --instance <id> --file <pack.zip>
lingxi shader disable --instance <id>
lingxi shader remove --instance <id> --file <pack.zip>
```

流程：官方 manifest（或已验证缓存）→ 版本 JSON（校验 manifest 内 SHA-1）→ client JAR / libraries / asset index / **全部 asset objects** → `.part` 临时文件 → SHA-1 + size 校验 → 原子落盘 → legacy natives 安全解压 → 生成 `instance.json` → 依赖完整性检查。**每一步都不需要 Microsoft 会话。**

Fabric 流程：官方兼容 Loader 查询 → 官方 profile（`inheritsFrom`）→ 先完成 vanilla stage → Fabric Maven 依赖 → 原子写 profile → 成功后才创建/更新实例。目标已存在时 Fabric CLI 默认拒绝，必须显式 `--update`（GUI 向导同样要求确认并备份 manifest）。

NeoForge 流程：官方 Maven metadata（按 Minecraft 版本严格映射）→ 下载并校验 installer → 隔离 staging 中运行官方 `--install-client` → 校验 `neoforge-<version>` profile / 生成库 / patched client JAR → 文件级事务合并到共享根 → 创建/更新实例。安装器进程有 900 秒超时和取消终止；目标实例不会作为 installer 工作目录。

- **源策略**：`official` 仅 Mojang 端点；`mirror` 仅显式配置的可信镜像；`auto` 官方优先、明确失败后切镜像；`local-cache-only` 完全不发网络请求。
- **镜像不是"官方授权"的同义词**：默认不内置任何镜像。使用需提供显式 host 映射 JSON（见 [docs/mirror-config.example.json](docs/mirror-config.example.json)），只允许 HTTPS，不做任意 URL 字符串替换。若评估 BMCLAPI，需自行核实其当前接口前缀、署名/使用规范、稳定性与 Minecraft EULA 要求。
- **校验**：以元数据的 SHA-1 + size 为准；校验失败的文件立即删除，绝不落盘为"已完成"。SHA-1 是与 Mojang 元数据兼容的校验和，不等同于现代数字签名。
- **缓存命中**：已存在的文件按 size（必要时 SHA-1）判断；`install` 修复缺失/大小不符，`verify` 做全量哈希校验。
- **并发与重试**：默认 4 路（可配 1–32）；网络/408/429/5xx 有上限重试，403/404 不重试；磁盘空间不足在下载前即报错。
- **原子落盘**：下载写入同目录 `.part` 文件，SHA-1 + size 校验通过后才用 `rename(2)` 原子替换目标；替换失败时已有完整文件保持不变。
- **JVM 架构感知**：`--java`（或安装时探测到的默认 JVM）决定 rules、natives 选择与 natives 缓存目录（`natives/<version>/<jvm-arch>`），而不是启动器进程架构。x86_64 JVM 在 Apple Silicon 上会被标记为 Rosetta；legacy natives 会读取 Mach-O 头校验真实架构，不匹配即阻断启动。
- **Java 可选托管安装**：`JavaManager` 优先使用 Mojang 官方 `javaVersion.component` 对应的 macOS arm64 `java-runtime`，逐个校验 manifest/文件 SHA-1；仅当官方不可用时回退 Adoptium Temurin。安装/启动后把来源、component、版本、artifact SHA 写入实例 `javaRuntime` 元数据。不修改系统 Java；更新托管 JDK 时新树完整 probe 后才切换，失败恢复旧版本。也可继续用 `--java`/设置页手动选择。
- **Modrinth**：搜索固定 `project_type:mod` + `categories:<fabric|neoforge>` + 当前 Minecraft 版本；必需依赖递归安装，可选依赖只标识；文件从 `cdn.modrinth.com` 下载，优先 SHA-512、回退 SHA-1，并校验 size。更新先下载校验再替换，失败保留旧 JAR。详见 [docs/MODRINTH-API.md](docs/MODRINTH-API.md)。
- **Iris + Sodium**：`GraphicsSetupManager` 先解析当前实例 Fabric/NeoForge 的 Iris 版本及其 Sodium 依赖；若元数据固定 Sodium 版本则使用固定版本，否则选择最新兼容版。已安装不同版本时计划会标记 `requiresReplacement`，只有 `--replace` / GUI 二次确认后才替换；整个 pair 使用有界目录快照，Sodium 替换后 Iris 失败会完整恢复旧文件与记录，不触碰其他模组。
- **光影包**：`ShaderPackManager` 只把 ZIP 写入实例隔离目录的 `shaderpacks/`，元数据写入实例目录 `shaderpacks.json`；项目/版本/哈希来自 Modrinth，更新先完整下载校验再原子替换。替换同时备份旧 ZIP 和 `shaderpacks.json`，任一步失败恢复旧文件/旧记录。启用/停用只改写经版本白名单验证的 Iris `config/iris.properties` 中的 `shaderPack` 与 `enableShaders`，保留注释和未知键，并在写入前备份、写入后校验；游戏运行时由 Core 运行时注册表拒绝改写，GUI 用同一更新动作处理已安装/可更新。`env.client=optional` 的文件默认不安装，GUI 必须逐个勾选。

## Microsoft 认证（M3）

- **Public client**：Authorization Code + PKCE S256；系统浏览器；`http://localhost` loopback；随机 `state`；无密码输入、无 Client Secret。
- **链路**：Microsoft token → Xbox Live user auth → XSTS（Minecraft relying party）→ Minecraft Services `login_with_xbox` → `entitlements/mcstore` + profile → 所有权判定。
- **令牌类型严格区分**：MSA access token、Xbox token、XSTS token、Minecraft access token 均在内存/会话中；**只有 refresh token 写入 macOS Keychain**（service `com.lingxifox.LingXiLauncher.microsoft`）。
- **恢复/刷新**：新进程从 Keychain 读取 refresh token 并刷新；访问令牌过期会刷新，refresh token 失效返回 `TOKEN_EXPIRED`。
- **错误**：无所有权 `GAME_OWNERSHIP_MISSING`；Xbox 限制 `XBOX_ACCOUNT_RESTRICTED`；应用注册 403 `APP_REGISTRATION_REJECTED`；Keychain 错误 `KEYCHAIN_FAILURE`。
- **XUID**：优先 XSTS `DisplayClaims`/Xbox Live；否则用独立 XSTS audience + Xbox profile service 获取。若仍不可用，允许占位 `0` 继续本地启动（在线功能可能受限），但不伪造所有权。
- **客户端配置**：`MicrosoftAppRegistration` 单一内嵌来源；开发者可用 `LINGXI_MICROSOFT_CLIENT_ID` 临时覆盖。无外部 auth 配置文件。
- **外观**：登录/验证时从 Minecraft Profile 读取 `skins` / `capes`，只保存公开纹理 URL 与 Classic/Slim；GUI 用真实纹理绘制头像、皮肤与披风，缺省时显示真实空缺，不伪造玩家资源。
- **内存**：实例内存默认为自动策略（按物理内存解析为具体 `-Xmx`，上限 8 GiB），也可手动固定；GUI、CLI 与 `LaunchService` 共用同一策略。

## 唯一 `.minecraft` 与强制隔离

实例元数据仍在 `<dataRoot>/instances/<id>/instance.json`，但游戏目录不再嵌套在实例目录中。所有实例共用一个 `<dataRoot>/.minecraft`，实际工作目录是 `<dataRoot>/.minecraft/versions/<instance-id>`，因此版本/实例之间不会共享存档、选项、模组或日志。首次加载旧实例时，旧的 `instances/<id>/.minecraft` 会被**移动**到新隔离目录；若新旧目录同时存在则报错而不会自动合并。

## 身份模式与发布边界

| 模式 | 状态 | 行为 |
|---|---|---|
| `local-offline` | M1，CLI 技术验证 | 确定性离线 UUID，token/xuid 占位 `0`；**不是购买验证**。GUI 不提供启动入口。 |
| `microsoft` | **M3 已实现/真机验证** | 真实 Microsoft/Xbox/Minecraft 会话、所有权检查、Keychain 刷新。 |
| `licensed-offline` | 未实现 | 构建计划时显式抛错，不静默降级。 |

Minecraft AppID 已于 **2026-10-26** 通过 Mojang 官方审核并加入 API Allow List（项目所有者确认）。GUI 公开构建只允许 Microsoft 正版身份启动；本地离线身份仅用于 CLI 技术验证，与 Microsoft 身份严格隔离。

**严禁静默回退**：Microsoft 登录失败必须报错，绝不自动切换成本地身份；反之亦然。`LaunchPlan` 的 `description`/日志只使用脱敏 argv。

## SwiftUI GUI（M5-Alpha）

原生 SwiftUI，macOS 14+，无 Electron/WebView：

- **首页**：当前实例、账户、Java、启动/停止、最近退出码。
- **游戏实例**：列表、创建、删除（需确认）、打开隔离游戏目录、自动/手动 JVM 内存设置、启动。
- **版本下载 / 安装向导**：官方/可信镜像清单、Release/Snapshot 过滤；向导依次选择 Minecraft → Vanilla/Fabric/NeoForge → Java → 新/现有实例 → 确认 → 下载校验；NeoForge 版本来自官方 Maven 并严格匹配 Minecraft；进度/取消/重试，默认新实例，更新现有实例需显式确认并备份 manifest。
- **模组管理**：实例详情打开「模组管理」双视图；已安装页管理本地模组、检测更新；浏览页搜索 Modrinth、查看项目/版本/依赖并安装。支持 Fabric 与 NeoForge；GUI 通过 Core 的 `ModManager` 访问网络。
- **整合包导入**：实例页「导入整合包」支持 `.mrpack` 文件选择与 Finder 拖放；展示解析结果、Java 与可选客户端文件后，通过 Core 的 `MrpackInstaller` 创建全新实例。支持 Vanilla/Fabric/NeoForge；Forge/Quilt/CurseForge 明确不支持。
- **图形与光影**：Fabric/NeoForge 实例详情打开「图形与光影」；提供 Iris + Sodium 检测/安装计划、已安装光影、Modrinth 搜索/版本/更新、本地 ZIP 导入、启用/停用和删除。启动器明确显示 macOS OpenGL 4.1 上限与“安装不等于已启用”；实际渲染需进入世界验证。
- **账户管理**：Microsoft 登录进度、UUID、所有权、真实皮肤/披风纹理与头像裁剪、切换、验证、退出；本地身份只读并明确标注未验证。
- **运行日志**：LauncherCore 事件、Java stdout/stderr、游戏输出、退出码；搜索、复制、自动滚动、脱敏诊断导出、打开 Minecraft `latest.log`。启动器日志带实例 ID，诊断不会读取其他实例的日志。
- **设置**：Java 检测/选择、下载源/镜像配置、数据/游戏目录、内嵌认证状态。
- **安全**：GUI 不执行 CLI；OAuth code、access/refresh token、PKCE verifier 不写入日志；诊断导出脱敏。

GUI 使用 `LaunchService` 启动：`resolve → dependencies → preflight → GameProcessController`，与 CLI 共享 Core 组件，不复制业务逻辑。

## 数据布局

```text
<root>/                                  # 游戏根（--root；开发期 .dev-sandbox/mc）
├── versions/<id>/<id>.json + <id>.jar
├── libraries/<maven path>
├── assets/indexes/<asset-id>.json
├── assets/objects/<hash[0..2]>/<hash>
└── assets/log_configs/<id>

<data-root>/                             # 启动器数据（--data-root；开发期 .dev-sandbox/data）
├── backups/<instance-id>/<backup-id>/      # 世界备份与 Manifest（独立于游戏目录）
├── performance/reports/<uuid>.json          # M8 性能报告
├── instances/
│   ├── <instance-id>/instance.json        # 实例元数据（不含嵌套 .minecraft）
│   ├── <instance-id>/mods.json            # 模组记录/来源/版本/许可证
│   ├── <instance-id>/mods-disabled/       # 禁用的模组 JAR
│   └── <instance-id>/shaderpacks.json     # 光影包记录/来源/版本/SHA-1/SHA-512
├── java/                                  # 用户确认后下载的托管 JDK（可选）
├── .minecraft/                            # 唯一的游戏数据根
│   └── versions/<instance-id>/            # 隔离游戏目录（mods/shaderpacks/存档/config/日志）
├── cache/
│   ├── manifests/version_manifest_v2.json
│   └── mrpack/<archive-sha256>/           # 整合包外部文件已验证缓存
├── accounts/local/<name>.json            # 本地离线账户（无令牌字段，显式 unverified）
├── accounts/microsoft/<uuid>.json        # 仅元数据：UUID/name/xuid/ownership/时间/公开皮肤披风 URL
├── accounts/active.json
├── natives/<version-id>/<arch>/          # legacy natives 解压缓存
├── logs/launcher/launch-*.log            # CLI，脱敏 argv
└── logs/launcher/gui-launch-*.log        # GUI，脱敏 argv
```

macOS Keychain（不落盘到上述目录）：

```text
service: com.lingxifox.LingXiLauncher.microsoft
account: <Microsoft account UUID>
value:   refresh token only
```

## 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 3 | 没有可用 Java（版本/架构/可执行性） |
| 4 | preflight / verify 失败（缺失文件、架构不兼容、校验不通过） |
| 64 | 用法错误 |
| 65 | 元数据无效 / 校验和不匹配 / 认证数据无效 |
| 66 | 缺少输入（版本 JSON、实例、账户） |
| 69 | 未实现 / 不可用（网络、HTTP 失败、认证/所有权/配置错误） |
| 70 | 内部错误 |
| 74 | I/O 错误（含磁盘空间、权限、Keychain） |

游戏正常跑完时，启动器透传游戏自身的退出码。

## M8.1 数据完整性与资源包

- 实例复制保留 `mods.json`、`shaderpacks.json` 和 `modpack.json`，并保留禁用模组与来源信息。
- 世界备份包含隐藏文件、跨进程锁、源/目标 SHA-256 一致性和失败回滚。
- `ResourcePackManager` 支持 Modrinth 资源包搜索/安装/更新/删除、本地 ZIP 导入和受控的 `options.txt` 启用。
- 整合包来源写入 `modpack.json`；不会根据名称猜测 Modrinth 项目。
- 当前限制：整合包更新事务和真实资源包进游戏验证尚未完成，详见 [M8.1 验证记录](docs/VERIFICATION-M8.1.md)。

### M8.2 数据安全修复

- 实例复制保留 `resourcepacks.json`，与 `mods.json`、`shaderpacks.json`、`modpack.json` 一并复制。
- 资源包删除改为可回滚事务，并同步清理受支持版本的 `options.txt` 启用项。
- 整合包记录区分 `.mrpack` 内部版本 ID 与 Modrinth API 项目/版本 ID；旧记录不会被猜测为 Modrinth 版本。
- 当前限制：整合包更新事务和真实 `.mrpack` 内容差异仍未实现，详见 [M8.2 验证记录](docs/VERIFICATION-M8.2.md)。

## 当前限制（诚实清单）

- M3 真实登录已验证；但本次使用浏览器已有 Microsoft 会话（SSO），未在全新浏览器 profile 下重走密码 + 首次 consent。
- CLI/GUI 正版启动均验证到 **1.20.1 主菜单**并正常退出 0。M7.1 额外使用独立的本地技术身份和测试实例创建/加载了一个新世界，验证 Iris pipeline；未验证多人、Realms 或长时间玩法。1.20.1 的 Realms “Client incompatible” 是旧版本游戏侧提示，不是认证失败。
- GUI 下载本次是 1.20.1 缓存命中 + 3636 文件全量验证；大文件全新下载已由 M2 CLI 验证，但 GUI 中途取消未做真机大文件实测。
- 未测试 Intel Mac；`.app` 为 ad-hoc 签名，未做 Developer ID 签名/公证。
- XUID 依赖额外的 Xbox profile 请求；失败时占位 `0` 会限制在线功能。
- M7.1 只在 Minecraft 1.20.1 + Fabric Loader 0.20.1 + Iris 1.7.6 / Sodium 0.5.12-beta.2 上做了真实世界验证；M7.2 的 NeoForge 验证使用 1.21.1 + NeoForge 21.1.265 + JEI，未在 NeoForge 上重复 Iris/Sodium 世界验证。其他版本即使 Modrinth 声明兼容，也可能因 loader 或显卡驱动差异失败。
- macOS 只提供 OpenGL 4.1（Metal 转译）；没有 Metal 原生渲染、硬件光追或“RTX”能力。复杂光影在 Apple Silicon 上可能掉帧；启动器只提示，不承诺帧率。
- 光影“启用”只代表已写入 Iris 配置，是否真正渲染以游戏内为准；测试用的 Complementary r5.9.3 在 Iris 1.7.6 下记录了未识别 custom uniform 警告，未崩溃，但不能据此宣称所有光影包无警告。
- M7.1 的 GUI 真实启动验证使用 CLI/本地测试身份；没有在 M7.1 阶段重新执行 Microsoft 登录流程。
- M7.3 世界备份默认为手动；没有自动定时备份策略。恢复操作已在真实 `m73-fabric` 世界验证，但仍建议用户保留独立副本。
- M8 只记录 CPU/内存和启动阶段；外部启动器无法稳定读取 Minecraft 内部帧时间，因此 FPS/1% low 显示为不可用。单轮/无预热基准不应视为稳定性能结论。
- Forge/Quilt 和 CurseForge 整合包未实现；NeoForge 仅验证了现代官方 Maven 版本。
- legacy `virtual` / `map_to_resources` 资产索引（1.6 及更早）只下载对象、不生成 resources 树。
- 同尺寸但内容损坏的文件不会被 `install` 自动发现，请用 `lingxi verify` 做哈希级校验。

更多实现细节见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。

## License

[MIT](LICENSE) © 2026 LingXiFox

Minecraft is a trademark of Mojang Studios. This project is not affiliated with, endorsed by, or sponsored by Mojang Studios or Microsoft. It does not distribute Minecraft game files, assets or modified JARs; the installer downloads them from Mojang's own servers into the user's local data directory.
