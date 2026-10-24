# LingXi Launcher

macOS Apple Silicon 原生 **Minecraft: Java Edition** 启动器。当前进度：**M0 + M1 + M2（T01–T10）** —— 元数据解析、规则引擎、依赖解析、Java 检测、启动计划、进程控制、本地 CLI、本地离线身份，以及**无需登录的官方版本下载安装器**均已实现；正版认证（M3）、Fabric（M4）、SwiftUI GUI（M5）尚未实现。

> 这是一个**开发中**的项目，不是已发布产品。文档中的里程碑勾选状态以实际测试结果为准。

## 设计边界

- `LauncherCore` 是独立 Swift library，不依赖 SwiftUI/AppKit/CLI 参数解析，不进行用户交互。
- `lingxi` 只是薄外壳：解析 argv → 调用 Core API → 映射退出码。**没有任何启动/下载逻辑写在 CLI 里。**
- 未来 `LingXiMac`（M5）直接调用同一个 library，**不会**通过执行 CLI 获取核心功能。
- 零第三方依赖：Foundation / CryptoKit / Compression（系统框架）。

```text
LingXiMac (SwiftUI, M5)          lingxi (CLI)
        │                             │
        └──────────────┬──────────────┘
                       ▼
                 LauncherCore
   VersionResolver · RuleEvaluator · ArgumentResolver
   DependencyResolver · JavaRuntimeInspector · LaunchPlanBuilder
   GameProcessController · InstanceRepository · LocalOfflineIdentity
   SourceResolver · Downloader · ManifestService
   SafeZipExtractor · VanillaInstaller · InstallationVerifier
```

## 快速开始（开发沙盒，不写系统目录）

要求：macOS 14+、Apple Silicon、Swift 6 工具链（Xcode 26/27 自带）。

开发期的游戏文件全部放在仓库内的 `.dev-sandbox/`（已 gitignore），不碰 `~/Library`。1.20.1 约 **735 MB**。

```bash
swift build
swift test

# 1) 列出版本（下载官方 manifest 到 .dev-sandbox/data/cache）
swift run lingxi version list --type release --source official \
  --root .dev-sandbox/mc --data-root .dev-sandbox/data

# 2) 安装 1.20.1（官方源，8 并发；约 2–3 分钟）
swift run lingxi install vanilla --version 1.20.1 --instance dev-1201 \
  --name "Dev 1.20.1" --source official --concurrency 8 \
  --root .dev-sandbox/mc --data-root .dev-sandbox/data

# 3) 全量 SHA-1 校验
swift run lingxi verify --instance dev-1201 \
  --root .dev-sandbox/mc --data-root .dev-sandbox/data

# 4) 本地离线身份 + 脱敏启动预览
swift run lingxi account local create --name DevPlayer \
  --root .dev-sandbox/mc --data-root .dev-sandbox/data
swift run lingxi launch --instance dev-1201 --identity local:DevPlayer \
  --root .dev-sandbox/mc --data-root .dev-sandbox/data --dry-run
```

生产默认值不变：数据根目录 `~/Library/Application Support/LingXiLauncher`，游戏根目录默认指向官方启动器的 `~/Library/Application Support/minecraft`（只读引用）。任何下载/写入都只发生在显式传入的 `--root` / `--data-root` 下。

## 安装器（M2，无需登录）

```bash
lingxi version list [--type release|snapshot|all] [--source official|auto|mirror|local-cache-only]
lingxi install vanilla --version <id> --instance <id> [--source auto] [--name "..."]
                       [--mirror-config <path>] [--concurrency 4] [--java <path>]
lingxi verify --instance <id>
```

流程：官方 manifest（或已验证缓存）→ 版本 JSON（校验 manifest 内 SHA-1）→ client JAR / libraries / asset index / **全部 asset objects** → `.part` 临时文件 → SHA-1 + size 校验 → 原子落盘 → legacy natives 安全解压 → 生成 `instance.json` → 依赖完整性检查。**每一步都不需要 Microsoft 会话。**

- **源策略**：`official` 仅 Mojang 端点；`mirror` 仅显式配置的可信镜像；`auto` 官方优先、明确失败后切镜像；`local-cache-only` 完全不发网络请求。
- **镜像不是"官方授权"的同义词**：默认不内置任何镜像。使用需提供显式 host 映射 JSON（见 [docs/mirror-config.example.json](docs/mirror-config.example.json)），只允许 HTTPS，不做任意 URL 字符串替换。若评估 BMCLAPI，需自行核实其当前接口前缀、署名/使用规范、稳定性与 Minecraft EULA 要求。
- **校验**：以元数据的 SHA-1 + size 为准；校验失败的文件立即删除，绝不落盘为"已完成"。SHA-1 是与 Mojang 元数据兼容的校验和，不等同于现代数字签名。
- **缓存命中**：已存在的文件按 size（必要时 SHA-1）判断；`install` 修复缺失/大小不符，`verify` 做全量哈希校验。
- **并发与重试**：默认 4 路（可配 1–32）；网络/408/429/5xx 有上限重试，403/404 不重试；磁盘空间不足在下载前即报错。
- **Java 不会自动安装**：安装后仅提示所需主版本；用 `lingxi doctor --java ...` 检查实际运行时。

