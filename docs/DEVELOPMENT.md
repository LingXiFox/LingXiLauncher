# 开发说明（M1 + M2 + M2.5 + M3 + M5-Alpha）

本文记录实现约定、契约边界和验收方式。产品边界与安全披露见根目录 [README](../README.md)。

## 1. 仓库结构

```text
Package.swift                     # library + executable + test targets，零第三方依赖
Sources/LauncherCore/
├── Models/                       # 契约层：数据模型、错误、平台上下文、布局、协议
│   ├── Contracts.swift           # 所有跨组件协议（VersionResolving / RuleEvaluating / …）
│   ├── VersionMetadata.swift     # Mojang 版本 JSON 模型 + 严格规则解码
│   ├── AccountIdentity.swift     # 三种身份（Microsoft / LicensedOffline / LocalOffline）
│   ├── LaunchPlan.swift          # LaunchContext / LaunchPlan / LaunchPreview（脱敏）
│   ├── DependencyTypes.swift     # ResolvedFile / ResolvedNative / MissingDependency
│   ├── InstallModels.swift       # 下载任务/进度/报告/校验结果
│   ├── GameDataLayout.swift      # dataRoot / gameRoot 路径推导（全部做路径穿越防护）
│   └── PathSafety.swift          # zip entry / 相对路径的安全校验
├── Version/
│   ├── VersionResolver.swift     # 读取并规范化版本 JSON（拒绝旧格式与继承）
│   ├── RuleEvaluator.swift       # Mojang rules（T03）
│   └── ArgumentResolver.swift    # arguments 展开与占位符替换（T06）
├── Runtime/
│   ├── JavaRuntimeInspector.swift         # 真实执行 java 探测版本/架构/Rosetta（T05）
│   └── NativeArchiveInspector.swift       # Mach-O 架构检查 + JVM/原生库兼容诊断（M2.5）
├── Launch/
│   ├── DependencyResolver.swift  # 规则过滤 → classpath/natives/assets（T04）
│   ├── LaunchPlanBuilder.swift   # 纯转换：preview / build / validate（T06）
│   ├── GameProcessController.swift        # Process + 异步流 + 退出码（T07）
│   ├── LaunchService.swift                # GUI/CLI 共享的启动编排
│   └── LocalOfflineIdentity.swift         # 离线 UUID v3（T09）
├── Authentication/                # M3
│   ├── MicrosoftAppRegistration.swift     # 唯一内嵌 Entra public-client 配置
│   ├── AuthenticationModels.swift         # 配置/阶段/状态/账户模型
│   ├── PKCE.swift                         # S256 verifier/challenge
│   ├── MicrosoftOAuthClient.swift         # authorize/token/refresh
│   ├── LoopbackOAuthAuthorizer.swift      # localhost server + state 校验
│   ├── XboxMinecraftAuthenticator.swift   # Xbox/XSTS/Minecraft/所有权/XUID
│   ├── KeychainRefreshTokenStore.swift    # 仅 refresh token
│   ├── MicrosoftAccountStore.swift        # 元数据 + active account
│   └── MicrosoftAuthenticationService.swift # actor 状态机/刷新/登出
├── Instance/
│   ├── InstanceRepository.swift  # 实例创建/加载/列出/切换版本/内存/删除
│   └── LocalAccountStore.swift   # 本地离线账户（无令牌字段）
├── Installer/                    # M2
│   ├── DownloadSource.swift      # official/mirror/auto/local-cache-only + 显式镜像映射
│   ├── DownloadTransport.swift   # URLSession 实现 + 可注入传输层
│   ├── Downloader.swift          # 有界并发、重试、SHA-1 校验、.part 原子落盘
│   ├── ManifestService.swift     # manifest / 版本 JSON / asset index 缓存与校验
│   ├── SafeZipExtractor.swift    # 最小 ZIP 读取 + Zip Slip/symlink 防护
│   ├── VanillaInstaller.swift    # 安装编排（按选定 JVM 架构）
│   └── InstallationVerifier.swift# 全量哈希校验
├── Apps/LingXiMac/               # M5 SwiftUI GUI（直接依赖 LauncherCore）
│   ├── Info.plist
│   └── Sources/                  # AppModel + Views
├── Scripts/build-app.sh          # SwiftPM → dist/LingXiMac.app（ad-hoc）
└── Sources/LingXiCLI/            # 薄外壳：argv 解析、Core 调用、退出码映射
Tests/LauncherCoreTests/
├── Fixtures/                     # 真实 Mojang 元数据 + 故意的坏数据
└── *Tests.swift                  # 见 §6
```

