# M7.1 图形与光影验证记录

验证日期：2026-10-29
环境：macOS 27.2、Apple M5（arm64）、Xcode 27.2、Swift 6.4.2
测试基线：**283 tests, 0 failures, 0 skipped**
Release：CLI + SwiftUI GUI 构建成功；`dist/LingXiMac.app` 为 arm64、Info.plist 合法、ad-hoc 签名通过

## 1. 范围

本阶段只做 Fabric 1.20.1 的 Iris + Sodium 与独立光影包管理：

- 安装兼容的 Iris + Sodium，优先使用 Iris 元数据中固定的 Sodium 版本；没有固定依赖时安装当前 Minecraft 版本的最新兼容 Sodium。
- Modrinth 光影搜索、排序、分页、详情和版本选择；项目类型固定为 `shader`，按实例 Minecraft 版本过滤。
- 下载 ZIP 后校验 Modrinth SHA-512（优先）或 SHA-1，并验证文件大小；通过后才原子提交到实例 `shaderpacks/`。
- 本地 ZIP 导入、启用/停用、删除、替换和更新检测。
- 只改 Iris 的 `config/iris.properties` 中 `shaderPack` 和 `enableShaders`，保留注释、未知键和其他配置。
- macOS OpenGL 4.1 的能力提示与性能警告；不声称支持 Metal 原生渲染或硬件光追。`GraphicsCapabilities` 对无法创建 OpenGL 上下文的路径也做显式提示，不伪造能力。

没有新增 Forge/NeoForge/Quilt、CurseForge 或新的 Mod Loader。

## 2. 自动化验证

完整测试：

```text
Executed 283 tests, with 0 failures (0 unexpected) in 9.568 seconds
```

新增 `Tests/LauncherCoreTests/M7GraphicsTests.swift`，8 项：

```text
testGraphicsSetupInstallsPinnedIrisAndSodiumWithShaderFacets
testExistingGraphicsPairRequiresExplicitReplacement
testShaderInstallActivationPreservesConfigAndVerifiesZip
testShaderInstallHashFailureLeavesWorldsConfigsAndRecordsUntouched
testNonFabricInstanceIsRejectedBeforeNetworkOrFileWrite
testActivationIsBlockedWhileGameRunsAndDeactivationIsSafe
testUnsupportedMacOpenGLPathWarnsWithoutClaimingMetalRayTracing
testMalformedLocalShaderIsRejectedWithoutMetadataOrFileCommit
```

覆盖点：

- Iris 版本元数据固定 Sodium 依赖时，安装精确匹配的 Sodium；无固定依赖时走最新兼容版本。
- 已有 Iris/Sodium 时不静默覆盖，必须显式替换。
- 光影 ZIP 哈希失败时，不写元数据、不留下半成品，也不碰存档和配置。
- 非 Fabric 实例在联网或写文件前拒绝。
- 游戏进程运行时拒绝修改 Iris 配置；“关闭光影”是幂等安全操作。
- 畸形本地 ZIP 不提交。
- `iris.properties` 中已有注释、未知键和 `enableShaders` 状态在启用/停用后保留。

## 3. 真实 Fabric 1.20.1 验证

测试实例：`shader-real`（独立游戏目录，未触碰已有实例）。

| 项目 | 值 |
|---|---|
| Minecraft | 1.20.1 |
| Fabric Loader | 0.20.1 |
| Iris | 1.7.6+1.20.1（version `s5eFLITc`） |
| Sodium | mc1.20.1-0.5.12-beta.2-fabric（version `ryOMVRuG`） |
| 光影 | Complementary Shaders - Reimagined `r5.9.3`（version `Bqen1mJX`） |
| 光影文件 | `ComplementaryReimagined_r5.9.3.zip` |
| 大小/SHA-1/SHA-512 | 553,397 B / `838139b54cddb56b2e83cd260d8efd960ac536d6` / `45304b…d37d85` |

启动日志（完整摘录见 [evidence/M7.1/iris-runtime.log](evidence/M7.1/iris-runtime.log)）：

```text
OpenGL Vendor: Apple
OpenGL Renderer: Apple M5
OpenGL Version: 4.1 Metal - 91.7
Using shaderpack: ComplementaryReimagined_r5.9.3.zip
GPU: Apple M5 (Supports OpenGL 4.1 Metal - 91.7)
Creating pipeline for dimension minecraft:overworld
```

实际路径：

```text
<data-root>/instances/shader-real/shaderpacks.json
<data-root>/.minecraft/versions/shader-real/shaderpacks/ComplementaryReimagined_r5.9.3.zip
<data-root>/.minecraft/versions/shader-real/config/iris.properties
```

`iris.properties` 最终包含：

```properties
shaderPack=ComplementaryReimagined_r5.9.3.zip
enableShaders=true
```

`shaderpacks.json` 保存 `projectID=HVnmMxH1`、`versionID=Bqen1mJX`、`source=modrinth`、SHA-1/SHA-512、文件大小和许可证。

### 运行时警告（未崩溃）

Iris 1.7.6 加载 Complementary r5.9.3 时记录了未识别 custom uniform 警告，例如：

```text
Failed to resolve uniform inPaleGarden, reason: Unknown variable: BIOME_PALE_GARDEN
```

这不是启动器校验失败；Iris 仍创建 overworld pipeline，游戏进入世界并正常渲染，没有崩溃。不同光影包可能使用较新 Iris 才支持的 uniform，因此“配置已启用”不等于“所有光影包零警告”。验证截图见下。

