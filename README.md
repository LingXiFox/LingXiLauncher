# LingXi Launcher

macOS Apple Silicon 原生 **Minecraft: Java Edition** 启动器。当前进度：**M0 + M1（T01–T09）** —— 元数据解析、规则引擎、依赖解析、Java 检测、启动计划、进程控制与本地 CLI 已实现；下载器（M2）、正版认证（M3）、Fabric（M4）、SwiftUI GUI（M5）尚未实现。

> 这是一个**开发中**的项目，不是已发布产品。文档中的里程碑勾选状态以实际测试结果为准。

## 设计边界

- `LauncherCore` 是独立 Swift library，不依赖 SwiftUI/AppKit/CLI 参数解析，不进行用户交互。
- `lingxi` 只是薄外壳：解析 argv → 调用 Core API → 映射退出码。**没有任何启动逻辑写在 CLI 里。**
- 未来 `LingXiMac`（M5）直接调用同一个 library，**不会**通过执行 CLI 获取核心功能。
- 零第三方依赖：仅 Foundation / CryptoKit（系统框架）。

```text
LingXiMac (SwiftUI, M5)          lingxi (CLI)
        │                             │
        └──────────────┬──────────────┘
                       ▼
                 LauncherCore
   VersionResolver · RuleEvaluator · ArgumentResolver
   DependencyResolver · JavaRuntimeInspector · LaunchPlanBuilder
   GameProcessController · InstanceRepository · LocalOfflineIdentity
```

## 快速开始

要求：macOS 14+、Apple Silicon、Swift 6 工具链（Xcode 26/27 自带）。

```bash
swift build                    # 编译 library + CLI
swift test                     # 全部单元测试
swift run lingxi --help
```

M1 只读取已有的 `.minecraft` 数据，不下载、不修改游戏文件：

```bash
# 读取现有版本元数据
swift run lingxi version inspect --id 1.20.1 --root "$HOME/Library/Application Support/minecraft"

# 诊断 Java 与缺失文件（本机已有 JDK 时）
swift run lingxi doctor --root "$HOME/Library/Application Support/minecraft" --version 1.20.1

# 本地离线身份（未验证所有权，仅本地技术验证）
swift run lingxi account local create --name TestPlayer
swift run lingxi instance create --name "Vanilla 1.20.1" --version 1.20.1
swift run lingxi launch --instance <instance-id> --identity local:TestPlayer --dry-run
```

`--dry-run` 输出脱敏、确定性的启动预览：Java 路径、主类、classpath 条目数、实例目录、JVM 参数、游戏参数（`--accessToken` 已替换为 `<redacted>`）、缺失依赖摘要和身份模式。它不会启动进程，也不会写文件。

`--json` 提供机器可读输出，供 CI/调试使用。

## 三种身份模式的硬性隔离

| 模式 | 状态 | 行为 |
|---|---|---|
| `local-offline` | **M1 已实现** | 只生成玩家名 + Java 兼容的确定性离线 UUID（`OfflinePlayer:<name>` 的 MD5 v3）；`auth_access_token`/`xuid`/`clientid` 使用显式占位值 `0`，`user_type=legacy`。**不是购买验证。** |
| `microsoft` | M3，未实现 | 需要 Entra 应用 + Minecraft AppID 获批；CLI 目前明确返回 `NOT_IMPLEMENTED`，不会伪造会话。 |
| `licensed-offline` | M3，未实现 | 使用此前通过正版所有权校验的本地缓存；构建计划时明确抛错，不静默降级。 |

**严禁静默回退**：选择 Microsoft 登录失败时报错退出，绝不自动切换成本地身份；反之亦然。本地离线身份不能伪装成 `AuthorizedMinecraftSession`，代码层面也不提供伪造入口（`AuthorizedMinecraftSession` 无公开构造器，`description` 恒为脱敏值）。

### 政策与发布门槛（必须如实披露）

本项目已有 Entra 应用 `LingXi Launcher`，**Minecraft AppID 审核状态尚未确认批准**。审核表要求“应用必须验证用户的游戏所有权并在启用游戏前认证”，并明确反对绕过认证与许可证检查。

- `LocalOffline` 是**本地技术验证路径**，不代表获得 Mojang 授权，也不代表能访问需要正版会话的服务。
- 若要把该能力带入面向公众、使用已获批 AppID 的发行版，**必须先向审核方如实披露并取得明确答复**；若不允许，发行版应禁用该模式（开发代码可保留）。
- 不隐藏特性、不借用他人 Client ID、不自动回退以规避审核。
- 不随安装包分发任何游戏本体、资源或修改后的 JAR。

## 数据布局

```text
~/Library/Application Support/LingXiLauncher/     # dataRoot（本启动器自己的数据）
├── instances/<instance-id>/
│   ├── instance.json
│   ├── .minecraft/            # gameDir：世界、logs、crash-reports
│   └── ...
├── accounts/local/<name>.json # 本地离线账户（无令牌字段，显式 unverified）
├── natives/<version-id>/<arch>/
└── logs/launcher/             # 启动日志（只记录脱敏后的 argv）
```

游戏本体 / libraries / assets 来自 `--root` 指定的 `.minecraft`（与官方启动器共享），M1 **只读引用**，绝不覆写、搬迁或清空用户目录。

## 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 3 | 没有可用 Java（版本/架构/可执行性） |
| 4 | preflight 阻断（缺失文件、架构不兼容等） |
| 64 | 用法错误 |
| 65 | 元数据无效 / 不支持的版本格式 |
| 66 | 缺少输入（版本 JSON、实例、账户） |
| 69 | 未实现 / 不可用（M2/M3，AppID 未获批） |
| 70 | 内部错误 |
| 74 | I/O 错误 |

游戏正常跑完时，启动器透传游戏自身的退出码。

## 当前限制（诚实清单）

- 只支持现代 `arguments` 元数据；旧版 `minecraftArguments` 与 `inheritsFrom`（Fabric/Forge）**检测后明确报错**，M4 再实现。
- 不下载任何文件：缺失依赖只报告，不补齐（M2）。
- 资产对象逐个校验属于 M2；M1 只检查 `assetIndex` 文件存在性与大小。
- 尚未在真实完整游戏文件上跑通“进入单人主菜单”（本机 `.minecraft` 无 `versions/` 目录，需要 M2 下载器或用户已有文件）。已验证的部分：CLI 全链路（`version inspect` / `doctor` / `launch --dry-run` / 真实 `Process` 启动、输出流、日志脱敏、退出码透传）用 1.20.1 元数据 + 稀疏占位文件跑通，Java 因占位 jar 无效而以 code 1 退出并被正确上报。
- 正版认证、Keychain、Fabric、GUI 均未开始。
- 旧版 natives 的架构只能在 classifier 明确写出时判定：classifier 带 `-x86_64`/`-x64` 的会在 preflight 阶段报 error；只写 `natives-macos` 的旧版（如 1.16.5）无法静态判定，给出 warning 提示可能需要 Rosetta，绝不自动做混合架构修复。

更多实现细节见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。
