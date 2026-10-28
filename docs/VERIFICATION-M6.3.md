# M6.2.1 + M6.3 验证记录

验证日期：2026-10-28  
环境：macOS 27.2（26B123）、Apple Silicon arm64、Swift 6.4.2、LingXi Launcher 0.3.0  
自动化测试：**270 tests, 0 failures**

## 1. M6.2.1 稳定性修复

### 1.1 依赖冲突不再直接拒绝

`ModManager` 现在把 `dependency_type: incompatible` 当作冲突声明而不是必需依赖：

- 目标项目未安装：允许安装；
- 目标项目已安装但已禁用：允许安装；
- 目标项目已启用，且 project/version/file 约束匹配：明确拒绝；
- 固定 `version_id` 不匹配：不视为冲突；
- 本次事务规划中的必需依赖也会参与冲突检查。

回归测试：缺少目标、启用目标、禁用目标、固定版本约束四个场景。

### 1.2 更新禁用模组保留禁用状态

`ModManager` 在替换 primary 时继承旧记录的 `enabled`；`ModRepository` 根据记录状态把新 JAR 写入 `mods/` 或 `mods-disabled/`，并在提交失败时回滚旧文件。测试覆盖禁用模组 `v1 → v2` 后文件仍在 `mods-disabled/`、记录仍为 disabled。

### 1.3 更新检测不再比较发布日期

`updates` 现在：

- 当前版本必须仍出现在兼容版本列表中，否则不猜测更新；
- 按当前版本的发布渠道过滤候选：release 不接收 beta/alpha，beta 接收 release/beta，alpha 接收 release/beta/alpha；
- 使用自然版本号比较（支持 `mc1.20.1-0.11.4-fabric` 这类 Modrinth 版本号），只在候选版本号确实更新时报告；
- 日期只作为元数据，不参与“更新/降级”判断。

测试覆盖新 release、较旧版本但日期更晚、beta 不应升级 release 安装。

### 1.4 DebugAutomation 安全

- 整个监听器/action registry 包在 `#if DEBUG` 中；Release 构建编译为无监听器、无 action registry 的 stub。
- Debug 构建仍要求 `LINGXI_DEBUG_AUTOMATION=1` 或 `--debug-automation`。
- 每次启动生成随机会话 token，stderr 输出；所有请求必须携带 token，错误 token 返回 `unauthorized debug session`。
- 只绑定 loopback；token 不写入磁盘。
- 文档：[DEBUG-AUTOMATION.md](DEBUG-AUTOMATION.md)。
- 验证：`swift build -c release --product LingXiMac` 通过，Release 二进制中不包含 `59321`、`LINGXI_DEBUG_AUTOMATION` 或监听器启动字符串；Debug 构建实测错误 token 返回 unauthorized，正确 token 可执行。

## 2. M6.3 Modrinth .mrpack

### 解析与安全

Core 新增：

- `MrpackParser`：严格读取 `modrinth.index.json`，校验 format 1、game、name/version、Minecraft、Fabric Loader、文件清单、客户端环境；
- 复用 `SafeZipExtractor`：拒绝 ZIP 路径穿越、绝对路径、反斜杠、符号链接、ZIP64 与超限条目/总展开大小；归档上限 512 MiB，条目 20,000 个，单条目 256 MiB，总展开 1 GiB；
- `overrides` 先应用，`client-overrides` 后应用；
- `env.client == unsupported` 的文件跳过，不下载；
- 外部文件必须有 SHA-1 或 SHA-512、fileSize，且下载 URL 必须是 `https://cdn.modrinth.com`；缺少哈希或非 Modrinth CDN 会在安装前失败，不跳过校验；
- 所有下载文件进入 `Downloader` 的持久缓存并做 size + SHA-1/SHA-512 校验。

### 事务安装

`MrpackInstaller`：