## 2. 契约优先

所有跨组件接口集中在 `Sources/LauncherCore/Models/Contracts.swift`。实现组件只依赖协议，不依赖彼此的具体类型：

- `VersionResolving`：`resolve(versionID:from:)`，只读磁盘，不联网。
- `RuleEvaluating`：`isAllowed(_:platform:)`。**无 rules ⇒ 允许；有 rules 时初始为拒绝，按声明顺序让每个匹配项覆盖结果（最后匹配者胜）。**
- `ArgumentResolving`：`expand(_:platform:variables:sensitiveKeys:)`。`value` 数组展开为多个 argv 元素，绝不 join。未知占位符报错，不静默变空串。
- `DependencyResolving`：`resolve(version:layout:platform:)`。只映射路径与收集缺失项，不下载、不建目录。
- `LaunchPlanning`：`preview` / `build` / `validate`。**纯转换，不联网。**
- `JavaRuntimeInspecting` / `GameProcessControlling`：真实子进程行为。

`LaunchPlan` 与 `LaunchPreview` 是两种类型：Preview 永远不含令牌；Plan 在 Microsoft 模式下 `arguments` 含真实令牌，因此 `description`/`debugDescription` 只输出脱敏摘要，日志只写 `redactedArguments`。

## 3. 元数据解码容错策略

- **未知顶层字段忽略**：Mojang 会持续加字段（例如 1.21.9+ 的 `default-user-jvm`、26.x 的 `os.versionRange`），它们不影响已解析版本的启动方式。
- **影响行为的字段严格解码**：`rules.action`、`rules.os.*`、`features`、`arguments` 结构、`natives`、`downloads`。遇到无法识别的 rule/os 字段直接抛 `UNSUPPORTED_VERSION`，宁可不启动也不猜。
- **缺失可选字段可预测降级**：无 `javaVersion` ⇒ 无 Java 主版本要求；无 `assetIndex` ⇒ 用旧式 `assets` id；无 `downloads.client` ⇒ 依赖解析报告缺失。
- 所有解码失败统一包装成 `LauncherError(.invalidMetadata)`，附带 JSON path 与字段名。

真实元数据三种形态（测试 fixture 覆盖）：

| 版本 | 特征 |
|---|---|
| `26.3` | 最新格式：natives 作为普通 library（`natives-macos` / `natives-macos-arm64` 同时受 `osx` 规则允许）、`default-user-jvm`、`os.versionRange`、`--clientId`/`--xuid` 游戏参数 |
| `1.20.1` | 现代 `arguments` + natives 作为普通 library |
| `1.16.5` | 旧格式：`natives.osx` + `downloads.classifiers` + `extract.exclude` |

## 4. macOS / Apple Silicon 规则

- `os.name` 使用 `osx`；`os.arch` 同时接受 `arm64`/`aarch64`（以及 `x86_64`/`amd64`）。
- `os.version` 为正则匹配；`os.versionRange` 为逐段数值比较（min/max 闭区间）。
- JVM 架构来自**实际运行** `<java> -XshowSettings:properties -version` 的 `os.arch`，而不是“主机是 arm64”的假设。
- 旧版 natives 的架构判定是显式的：classifier 带 `-x86_64`/`-x64` 在 arm64 平台产生 **error 级诊断**；只写 `natives-macos`/`natives-osx` 的旧版归档无法静态判定架构，产生 **一次性 warning**（提示可能需要 Rosetta）。两者都不做混合架构自动修复，也不静默硬加载。
- natives 缓存按 `<version>/<arch>` 隔离，x86_64 缓存不可能被 arm64 JVM 复用。
- 路径（含中文、空格）始终以 argv 数组传递，classpath 用 `:` 拼成单个 `-cp` 参数值，不做 shell quote。
- 唯一游戏数据根为 `<dataRoot>/.minecraft`；工作目录固定为 `<dataRoot>/.minecraft/versions/<instance-id>`（强制版本/实例隔离），实例元数据目录内不再创建 `.minecraft`。

