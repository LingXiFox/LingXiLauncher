# M6.1 验证记录：一站式安装

验证日期：2026-10-27  
环境：macOS 27.2（26B123）、Apple Silicon arm64、Swift 6.4.2、LingXi Launcher 0.3.0  
自动化测试：**244 tests, 0 failures**

## 1. 实现范围

### 1.1 版本继承与合并

`VersionResolver` 现在从子版本向上加载 `inheritsFrom` 链，再按 parent → child 合并：

- `mainClass`、`assetIndex`、`downloads`、`logging`、`javaVersion` 采用 child 覆盖/最高 Java 要求；
- `libraries` 按 Maven group/artifact/classifier/natives 身份合并，child 覆盖同名 parent；
- `arguments.game` / `arguments.jvm` 保持结构化数组顺序拼接，**不拼接 shell 字符串**；
- 检测循环继承、缺失父版本、空 `mainClass`、缺失 asset index；
- legacy `minecraftArguments` 转换为结构化 game args，并给出 legacy JVM 基线；对应版本标记 `.legacyArguments`，GUI/启动诊断不会把它标成完全现代兼容；
- 缺失 JVM 参数的结构不完整版本标记 `.incomplete`；
- Fabric 子版本没有 client JAR 时，使用 parent 的 `clientJarVersionID` 和 parent 的 `nativesVersionID`，避免重复下载/解压原生库。

真实 Fabric profile fixture：`Tests/LauncherCoreTests/Fixtures/versions/fabric-loader-0.20.1-1.20.1.json`（来自 `https://meta.fabricmc.net/v2/versions/loader/1.20.1/0.20.1/profile/json`）。测试验证了 1.20.1 parent 合并、ASM 子版本覆盖、Fabric mainClass、Java 17 要求、结构化参数和 Maven URL。

### 1.2 Fabric 安装

新增 `FabricInstaller` 与统一入口 `OneStopInstaller`：

- 通过 Fabric 官方兼容端点查询对指定 Minecraft 版本可用的 Loader；
- 通过官方 profile 端点获取 `inheritsFrom` 配置；
- 使用 Fabric 官方 Maven `https://maven.fabricmc.net/`，支持 top-level `url`/`sha1`/`size` 的 Maven 库；
- 先把 vanilla 文件安装到临时 stage，再解析/下载 Fabric 依赖，成功后才创建/更新目标实例；
- 失败/取消删除 stage，目标实例不被修改；已下载共享文件保留以便重试；
- 新实例默认；已存在实例必须显式 `updateExistingInstance`，更新前备份 `instance.json`，不删除世界、模组或配置；
- profile 写入使用原子替换；
- reuse parent vanilla client JAR、assets、libraries 和 natives 缓存。

真实安装记录：

```text
lingxi install fabric --version 1.20.1 --instance fabric-1201 \
  --name "Fabric 1.20.1" --loader 0.20.1 \
  --java /Library/Java/JavaVirtualMachines/microsoft-17.jdk/Contents/Home/bin/java \
  --root .dev-sandbox/mc --data-root .dev-sandbox/data
```

结果：

- profile：`fabric-loader-0.20.1-1.20.1`
- Loader：**0.20.1**
- Fabric Maven 文件：**8 个，4.5 MB，0 failures**
- vanilla 3575 个共享文件：全部缓存命中
- 目标实例：`fabric-1201`
- 临时 stage 已清理

启动记录：

- GUI 新实例 `fabric-1-20-1`（由安装向导创建）启动到 **Minecraft 1.20.1 / Fabric (Modded) 主菜单**；
- 游戏进程正常退出码 0；
- 另一次使用托管 Temurin 17.0.21 的 GUI 启动也到达主菜单。

见：[Fabric 主菜单](evidence/M6.1/10-fabric-main-menu.jpg)。

### 1.3 JavaManager

新增 `JavaManager`：

- 基于现有 `JavaRuntimeInspector` 探测系统、PATH、托管运行时；
- 按版本元数据与 Loader 的 `min_java_version` 选择兼容 Java，不硬编码所有版本统一 Java 17；
- 托管 JDK 从 **Eclipse Temurin / Adoptium API** 获取，仅 macOS arm64；
- 下载后校验发布方 SHA-256 和 size，再用 `/usr/bin/tar` 解压到 `<dataRoot>/java`，最后 probe `java`；
- 不修改 `/Library/Java`、`/usr/bin/java` 或 `JAVA_HOME`；
- 保留用户手动选择 JDK 的入口；
- GUI 展示版本、架构、来源和许可。

真实验证：

