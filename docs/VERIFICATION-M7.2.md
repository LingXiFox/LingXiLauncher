# M7.2 Verification — NeoForge & Graphics Stability

状态：**本地验证完成，等待提交后的 GitHub Actions 结果**。本阶段没有新增 Forge/Quilt/CurseForge，也没有修改 Microsoft 认证、Keychain 或正式发行签名。

## 1. 范围

- **M7.1.1 图形稳定性**：Iris + Sodium 成对事务、游戏运行时光影写保护、光影 ZIP 替换/更新回滚、GUI 更新动作收敛。
- **M7.2 NeoForge**：官方 Maven 版本查询、隔离 staging 中运行官方 installer、profile/library/patched client 校验与事务提交、Modrinth 模组、`.mrpack` `neoforge` 依赖、安装向导/CLI/GUI。
- macOS 图形仍由 OpenGL 4.1（Metal 转译）提供；不宣称 Metal 原生生渲染、硬件光追或 RTX。

## 2. 自动化验证

```text
swift build
swift test
Executed 290 tests, with 0 failures (0 unexpected)
```

新增/更新的回归测试覆盖：

- Iris + Sodium 升级时 Sodium 已被替换、Iris 下载失败 → 恢复两个旧模组和旧文件，不残留 snapshot。
- 光影 ZIP 暂存提交失败 → 恢复旧 ZIP 和 `shaderpacks.json`。
- 游戏运行时拒绝启用/停用光影；CLI/GUI 共享 `InstanceRuntimeRegistry`。
- NeoForge Maven metadata 解析、Minecraft 版本严格映射、兼容版本过滤。
- 已有实例未显式 `--update` 时在联网前拒绝。
- NeoForge profile 识别为 `.neoforge`，供 Modrinth/图形过滤。
- `.mrpack` `neoforge` 依赖解析为新实例安装类型。
- 本地 ZIP 路径/hash/大小校验、可选客户端文件不隐式安装。

## 3. 真实 NeoForge 安装与启动

环境：macOS Apple Silicon，Microsoft OpenJDK 21；Minecraft **1.21.1**，NeoForge **21.1.265**。

```bash
.build/debug/lingxi install neoforge \
  --version 1.21.1 --instance nf-real --name 'NeoForge 1.21.1' \
  --loader 21.1.265 --root .dev-sandbox/mc --data-root .dev-sandbox/data \
  --java /Library/Java/JavaVirtualMachines/microsoft-21.jdk/Contents/Home/bin/java
```

结果：

- 官方 installer 在隔离 staging root 运行，vanilla 1.21.1 的 3888 个缓存文件校验通过；NeoForge 生成 profile、libraries 和 patched client JAR。
- launcher 将 `neoforge-21.1.265-client.jar` 提升为 profile 的 client jar，避免 vanilla client + NeoForge patched client 同时作为 module 导致 `ResolutionException`。
- profile `/versions/neoforge-21.1.265/neoforge-21.1.265.json` 的 parent 为 `1.21.1`，main class 为 `cpw.mods.bootstraplauncher.BootstrapLauncher`。
- 离线技术身份启动进入标题界面：`Minecraft 1.21.1 / NeoForge 21.1.265 (2 mods)`。截图：[neoforge-title.png](evidence/m7.2-neoforge-title.png)。

Modrinth 真实安装：

```bash
.build/debug/lingxi mod search --instance nf-real --query jei ... --json
.build/debug/lingxi mod install --instance nf-real --project jei ...
```

成功安装 **JEI 19.70.0.464** 及依赖 **MezzConfig 0.6.9**；再次启动进入标题界面，显示 `NeoForge 21.1.265 (4 mods)`，日志确认 JEI 被 NeoForge 加载。截图：[neoforge-jei.png](evidence/m7.2-neoforge-jei.png)。

## 4. NeoForge `.mrpack`

使用仅含 `modrinth.index.json` 的合成 NeoForge pack 做端到端安装：

```text
instance       neoforge-fixture-841cf5ab
minecraft      1.21.1
loader         neoforge-21.1.265
files          0 committed
sources        0 Modrinth · 0 local
```

说明解析器把 `dependencies.neoforge` 转成 `.neoforge(loaderVersion:)`，OneStop/NeoForgeInstaller 完成隔离安装；没有把 pack 的 `mods/` 写进目标实例之外。真实带 mods 的 NeoForge pack 未在本阶段下载大文件。

## 5. GUI

- 安装向导新增 **NeoForge**，版本从官方 Maven 获取，并按当前 Minecraft 版本严格过滤。
- 模组管理在 NeoForge 实例上显示 `1.21.1 · NeoForge`，可搜索并安装 NeoForge 构建；JEI 已安装状态正确显示。
- 图形与光影页允许 Fabric/NeoForge；仍提示 OpenGL 4.1 上限。
- NeoForge 实例的 Modrinth 搜索/安装真实截图：[gui-neoforge-mods.png](evidence/m7.2-gui-neoforge-mods.png)。

## 6. 安全与回滚

- NeoForge installer 有 32 MiB installer 上限、900 秒超时、取消终止、独立 staging root；目标实例不会成为 installer 的 cwd。
- 安装后的 libraries/version 通过文件级事务合并；失败恢复旧文件，成功的 update 才替换 `instance.json`。
- `.mrpack` 仍只接受 HTTPS、官方可信域名和 SHA-512/SHA-1 + size；`env.client=optional` 必须显式选择。
- 图形 pair 使用有界模组目录快照；光影替换同时备份 ZIP 与 JSON 元数据。

## 7. 已知限制

- 真实 NeoForge 验证使用 CLI 离线技术身份；未在 NeoForge 上重新执行 Microsoft 登录流程。
- 未在 NeoForge 上重复完整 Iris/Sodium 世界渲染验证；M7.1 的 Iris 世界验证仍只针对 Fabric 1.20.1。
- 没有执行真实的大型第三方 NeoForge 整合包安装；合成 pack 只验证 loader 依赖和实例事务。
- macOS OpenGL 4.1 的性能限制仍然存在；没有 Metal 原生后端。
- 本文件中的 CI 段落在首次 push 后补充实际 run URL 和 artifact 名称。