## 4. GUI 验证

图形与光影弹窗包含三个页签：

- **已安装光影**：显示来源、版本、许可证、启用状态；支持启用/关闭、删除、本地 ZIP 导入、打开目录和检查更新。
- **浏览 Modrinth**：关键词搜索、下载量/相关性/最新发布/最近更新排序、分页、详情、版本选择和安装；只显示 `project_type:shader` 且声明支持实例 Minecraft 版本的版本。
- **Iris + Sodium**：安装/替换图形环境，显示当前版本、目标版本和 OpenGL 能力提示。

截图：

- [已安装光影与 macOS OpenGL 提示](evidence/M7.1/graphics-installed.jpg)
- [Modrinth 光影浏览](evidence/M7.1/shader-browse.jpg)
- [真实游戏世界（Iris 已加载）](evidence/M7.1/game-shader-world.jpg)

GUI 的安装、启用、删除和更新按钮均调用 Core；GUI 不构造 Modrinth URL，也不直接下载文件。调试自动化动作与按钮共用同一个 store 方法。

## 5. CLI 验证

```text
lingxi graphics status --instance shader-real
lingxi shader list --instance shader-real
lingxi shader enable --instance shader-real --file ComplementaryReimagined_r5.9.3.zip
lingxi shader disable --instance shader-real
```

`graphics status` 正确解析 Fabric 1.20.1 实例并显示：

```text
iris     1.7.6+1.20.1 (enabled)
sodium   mc1.20.1-0.5.12-beta.2-fabric (enabled)
warning: Iris 1.7.6+1.20.1 的元数据固定依赖 Sodium mc1.20.1-0.5.12-beta.2-fabric。
```

`shader list` 显示当前启用的 Complementary r5.9.3；`shader disable` 后 `enableShaders=false` 且保留其他键，`shader enable` 后恢复。

## 6. 数据安全

- 光影文件只写实例隔离目录的 `shaderpacks/`，元数据写 `<data-root>/instances/<id>/shaderpacks.json`；不写 `mods/`。
- ZIP 只允许普通文件、禁止路径穿越、绝对路径、反斜杠、符号链接、加密条目和异常压缩比；限制单文件/总解压大小。
- 安装先写同实例的 `.shaderpacks-stage-<UUID>/`，校验后经 `ShaderPackRepository.commit` 提交；替换时先备份旧文件，失败回滚。
- 哈希失败、游戏运行中修改、非 Fabric、畸形 ZIP 都有回归测试；测试确认未改动 worlds、config 或已有记录。
- 启用/停用只改 `config/iris.properties`，采用临时文件 + 原子替换；不改世界、选项或其他 mod 配置。

## 7. Release 与 CI

本地结果：

```text
swift build                                      # success
swift test                                       # 283 tests, 0 failures
swift build -c release --product lingxi          # success
swift build -c release --product LingXiMac       # success
Scripts/build-app.sh --release                   # success
plutil -lint dist/LingXiMac.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 dist/LingXiMac.app
```

App Bundle：

```text
Identifier=com.lingxifox.LingXiLauncher
Format=app bundle with Mach-O thin (arm64)
Signature=adhoc
```

CI 工作流：`.github/workflows/ci.yml`，使用 GitHub 官方 `xcode-27` Apple Silicon Runner；push main、PR、workflow_dispatch；仅 `contents: read`；30 分钟超时；Debug build、完整 XCTest、Release CLI/GUI、`Scripts/build-app.sh`、Info.plist/arm64/ad-hoc 签名校验、ZIP Artifact 上传。CI 不执行 Microsoft 登录、真实 Minecraft 下载或图形桌面启动，Artifact 不是公证发行版。

## 8. GitHub Actions 实跑结果

- 运行：[CI #40859865613](https://github.com/LingXiFox/LingXiLauncher/actions/runs/40859865613)（commit `c9f46ae`，`xcode-27` Apple Silicon Runner）— **success**，耗时约 3 分 34 秒。
- Debug build、完整 **283 tests / 0 failures / 0 unexpected**、Release CLI/GUI、`Scripts/build-app.sh`、Info.plist/arm64/ad-hoc 签名校验全部通过。
- Artifact：`LingXiMac-ci-c9f46aeee2535cbd695543c38c25102a98e19a31`，约 **3.70 MB**，保留 7 天；仅用于测试，不是公证发行版。
- 首次 M7.1 CI 运行 [#40859308536](https://github.com/LingXiFox/LingXiLauncher/actions/runs/40859308536)（commit `138bffa`）也通过，覆盖最初的 282 项测试。
- CI 未执行 Microsoft 登录、真实 Minecraft 下载或图形桌面游戏启动；真实游戏验证是本地独立步骤。

## 9. 边界与后续

- 真实游戏验证使用本地技术身份 + CLI 启动；GUI 的真实启动按钮仍要求已登录账号，本阶段没有重新执行 Microsoft 登录流程。
- macOS 只有 OpenGL 4.1（Metal 转译），复杂光影在 Apple Silicon 上可能掉帧；启动器只提示，不承诺帧率，也不宣传“RTX”。
- Complementary r5.9.3 在 Iris 1.7.6 下有未知 custom uniform 警告；未做所有光影包兼容性矩阵。
- 未测试 Intel Mac；`.app` 为 ad-hoc 签名，不是 Developer ID 签名或公证发行版。
- Modrinth、Iris、Sodium 和光影包的许可证/署名仍由各自项目提供；启动器不重新分发这些文件。