- Temurin **17.0.21+9** 下载成功（约 186 MB）；
- SHA-256：`78b08c7f5a0598242d5719c022e19479cb4a3aa45c37c19726a757a469ed1c15`；
- 托管路径：`.dev-sandbox/data/java/temurin-17-17.0.21_9/Contents/Home/bin/java`；
- 在 `sandbox-exec` 隐藏系统 `/Library/Java` 与 `/usr/bin/java` 的 GUI 环境中，向导正确显示“没有找到兼容的 Java”，确认下载后安装托管 Temurin，随后完成 Fabric 安装；
- 在隐藏系统 Java 的 GUI 环境中，使用托管 Java 完成 1.20.1 + Fabric 安装；
- 在同一隐藏系统 Java 的 sandbox 环境中，用 CLI 的 local-offline 技术身份 + 托管 Temurin 启动 `fabric-1-20-1` 到 **Minecraft 1.20.1 / Fabric (Modded) 主菜单**；这验证“无系统 Java + 托管 Java + Fabric”的运行时链路（GUI 的 Microsoft 身份启动也在托管 Java 下到达主菜单）。

截图：[无兼容 Java](evidence/M6.1/07-no-java-detected.jpg)、[下载确认](evidence/M6.1/08-java-download-confirmation.jpg)、[托管 Java 已选择](evidence/M6.1/09-managed-java-selected.jpg)、[无系统 Java 的 Fabric 主菜单](evidence/M6.1/11-managed-java-no-system-java-game.jpg)。

### 1.4 安装目标

`OneStopInstaller` 明确区分：

- `.newInstance(id:displayName:)`：默认；目标 ID 已存在则拒绝；
- `.existingInstance(id:)`：必须由 GUI 显式切换并勾选风险确认；更新前备份 `instance.json`；不删除世界/模组/配置；
- 失败或取消不会创建目标实例；所有下载在提交前完成。

自动化测试：

- 新实例目标 ID 冲突时拒绝；
- 已有实例未显式选择更新时拒绝；
- 失败的新安装不创建目标；
- 显式更新创建 manifest 备份，且保留 `level.dat`。

### 1.5 SwiftUI 安装向导

新增 `InstallWizardView`，从任意页面工具栏的“安装游戏”或版本下载页打开：

1. 选择 Minecraft 版本（默认 1.20.1，显示已选择摘要）；
2. 选择 Vanilla / Fabric，Fabric 只列官方兼容 Loader；
3. Java 检测、兼容性提示、手动选择或确认下载托管 JDK；
4. 实例名称/目录；默认创建新实例；更新现有实例需风险确认；
5. 确认摘要；
6. 下载/校验/进度/取消/失败重试；
7. 完成。

界面复用 Fox Orange Design System，没有整体重做视觉；安装、Java 下载和版本解析全部调用 LauncherCore，不在 View 里发网络请求或拼装版本元数据。

截图：

| 步骤 | 截图 |
|---|---|
| 选择版本 | [01](evidence/M6.1/01-wizard-version.jpg) |
| Fabric Loader | [02](evidence/M6.1/02-wizard-fabric-loader.jpg) |
| Java 检测 | [03](evidence/M6.1/03-wizard-java-runtime.jpg) |
| 新实例目标 | [04](evidence/M6.1/04-wizard-new-instance.jpg) |
| 确认 | [05](evidence/M6.1/05-wizard-confirm.jpg) |
| 完成 | [06](evidence/M6.1/06-wizard-done.jpg) |

## 2. 测试

```text
swift test
Executed 244 tests, with 0 failures (0 unexpected)
```

覆盖新增：

- `VersionResolverTests`：继承合并、缺失父版本、循环继承、legacy 参数、真实 Fabric profile；
- `M6InstallTests`：Fabric 兼容 Loader 端点、目标冲突拒绝、显式更新备份/存档保留、失败不创建目标、Java 无兼容运行时、SHA-256 向量；
- 原有 Microsoft 认证/Keychain、启动计划、下载校验、实例隔离、内存、外观测试全部通过。

## 3. 已知限制

- 本阶段只支持 Vanilla 与 Fabric；Forge/NeoForge/Quilt 未实现。
- 托管 JDK 下载仅支持 macOS Apple Silicon arm64；Intel Mac 需手动选择 JDK。
- Fabric profile/Maven 网络请求目前只走 Fabric 官方 HTTPS；镜像策略不映射 Fabric 元数据。
- legacy `minecraftArguments` 是兼容转换，标记为 `.legacyArguments`，不承诺覆盖所有旧版本；结构不完整版本标记 `.incomplete`。
- 现有实例“更新”只备份 `instance.json` 并改变版本指针；不会复制世界/模组。世界、模组和配置本身不会被删除，但用户仍应在确认界面理解版本切换风险。
- Fabric 安装的 stage 是临时实例；成功后删除，共享下载缓存保留。

## 4. 验证后清理

按用户要求，验证完成后删除 `.dev-sandbox` 中下载的 Minecraft 文件、Fabric 库、托管 JDK、临时实例和测试数据；保留本文档中的截图与脱敏结果。