## 4.1 JVM 架构与原生库（M2.5）

- **唯一事实来源是实际选定的 JVM**：`JavaRuntimeInspector` 执行 `<java> -XshowSettings:properties -version` 得到 `os.arch`；`PlatformContext.forJVM(runtime)` 用 JVM 架构 + 主机 OS/版本构造规则上下文。
- `DependencyResolver`、`RuleEvaluator`、`LaunchPlanBuilder`、`InstallationVerifier` 全部显式接收该上下文；`LaunchContext.platform` 是必填字段，builder 不再读取启动器进程架构。
- natives 缓存目录为 `natives/<version-id>/<jvm-arch>`，arm64 与 x86_64 缓存物理隔离。
- Rosetta：`hw.optional.arm64=1` 且 JVM `os.arch=x86_64` 时标记 `isRosettaTranslated`；doctor / install / launch 均给出 warning，并选择 x86_64 natives。
- legacy natives 除了 classifier 提示外，还会解压读取 Mach-O 头（thin/fat）确认真实架构；与 JVM 不匹配是 blocking error。classifier 带 `-x86_64`/`-arm64` 时双向校验（arm64 JVM × x86_64 natives 与 x86_64 JVM × arm64 natives 都报错）。
- 不根据操作系统指定图形 API：Minecraft 自己选择 OpenGL/Metal 后端，启动器只负责 JVM/natives/参数。

## 5. 启动计划构建顺序

1. `VersionResolver`：读 JSON → 拒绝 `minecraftArguments` / `inheritsFrom` → `ResolvedVersion`。
2. `DependencyResolver`：规则过滤 → classpath（library 顺序 + client JAR 末尾，按标准化路径去重）→ legacy natives 列表 → 缺失项。
3. `JavaRuntimeInspector`：版本、架构、vendor。
4. `LaunchPlanBuilder.build`：占位符替换 → 注入额外 JVM 参数（在 `-cp` 之前）→ `mainClass` → 游戏参数；同时生成 `redactedArguments`。
5. `LaunchPlanBuilder.validate`：聚合 Java 版本/架构、缺失文件、classpath 结构、工作目录等诊断；有 error 则不启动。
6. `GameProcessController.start`：直接 `Process` 启动（**不用 `sh -c`，不用 `java -jar`**），异步读取 stdout/stderr，退出码与游戏崩溃分开表示。

占位符集合以版本实际引用为准：`${natives_directory}`、`${classpath}`、`${classpath_separator}`、`${library_directory}`、`${launcher_name}`、`${launcher_version}`、`${auth_player_name}`、`${auth_uuid}`、`${auth_access_token}`、`${auth_xuid}`、`${clientid}`、`${user_type}`、`${user_properties}`、`${version_name}`、`${version_type}`、`${game_directory}`、`${assets_root}`、`${assets_index_name}`、`${path}`（日志配置）。出现未提供的占位符即报错。

### LocalOffline 的参数约定

| 占位符 | 值 |
|---|---|
| `auth_player_name` | 玩家名（校验 `^[A-Za-z0-9_]{3,16}$`） |
| `auth_uuid` | `MD5("OfflinePlayer:"+name)` 的 RFC 4122 v3 UUID，去掉连字符 |
| `auth_access_token` | `0`（显式占位，不是"看起来像真"的令牌） |
| `auth_xuid` / `clientid` | `0` |
| `user_type` | `legacy` |
| `user_properties` | `{}` |

固定测试向量（Python `hashlib` 独立算得，与 Java `UUID.nameUUIDFromBytes` 一致）：`Notch → b50ad385-829d-3141-a216-7e7d7539ba7f`、`TestPlayer → bb77495a-a740-3169-a238-69654c8bd2c1`。

## 6. 下载安装器（M2）

入口：`lingxi version list` / `lingxi install vanilla` / `lingxi verify`。

```text
manifest（缓存）→ 版本 JSON（校验 manifest SHA-1）→ 依赖解析
→ asset index（校验 SHA-1/size）→ 缺失文件 + 全部 asset objects
→ Downloader（4 路默认并发，.part 临时文件）
→ SHA-1 + size 校验 → 同目录原子 rename → legacy natives 安全解压
→ instance.json → 依赖完整性复查
```