## 三种身份模式的硬性隔离

| 模式 | 状态 | 行为 |
|---|---|---|
| `local-offline` | **M1 已实现** | 玩家名 + Java 兼容的确定性离线 UUID（`OfflinePlayer:<name>` 的 MD5 v3）；`auth_access_token`/`xuid`/`clientid` 使用显式占位值 `0`，`user_type=legacy`。**不是购买验证。** |
| `microsoft` | M3，未实现 | 需要 Entra 应用 + Minecraft AppID 获批；CLI 明确返回 `NOT_IMPLEMENTED`，不会伪造会话。 |
| `licensed-offline` | M3，未实现 | 使用此前通过正版所有权校验的本地缓存；构建计划时明确抛错，不静默降级。 |

**严禁静默回退**：Microsoft 登录失败必须报错，绝不自动切换成本地身份；反之亦然。`LaunchPlan` 的 `description`/日志只使用脱敏 argv。

### 政策与发布门槛（必须如实披露）

本项目已有 Entra 应用 `LingXi Launcher`，**Minecraft AppID 审核状态尚未确认批准**。审核表要求"应用必须验证用户的游戏所有权并在启用游戏前认证"，并明确反对绕过认证与许可证检查。

- `LocalOffline` 是**本地技术验证路径**，不代表获得 Mojang 授权，也不代表能访问需要正版会话的服务。
- 若要把该能力带入面向公众、使用已获批 AppID 的发行版，**必须先向审核方如实披露并取得明确答复**；若不允许，发行版应禁用该模式。
- 不隐藏特性、不借用他人 Client ID、不自动回退以规避审核。
- 不随安装包分发任何游戏本体、资源或修改后的 JAR；下载器抓取的文件留在用户本机。

## 数据布局

```text
<root>/                                  # 游戏根（--root；开发期是 .dev-sandbox/mc）
├── versions/<id>/<id>.json + <id>.jar
├── libraries/<maven path>
├── assets/indexes/<asset-id>.json
├── assets/objects/<hash[0..2]>/<hash>
└── assets/log_configs/<id>

<data-root>/                             # 启动器数据（--data-root；开发期是 .dev-sandbox/data）
├── instances/<instance-id>/instance.json + .minecraft/
├── accounts/local/<name>.json           # 本地离线账户（无令牌字段，显式 unverified）
├── natives/<version-id>/<arch>/         # legacy natives 解压缓存，可重建
├── cache/manifests/version_manifest_v2.json
└── logs/launcher/                       # 仅记录脱敏后的 argv
```

## 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 3 | 没有可用 Java（版本/架构/可执行性） |
| 4 | preflight / verify 失败（缺失文件、架构不兼容、校验不通过） |
| 64 | 用法错误 |
| 65 | 元数据无效 / 校验和不匹配 |
| 66 | 缺少输入（版本 JSON、实例、账户） |
| 69 | 未实现 / 不可用（M3、网络或 HTTP 失败） |
| 70 | 内部错误 |
| 74 | I/O 错误（含磁盘空间、权限） |

游戏正常跑完时，启动器透传游戏自身的退出码。

## 当前限制（诚实清单）

- **尚未启动真实客户端进入单人主菜单**：`.dev-sandbox` 已有完整 1.20.1 文件并通过全量校验，但启动 GUI 游戏需要主人明确同意；进程链路已用子进程测试和一次"占位 jar"端到端启动验证覆盖。
- M3–M5 未开始：无 Microsoft 登录、无 Keychain、无 Fabric、无 GUI。
- Java 自动安装未实现（仅检测与提示）。
- legacy `virtual` / `map_to_resources` 资产索引（1.6 及更早）只下载对象、不生成 resources 树；现代版本不受影响。
- 旧版 natives 架构只能在 classifier 明确写出时判定：`-x86_64` 报 error；仅 `natives-macos` 的旧版给 warning，提示可能需要 Rosetta，绝不自动做混合架构修复。
- 同尺寸但内容损坏的文件不会被 `install` 自动发现（依赖解析只做 stat），请用 `lingxi verify` 做哈希级校验。

更多实现细节见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。
