# M6.1.1 + M6.2 验证记录

验证日期：2026-10-28  
环境：macOS 27.2（26B123）、Apple Silicon arm64、Swift 6.4.2、LingXi Launcher 0.3.0  
自动化测试：**257 tests, 0 failures**

## 1. M6.1.1 稳定性修复

### Java 托管运行时安全替换

`JavaManager` 现在按以下顺序更新托管 JDK：

1. 下载并校验发布方 checksum + size；
2. 解压到独立 staging；
3. 在 staging 中 probe `java -version`；
4. 写入 `source.json`；
5. 校验通过后，把旧目录移到隐藏 backup；
6. 把新目录移入最终位置并再次 probe；
7. 成功后才删除 backup；任何移动/probe 失败都恢复旧 JDK。

测试：`JavaManagerSafetyTests`（最终 probe 失败恢复旧目录、成功提交清理 backup、Mojang runtime 完整安装、元数据 Java 要求判断）。

### Java 来源与可复现性

现代 Minecraft 元数据提供 `javaVersion.component`（如 `java-runtime-gamma`）。向导优先从 Mojang 官方 `java-runtime` 清单选择 macOS arm64 构建，下载并逐个校验官方 manifest/files 的 SHA-1，按 `component + runtime version + manifest SHA-1` 固定目录；只有 Mojang 未提供该 component/平台时才回退 Temurin。

安装/启动后会把实际 Java 写入 `instance.json` 的 `javaRuntime`：

```json
{
  "source": "Mojang java-runtime",
  "component": "java-runtime-gamma",
  "version": "17.0.15",
  "architecture": "arm64",
  "artifactSHA1": "e0c8d5ccfe8cfb38075ff1b7f6352d7b03fd7868",
  "executable": "…/jre.bundle/Contents/Home/bin/java"
}
```

Temurin 回退记录 `artifactSHA256`；手动 JDK 也会记录可执行文件 SHA-256。

### 安装向导 Java 即时重验

切换 Minecraft 版本、Loader 或 Fabric Loader 版本时会清空旧 Java 选择；进入 Java 步骤时重新读取版本元数据与 Fabric Loader 的 `min_java_version`。如果已选 Java 的主版本低于要求，会自动重新选择兼容运行时，不能继续到确认页。Java 下载仍必须由用户确认。

### Fabric 兼容矩阵

使用官方 profile 与 vanilla parent metadata 覆盖：

| Minecraft | Fabric profile | Java | Asset |
|---|---|---|---|
| 1.16.5 | `fabric-loader-0.20.1-1.16.5` | 8 | 1.16 |
| 1.20.1 | `fabric-loader-0.20.1-1.20.1` | 17 | 5 |
| 1.21.11 | `fabric-loader-0.20.1-1.21.11` | 21 | 29 |
| 26.3（当前正式版） | `fabric-loader-0.20.1-26.3` | 25 | 34 |

测试文件：`ManifestTests.testRealFabricCompatibilityMatrix`；fixture 来自 Mojang/Fabric 官方元数据快照。

### 实例更新安全

- 新安装默认目标不存在；已存在目录（包括损坏 manifest）在下载前 fail closed。
- 显式更新先备份 `instance.json`；backup 文件名含唯一 nonce，避免同一秒覆盖。
- stage 失败/取消不会创建或修改目标实例。
- 更新后测试保留 `level.dat`；损坏 manifest 测试保持原文件字节不变。
- Fabric/OneStop 的 stage 在成功提交后清理；下载缓存保留供重试。

## 2. M6.2 Modrinth Fabric 模组管理

### Core

- `ModrinthClient`：官方 v2 API，强制唯一 User-Agent，搜索 facets（`project_type:mod` + `categories:fabric` + `versions:<mc>` + 分类），分页，排序；项目、版本、图标读取。
- `ModManager`：真实 Minecraft/Fabric 兼容性上下文、必需依赖递归解析、可选/内嵌/冲突依赖分类、固定版本依赖、重复安装拒绝。
- `ModRepository`：实例独立 `mods/`、`mods-disabled/` 和 `mods.json`；staging → 全量校验 → 原子提交；更新先备份旧 JAR，失败恢复；启用/禁用移动文件；删除不触碰存档。
- Modrinth 文件优先校验 SHA-512，缺少时 SHA-1；校验 size；只接受 `cdn.modrinth.com` HTTPS URL。
- 更新检测按当前实例 game version/loader 查询兼容版本；用户确认后调用相同的安装/替换流程。

### GUI

实例详情新增「模组管理」入口，打开双视图 sheet：

