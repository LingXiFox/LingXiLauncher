# LingXi Launcher

macOS Apple Silicon 原生 **Minecraft: Java Edition** 启动器。当前进度：**M0 + M1 + M2 + M2.5 + M3 + M5-Alpha + M6.1 + M6.1.1 + M6.2 + M6.2.1 + M6.3**。

- **M3 Microsoft 正版认证已实现并通过真机验证**：OAuth 2.0 Authorization Code + PKCE S256、系统浏览器、localhost 回调、Xbox Live → XSTS → Minecraft Services → 所有权/档案、Keychain 存储与刷新。
- **M5-Alpha SwiftUI GUI 可用**：首页 / 游戏实例 / 版本下载 / 账户管理 / 运行日志 / 设置，直接调用 LauncherCore，不执行 CLI。
- 已使用真实 Microsoft 正版账号完成所有权、Keychain 刷新与 CLI/GUI 启动验证（1.20.1 主菜单，正常退出 0）。
- **M6.1 一站式安装**：VersionResolver 支持 `inheritsFrom` 合并；Fabric Loader（官方 meta/Maven）安装；JavaManager 按元数据检测/下载托管 Temurin；GUI 安装向导默认创建新实例，更新现有实例需显式确认并备份。
- **M6.2 Modrinth 模组管理**：Fabric 实例的 Modrinth 搜索、兼容性过滤、依赖自动解析、JAR 哈希校验、本地启用/禁用/删除、更新检测与原子更新；GUI 实例详情提供双视图。
- **M6.1.1 稳定性**：托管 JDK 完整校验后安全替换（失败恢复旧版本）；向导切换版本/Loader 后即时重验 Java；补充 Fabric 1.16.5/1.20.1/1.21.11/26.3 真实元数据矩阵。
- **M6.2.1 模组稳定性**：依赖冲突只在启用的实际版本上判定；更新保留禁用状态；更新检测按渠道和自然版本号而非仅日期；DebugAutomation 仅 Debug + 会话 token。
- **M6.3 整合包**：按 Modrinth format 1 解析 `.mrpack`，安全 ZIP/overrides、外部文件哈希下载、OneStop 安装、独立新实例、失败/取消清理和缓存重试；GUI/Finder 拖放导入。
- Fabric（Forge/NeoForge/Quilt 未实现）已通过真实 1.20.1 + Loader 0.20.1 安装与启动验证；本地离线身份仅保留给 CLI 技术验证，GUI 不提供绕过所有权的启动入口。

详见 [docs/VERIFICATION-M6.3.md](docs/VERIFICATION-M6.3.md)、[docs/VERIFICATION-M6.2.md](docs/VERIFICATION-M6.2.md)、[docs/VERIFICATION-M6.1.md](docs/VERIFICATION-M6.1.md)、[docs/VERIFICATION-M3-M5.md](docs/VERIFICATION-M3-M5.md) 与 [docs/VERIFICATION-M2.5.md](docs/VERIFICATION-M2.5.md)。调试 GUI 可使用 [docs/DEBUG-AUTOMATION.md](docs/DEBUG-AUTOMATION.md) 的 opt-in 接口。这是一个**开发中**项目，不是已发布产品。

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
   LaunchService · VanillaInstaller · FabricInstaller · OneStopInstaller
   JavaManager · InstallationVerifier
   ModrinthClient · ModManager · ModRepository
   Modpack/MrpackParser · Modpack/MrpackInstaller
```

## 快速开始

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
```

流程：官方 manifest（或已验证缓存）→ 版本 JSON（校验 manifest 内 SHA-1）→ client JAR / libraries / asset index / **全部 asset objects** → `.part` 临时文件 → SHA-1 + size 校验 → 原子落盘 → legacy natives 安全解压 → 生成 `instance.json` → 依赖完整性检查。**每一步都不需要 Microsoft 会话。**

Fabric 流程：官方兼容 Loader 查询 → 官方 profile（`inheritsFrom`）→ 先完成 vanilla stage → Fabric Maven 依赖 → 原子写 profile → 成功后才创建/更新实例。目标已存在时 Fabric CLI 默认拒绝，必须显式 `--update`（GUI 向导同样要求确认并备份 manifest）。