关键不变量：

- **下载与账户完全解耦**：整条链路不读取、不要求任何 Microsoft/令牌；`DownloadSourcePolicy.localCacheOnly` 时传输层一次都不会被调用。
- **校验链**：manifest → 版本 JSON 的 SHA-1；版本 JSON → asset index 的 SHA-1；所有文件 → 元数据 SHA-1 + size。校验失败立刻删除 `.part`，绝不生成"看起来完成"的目标文件。
- **源策略**：`official`/`mirror`/`auto`/`local-cache-only`。镜像仅接受显式 host 映射（`MirrorHostRule`），只允许 HTTPS，官方 path/query 原样保留，映射结果仍必须是 HTTPS；不做任意 URL 字符串替换或通配。
- **重试**：网络、408、429、5xx 按源重试（默认 3 次，线性退避，上限 5s）；403/404 与校验失败不重试，`auto` 会改用镜像。
- **并发**：默认 4，CLI 可配 1–32。stdout 进度按 0.5s 节流，避免 3000+ 资产刷屏。
- **磁盘预检**：按待下载 size 之和 + 32MB 余量与目标卷可用空间比较，不足直接 `DISK_FULL`。
- **缓存命中**：`Downloader` 对队列中的每个文件做 size（有 SHA-1 时也做哈希）检查；`DependencyResolver` 负责找出缺失/大小不符的文件。全量哈希由 `verify` 完成，避免每次 install 都扫描 700MB。
- **安全解压**：`SafeZipExtractor` 自己解析 ZIP（stored/deflate，Compression 框架），拒绝 `../`、绝对路径、反斜杠、控制字符、符号链接条目、超限条目/总量；ZIP64 明确报不支持。归档本身在解压前已通过 SHA-1 校验。
- **Java**：不自动安装。`install` 仅在显式传 `--java` 时做兼容性检查；`doctor` 负责发现与诊断。
- **实例**：`--instance <id>` 是稳定 id（路径安全校验）；不存在则创建，存在则更新 `versionID`。显示名不参与路径拼接。

## 7. 测试

```bash
swift build
swift test
```

当前总计 **233 个测试**，全量运行 0 失败：

| 测试文件（用例数） | 覆盖 |
|---|---|
| `ManifestTests` (4) | manifest / 版本 JSON 解码、坏 JSON、缺字段、未知 rule 字段 |
| `VersionMetadataTests` (7) | 真实 26.3/1.16.5 元数据、`assetIndex.url`、logging `id`、数组参数 |
| `VersionResolverTests` (5) | 正常解析、缺失元数据、旧格式拒绝、继承拒绝、id 不一致 |
| `RuleEvaluatorTests` (23) | macOS/Linux、arm64/x86_64、allow/disallow 顺序、features、version 正则与区间 |
| `ArgumentResolverTests` (13) | 字符串/对象混合、数组展开、占位符、未知占位符报错 |
| `DependencyResolverTests` (27) | classpath 顺序与去重、缺失收集、legacy natives 告警、路径穿越 |
| `LaunchPlanBuilderTests` (22) | 脱敏、额外 JVM 参数位置、身份模式、确定性、26.3 端到端 preview |
| `JavaRuntimeInspectorTests` (15) | 真实 JDK、无效路径、架构/版本解析表 |
| `ProcessControllerTests` (11) | 正常/非零/信号退出、>1 MB 输出不死锁、终止、启动失败 |
| `SourceResolverTests` (11) | 四种源策略、显式镜像映射/前缀/查询串、非 HTTPS 拒绝、配置加载 |
| `DownloaderTests` (17) | 成功/哈希或大小不符/空文件、缓存命中与失效、重试、404、auto 回退、并发上限、去重、原子替换与失败保护 |
| `SafeZipExtractorTests` (10) | 正常/存储模式、`../`、嵌套穿越、绝对路径、symlink、损坏包、条目与数量上限 |
| `InstallerTests` (10) | 端到端安装、二次缓存、宽展修复、local-cache-only、mirror-only、版本筛选、natives 解压、verify 检出损坏 |
| `M2_5CompatibilityTests` (7) | JVM 架构上下文/Rosetta、per-JVM natives 缓存、规则按 JVM 架构、双向架构不匹配、缺失 natives、Mach-O/ZIP 架构检查 |
| `LocalOfflineIdentityTests` (9) / `InstanceRepositoryTests` (9) | UUID 向量、名字边界、账户无令牌字段、单一 `.minecraft` 与迁移、内存策略/删除 |
| `AuthenticationTests` (23) | 内嵌配置、PKCE RFC 向量、OAuth、state 拒绝、真实 loopback、Xbox/XSTS/Minecraft/所有权、Keychain |
| `LaunchServiceTests` (2) | 启动失败事件、事件流终止与重复调用 |
| `PathSafetyTests` (4) / `GameDataLayoutTests` (3) / `PlatformContextTests` (3) | 路径穿越、布局推导、平台上下文 |