- **已安装**：图标、启用状态、版本/文件名、来源/许可证、更新检测、更新、启用/禁用、删除。
- **浏览模组**：Modrinth 搜索、分类、排序、分页、项目详情、版本选择、依赖说明、安装进度、错误反馈。
- 图标由 Core 获取并缓存，SwiftUI 不直接请求 Modrinth API。
- 沿用 Fox Orange Design System，没有重做其他页面。

截图：

| 内容 | 截图 |
|---|---|
| 已安装模组 | [01](evidence/M6.2/01-installed-mods.jpg) |
| 浏览/搜索 | [02](evidence/M6.2/02-browse-modrinth.jpg) |
| 发现更新 | [03](evidence/M6.2/03-update-available.jpg) |
| 依赖详情 | [05](evidence/M6.2/05-search-dependencies.jpg) |
| 游戏主菜单 | [04](evidence/M6.2/04-modded-main-menu.jpg) |

## 3. 真实运行验证

真实安装 Minecraft 1.20.1 + Fabric Loader 0.20.1：

```text
lingxi install fabric --version 1.20.1 --instance fabric-mods --loader 0.20.1 ...
```

首次下载因 2 个 asset 网络超时中止，重试复用已校验文件后完成；最终 profile 为 `fabric-loader-0.20.1-1.20.1`。

真实 Modrinth 安装：

```text
Fabric API  0.92.12+1.20.1  fabric-api-0.92.12+1.20.1.jar
Sodium      mc1.20.1-0.5.13-fabric
Lithium     mc1.20.1-0.11.4-fabric
```

游戏日志确认：

```text
Loading 60 mods:
  - fabric-api 0.92.12+1.20.1
  - lithium 0.11.4
  - sodium 0.5.13+mc1.20.1
```

游戏进入 **Minecraft 1.20.1 / Fabric (Modded)** 主菜单，见截图 04。测试使用 local-offline 技术身份启动（GUI 的正版启动需要 Microsoft 账户）；Microsoft 认证、Keychain 和启动代码未修改。测试结束强制结束游戏进程（退出码 143），不代表启动失败。

### 实际更新与依赖验证

- `lingxi mod updates --instance fabric-mods` 检测到 Lithium `0.11.3 → 0.11.4`；
- `lingxi mod install --project lithium --version ... --replace` 更新成功，旧 JAR 被替换，版本列表无剩余更新；
- 单元测试覆盖必需/固定版本依赖自动安装、重复安装拒绝、不兼容依赖拒绝、更新哈希失败保留旧文件；
- Modrinth API 真实搜索 `sodium` 返回结果，真实描述、许可证和图标均成功读取。

### Mojang Java runtime

真实执行：

```text
lingxi java install --major 17 --component java-runtime-gamma --yes --data-root .dev-sandbox/data
```

结果：

- component：`java-runtime-gamma`
- version：`17.0.15`
- manifest SHA-1：`e0c8d5ccfe8cfb38075ff1b7f6352d7b03fd7868`
- 路径：`.dev-sandbox/data/java/mojang-java-runtime-gamma-17.0.15-e0c8d5ccfe/jre.bundle/Contents/Home/bin/java`
- `lingxi java list` 显示 source `Mojang java-runtime`
- 启动 `fabric-mods` 后 `instance.json` 写入 `javaRuntime`（source/component/version/artifactSHA1/executableSHA256），记录见 [06-instance-java-runtime.json](evidence/M6.2/06-instance-java-runtime.json)。

## 4. 调试自动化接口

新增 `docs/DEBUG-AUTOMATION.md` 描述的 opt-in loopback TCP 接口：

- 默认关闭，只有 `LINGXI_DEBUG_AUTOMATION=1` 或 `--debug-automation` 启用；
- 只绑定 loopback；
- action 直接调用 GUI 真实按钮使用的方法，并在返回时读取实际页面状态；
- 已实际使用 `mods.open`、`mods.search`、`mods.select`、`mods.checkUpdates`、`mods.update`、`mods.toggle`、`mods.close` 验证，避免鼠标误点。

## 5. 已知限制

- 只实现 Fabric；Forge/NeoForge/Quilt/整合包不在 M6.2 范围。
- Modrinth 搜索/更新受官方 300 req/min/IP 限制；当前实现不并发轰炸 API。
- 模组下载只接受 `cdn.modrinth.com` HTTPS；这是安全边界，不是通用 URL 下载器。
- 没有自动安装可选依赖；会在 UI 标识。
- 当前实例的本地离线启动仅用于 CLI 技术验证；GUI 正版启动仍需 Microsoft 账户。
- 更新只保留旧 JAR 的临时备份；不复制世界。世界/配置不会被本功能修改。

## 6. 清理

按用户要求，验证完成后删除 `.dev-sandbox` 中的 Minecraft 游戏文件、Fabric 库、模组 JAR、实例、日志和测试下载；保留文档截图与脱敏证据。