- **源策略**：`official` 仅 Mojang 端点；`mirror` 仅显式配置的可信镜像；`auto` 官方优先、明确失败后切镜像；`local-cache-only` 完全不发网络请求。
- **镜像不是"官方授权"的同义词**：默认不内置任何镜像。使用需提供显式 host 映射 JSON（见 [docs/mirror-config.example.json](docs/mirror-config.example.json)），只允许 HTTPS，不做任意 URL 字符串替换。若评估 BMCLAPI，需自行核实其当前接口前缀、署名/使用规范、稳定性与 Minecraft EULA 要求。
- **校验**：以元数据的 SHA-1 + size 为准；校验失败的文件立即删除，绝不落盘为"已完成"。SHA-1 是与 Mojang 元数据兼容的校验和，不等同于现代数字签名。
- **缓存命中**：已存在的文件按 size（必要时 SHA-1）判断；`install` 修复缺失/大小不符，`verify` 做全量哈希校验。
- **并发与重试**：默认 4 路（可配 1–32）；网络/408/429/5xx 有上限重试，403/404 不重试；磁盘空间不足在下载前即报错。
- **原子落盘**：下载写入同目录 `.part` 文件，SHA-1 + size 校验通过后才用 `rename(2)` 原子替换目标；替换失败时已有完整文件保持不变。
- **JVM 架构感知**：`--java`（或安装时探测到的默认 JVM）决定 rules、natives 选择与 natives 缓存目录（`natives/<version>/<jvm-arch>`），而不是启动器进程架构。x86_64 JVM 在 Apple Silicon 上会被标记为 Rosetta；legacy natives 会读取 Mach-O 头校验真实架构，不匹配即阻断启动。
- **Java 可选托管安装**：`JavaManager` 优先使用 Mojang 官方 `javaVersion.component` 对应的 macOS arm64 `java-runtime`，逐个校验 manifest/文件 SHA-1；仅当官方不可用时回退 Adoptium Temurin。安装/启动后把来源、component、版本、artifact SHA 写入实例 `javaRuntime` 元数据。不修改系统 Java；更新托管 JDK 时新树完整 probe 后才切换，失败恢复旧版本。也可继续用 `--java`/设置页手动选择。
- **Modrinth**：搜索固定 `project_type:mod` + `categories:fabric` + 当前 Minecraft 版本；必需依赖递归安装，可选依赖只标识；文件从 `cdn.modrinth.com` 下载，优先 SHA-512、回退 SHA-1，并校验 size。更新先下载校验再替换，失败保留旧 JAR。详见 [docs/MODRINTH-API.md](docs/MODRINTH-API.md)。

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
- **版本下载 / 安装向导**：官方/可信镜像清单、Release/Snapshot 过滤；M6.1 向导依次选择 Minecraft → Vanilla/Fabric → Java → 新/现有实例 → 确认 → 下载校验；进度/取消/重试，默认新实例，更新现有实例需显式确认并备份 manifest。
- **模组管理**：实例详情打开「模组管理」双视图；已安装页管理本地模组、检测更新；浏览页搜索 Modrinth、查看项目/版本/依赖并安装。M6.2 仅 Fabric；GUI 通过 Core 的 `ModManager` 访问网络。
- **整合包导入**：实例页「导入整合包」支持 `.mrpack` 文件选择与 Finder 拖放；展示解析结果、Java 与文件清单后，通过 Core 的 `MrpackInstaller` 创建全新实例。M6.3 仅 Vanilla/Fabric；Forge/NeoForge/Quilt/CurseForge 明确不支持。
- **账户管理**：Microsoft 登录进度、UUID、所有权、真实皮肤/披风纹理与头像裁剪、切换、验证、退出；本地身份只读并明确标注未验证。
- **运行日志**：LauncherCore 事件、Java stdout/stderr、游戏输出、退出码；搜索、复制、自动滚动、脱敏诊断导出、打开 Minecraft `latest.log`。
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
├── instances/
│   ├── <instance-id>/instance.json        # 实例元数据（不含嵌套 .minecraft）
│   ├── <instance-id>/mods.json            # 模组记录/来源/版本/许可证
│   └── <instance-id>/mods-disabled/       # 禁用的模组 JAR
├── java/                                  # 用户确认后下载的托管 JDK（可选）
├── .minecraft/                            # 唯一的游戏数据根
│   └── versions/<instance-id>/            # 隔离游戏目录（mods/存档/配置/日志）
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

## 当前限制（诚实清单）

- M3 真实登录已验证；但本次使用浏览器已有 Microsoft 会话（SSO），未在全新浏览器 profile 下重走密码 + 首次 consent。
- CLI/GUI 正版启动均验证到 **1.20.1 主菜单**并正常退出 0；未创建新世界、未验证世界内玩法、多人或 Realms。1.20.1 的 Realms “Client incompatible” 是旧版本游戏侧提示，不是认证失败。
- GUI 下载本次是 1.20.1 缓存命中 + 3636 文件全量验证；大文件全新下载已由 M2 CLI 验证，但 GUI 中途取消未做真机大文件实测。
- 未测试 Intel Mac；`.app` 为 ad-hoc 签名，未做 Developer ID 签名/公证。
- XUID 依赖额外的 Xbox profile 请求；失败时占位 `0` 会限制在线功能。
- Fabric（M4）未实现。
- legacy `virtual` / `map_to_resources` 资产索引（1.6 及更早）只下载对象、不生成 resources 树。
- 同尺寸但内容损坏的文件不会被 `install` 自动发现，请用 `lingxi verify` 做哈希级校验。

更多实现细节见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。

## License

[MIT](LICENSE) © 2026 LingXiFox

Minecraft is a trademark of Mojang Studios. This project is not affiliated with, endorsed by, or sponsored by Mojang Studios or Microsoft. It does not distribute Minecraft game files, assets or modified JARs; the installer downloads them from Mojang's own servers into the user's local data directory.