安全测试约定：含 token 的 `LaunchPlan`、`--dry-run`、`--json`、日志文件都必须脱敏；游戏中 stdout/stderr 原样记录（启动器从不写完整命令行）。M2 测试全部使用内存传输层（`StubTransport`），不访问网络。

## 8. 任务与里程碑映射

| 任务 | 内容 | 状态 |
|---|---|---|
| T01 | Swift Package 骨架 | ✅ |
| T02 | 基础模型与 JSON 解码 | ✅ |
| T03 | RuleEvaluator（23 tests） | ✅ |
| T04 | DependencyResolver（27 tests） | ✅ |
| T05 | JavaRuntimeInspector（15 tests） | ✅ |
| T06 | LaunchPlanBuilder + ArgumentResolver（35 tests） | ✅ |
| T07 | GameProcessController（11 tests） | ✅ |
| T08 | CLI（version inspect / doctor / launch --dry-run） | ✅ 手工冒烟通过 |
| T09 | LocalOffline 身份（13 tests） | ✅ |
| T10 | 下载器（SourceResolver/Downloader/Zip/Installer） | ✅ 真实 1.20.1 安装 3635 文件 / 734.5 MB 通过 |
| M2.5 | JVM 架构感知 + 真实启动闭环 + 原子替换 | ✅ 真机 JDK17 ARM64 到主菜单并 exit 0（见 VERIFICATION-M2.5.md） |
| T11 | Microsoft 认证（OAuth+PKCE、Xbox/XSTS、Keychain） | ✅ 真机登录 `Ling_Xi_Fox`，UUID/所有权验证通过 |
| T12 | 正版启动回归 | ✅ CLI + GUI 到 1.20.1 主菜单，exit 0 |
| M5-A | SwiftUI GUI + `.app` + 六页 + 实时日志 | ✅ Alpha 可用（见 VERIFICATION-M3-M5.md） |

## 9. 剩余工作

- **M4**：Fabric/Quilt 加载器安装、版本继承解析、mods 目录与冲突提示。
- **M5-B**：下载任务历史、Java 自动安装/下载、更多诊断导出项。
- 外观：皮肤/披风纹理缓存、Cape 动画与更多皮肤模型细节。
- 真实大文件 GUI 下载中途取消、Intel Mac、Developer ID 签名/公证。
- 认证增强：多账户切换的 UI 覆盖、refresh token 轮换异常监控、全新浏览器 profile 的首次 consent 真机回归。

## 10. 开发沙盒

开发期的下载与实例数据统一放在仓库内（已 gitignore）：

```bash
mkdir -p .dev-sandbox
lingxi install vanilla --version 1.20.1 --instance dev-1201 --source official \
  --concurrency 8 --root .dev-sandbox/mc --data-root .dev-sandbox/data
```

- `.dev-sandbox/mc`：versions / libraries / assets（1.20.1 约 708 MB）
- `.dev-sandbox/data`：instances / accounts / natives / cache / logs
- 不写 `~/Library/Application Support/LingXiLauncher`，不改动官方 `.minecraft`。

## 11. 编码约定

- Swift 6 语言模式（严格并发），macOS 14 部署目标。
- 注释与测试名用英文；文档中文。
- 生产路径不使用强解包；错误一律用 `LauncherError`（稳定 code + 可执行建议）。
- 破坏性操作只发生在 `dataRoot` 下；`--root` 指向的用户游戏目录在 M1 内只读；`install` 只在显式请求时写入 `--root`。
- 临时文件放 `/tmp` 或 `.tmp/`，用完删除，不进仓库。
