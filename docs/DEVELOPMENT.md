# 开发说明（M1 / T01–T09）

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
│   ├── GameDataLayout.swift      # dataRoot / gameRoot 路径推导（全部做路径穿越防护）
│   └── PathSafety.swift          # zip entry / 相对路径的安全校验
├── Version/
│   ├── VersionResolver.swift     # 读取并规范化版本 JSON（拒绝旧格式与继承）
│   ├── RuleEvaluator.swift       # Mojang rules（T03）
│   └── ArgumentResolver.swift    # arguments 展开与占位符替换（T06）
├── Runtime/JavaRuntimeInspector.swift     # 真实执行 java 探测版本/架构（T05）
├── Launch/
│   ├── DependencyResolver.swift  # 规则过滤 → classpath/natives/assets（T04）
│   ├── LaunchPlanBuilder.swift   # 纯转换：preview / build / validate（T06）
│   ├── GameProcessController.swift        # Process + 异步流 + 退出码（T07）
│   └── LocalOfflineIdentity.swift         # 离线 UUID v3（T09）
├── Instance/
│   ├── InstanceRepository.swift  # 实例创建/加载/列出
│   └── LocalAccountStore.swift   # 本地离线账户（无令牌字段）
└── LingXiCLI/                    # 薄外壳：argv 解析、Core 调用、退出码映射
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
- 工作目录固定为实例的 `.minecraft`。

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

## 6. 测试

```bash
swift build
swift test
```

当前总计 **151 个测试**，连续两次全量运行 0 失败：

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
| `LocalOfflineIdentityTests` (9) / `InstanceRepositoryTests` (5) | UUID 向量、名字边界、账户无令牌字段、实例隔离 |
| `PathSafetyTests` (4) / `GameDataLayoutTests` (3) / `PlatformContextTests` (3) | 路径穿越、布局推导、平台上下文 |

安全测试约定：含 token 的 `LaunchPlan`、`--dry-run`、`--json`、日志文件都必须脱敏；游戏中 stdout/stderr 原样记录（启动器从不写完整命令行）。

## 7. 任务与里程碑映射

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
| T10 | 下载器（官方/镜像/auto/local-cache-only、原子下载、校验） | ⬜ M2 |
| T11 | Microsoft 认证（OAuth+PKCE、Xbox/XSTS、Keychain） | ⬜ M3（AppID 未获批） |
| T12 | 正版启动回归 | ⬜ M3 |

## 8. 下一步（M2）接口预留

- `MissingDependency` 已携带 `downloadURL`/`sha1`/`size`，`SourceResolver` 可直接消费，无需改动 Core 契约。
- `DependencyResolution` 已给出 `layout`，下载器按 `MissingDependency.kind` 落盘到 `versions/`、`libraries/`、`assets/objects/`、`natives/`。
- 下载实现必须：`.part` 临时文件 → 校验 SHA-1/size → 原子 rename；Zip Slip / symlink escape 防护复用 `PathSafety`。
- 新增目标（`Installer`）时保持不变式：**Installer 不构造 JVM 参数，Core 不执行下载**。

## 9. 编码约定

- Swift 6 语言模式（严格并发），macOS 14 部署目标。
- 注释与测试名用英文；文档中文。
- 生产路径不使用强解包；错误一律用 `LauncherError`（稳定 code + 可执行建议）。
- 破坏性操作只发生在 `dataRoot` 下；`--root` 指向的用户游戏目录在 M1 内只读。
- 临时文件放 `/tmp` 或 `.tmp/`，用完删除，不进仓库。