1. 解析/解压到独立临时目录；
2. 通过 `Downloader` 下载到 `dataRoot/cache/mrpack/<archive-sha256>/` 并校验；
3. 构建 pack staging（external files + overrides）；
4. 全部校验通过后，才调用 `OneStopInstaller` 创建全新实例并安装 Minecraft/Fabric；
5. 把 staging 文件提交到新实例；目标已存在文件时拒绝覆盖；
6. 提交失败删除刚创建的实例；取消/失败清理 staging/extraction，保留已验证缓存用于重试；
7. 不修改系统 Java，不触碰已有实例的世界/配置/模组。

GUI 入口在实例页「导入整合包」，支持文件选择与 Finder 拖放；展示包名、版本、MC/Fabric、文件清单、overrides、下载大小、Java 选择/自动匹配，安装时显示阶段和进度，失败显示具体原因与建议。Java 无兼容运行时可请求 JavaManager 优先安装 Mojang runtime。

## 3. 真实测试

### 真实整合包

使用 Modrinth 官方 CDN 下载：

- 项目：Fabulously Optimized（`1KVo5zza`）
- 版本：`5.4.1`（`2ZbcYfCj`）
- `.mrpack`：58,960 bytes
- Minecraft 1.20.1 / Fabric Loader 0.14.23
- 51 个外部文件 + 27 个 overrides
- 外部下载 27.9 MB

真实安装结果：

```text
instance: fo-541-real-031686bb
installed files: 78
game dir: .dev-sandbox/data/.minecraft/versions/fo-541-real-031686bb
```

真实启动（local-offline 技术身份 `PackTester`）：

```text
Loading 149 mods:
  - fabric-api ...
  - sodium ...
  - iris ...
Minecraft 1.20.1 / Fabric (Modded) main menu reached
```

截图：[真实整合包主菜单](evidence/M6.3/04-real-pack-main-menu.jpg)。测试结束按预期强制结束进程（退出码 143）。安装与启动脱敏记录：[real-pack-install.txt](evidence/M6.3/real-pack-install.txt)、[real-pack-launch.txt](evidence/M6.3/real-pack-launch.txt)。

GUI 使用同一真实 `.mrpack` 完成解析、Java 检测、安装，创建 `fabulously-optimized-b3d48319`，提交 78 个文件。截图：

| 内容 | 截图 |
|---|---|
| 导入解析/Java/文件清单 | [01](evidence/M6.3/01-import-review.jpg) |
| GUI 安装完成 | [02](evidence/M6.3/02-import-complete.jpg) |
| 实例列表 | [03](evidence/M6.3/03-pack-instances.jpg) |
| 真实整合包主菜单 | [04](evidence/M6.3/04-real-pack-main-menu.jpg) |

CLI：

```bash
lingxi mrpack inspect --file Fabulously.Optimized-5.4.1.mrpack
lingxi mrpack install --file Fabulously.Optimized-5.4.1.mrpack \
  --name "FO 5.4.1 Real" --java <jdk> --root <mc> --data-root <data>
```

### 失败/取消/重试

自动化测试覆盖：

- 外部文件大小/哈希错误：不创建实例，错误码明确；
- 网络失败：不创建实例；
- 网络恢复后重试：成功创建实例；
- 安装任务取消：不创建实例，清理临时目录；
- 合法/非法 ZIP、路径穿越、符号链接、未知 loader、格式版本、缺失哈希、非 CDN 下载地址。

## 4. 兼容性与范围

- 本阶段只支持 Vanilla/Fabric；Forge、NeoForge、Quilt、CurseForge 明确拒绝。
- 外部文件仅允许 Modrinth CDN；不实现任意第三方 URL 跳过校验。
- `overrides`/`client-overrides` 是整合包自身内容，按 ZIP 安全规则提取；外部文件逐个哈希校验，归档本身记录 SHA-256。
- 真实 GUI 启动仍需 Microsoft 账户；本次真实游戏启动使用 CLI local-offline 技术身份，Microsoft 认证/Keychain 未改动。
- 未修改系统 JDK；Java 记录写入实例 `javaRuntime`（本次为 system Microsoft 17）。

## 5. 清理

验证后删除 `.dev-sandbox` 中的 Minecraft、Fabric、Java、整合包缓存、实例和测试账户，以及 `/tmp` 临时下载；保留 `docs/evidence/M6.3` 的截图和脱敏日志。
