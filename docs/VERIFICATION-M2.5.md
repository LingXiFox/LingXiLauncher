# M2.5 真机启动验证记录

> 历史记录：本文件记录 M2.5 时的实例目录布局（每实例 `.minecraft`）。M5.1 已改为唯一 `<dataRoot>/.minecraft/versions/<instance-id>`，路径仅作历史证据保留。

日期：2026-10-25 13:06–13:10（Asia/Shanghai）
主机：macOS 27.2 / Apple Silicon arm64
实例：`dev-1201`（Minecraft 1.20.1，`.dev-sandbox` 沙盒）
Java：Microsoft OpenJDK **17.0.20.1 arm64**（`/Library/Java/JavaVirtualMachines/microsoft-17.jdk/Contents/Home/bin/java`）
身份：`local-offline`（`DevPlayer`，未验证所有权；仅本地技术验证）

## 执行的命令

```bash
swift build
swift test                       # 206 tests, 0 failures

lingxi verify --instance dev-1201 --java <JDK17> \
  --root .dev-sandbox/mc --data-root .dev-sandbox/data
# 3636 files / 734.9 MB, all SHA-1 and sizes match

lingxi doctor --version 1.20.1 --java <JDK17> \
  --root .dev-sandbox/mc --data-root .dev-sandbox/data
# platform: osx 27.2.0 jvm=arm64 host=arm64; 0 missing files

lingxi launch --instance dev-1201 --identity local:DevPlayer --java <JDK17> \
  --root .dev-sandbox/mc --data-root .dev-sandbox/data --dry-run
# preview: 10 JVM args, 59 classpath entries, --accessToken <redacted>

lingxi launch --instance dev-1201 --identity local:DevPlayer --java <JDK17> \
  --root .dev-sandbox/mc --data-root .dev-sandbox/data
# exit code 0
```

## 结果

- 游戏真实启动：窗口 `Minecraft 1.20.1`（854×508 @ 832,176），主菜单完整渲染。
  截图（未提交仓库，避免分发 Mojang 美术资源）：
  `.dev-sandbox/evidence/main-menu-1.20.1.png`
- 游戏日志关键阶段（`instances/dev-1201/.minecraft/logs/latest.log`）：

```text
[13:06:52] [Render thread/INFO]: Setting user: DevPlayer
[13:06:52] [Render thread/INFO]: Backend library: LWJGL version 3.3.1 build 7
[13:06:54] [Render thread/INFO]: Reloading ResourceManager: vanilla
[13:06:55] [Render thread/INFO]: OpenAL initialized on device CoreAudio Default
[13:06:55] [Render thread/INFO]: Sound engine started
[13:06:55] [Render thread/INFO]: Created: 1024x512x4 minecraft:textures/atlas/blocks.png-atlas
...
[13:10:36] [Render thread/INFO]: Stopping!
```

- 原生库实际加载架构（`file` 验证 LWJGL 从 natives 缓存解出的动态库）：

```text
.dev-sandbox/data/natives/1.20.1/arm64/liblwjgl.dylib:      Mach-O 64-bit ... arm64
.dev-sandbox/data/natives/1.20.1/arm64/libglfw.dylib:       Mach-O 64-bit ... arm64
.dev-sandbox/data/natives/1.20.1/arm64/libopenal.dylib:     Mach-O 64-bit ... arm64
```

- 正常退出：启动器日志 `Game exited with code 0`，游戏日志 `Stopping!`。

## 日志中的非致命信息（逐项判定）

| 日志 | 判定 |
|---|---|
| `Failed to verify authentication ... InvalidCredentialsException: Status: 401` | **预期**：`LocalOffline` 的 `accessToken=0`，游戏尝试拉取正版 profile 属性失败；不影响本地单人。M3 之前不伪造会话。 |
| `Could not authorize you against Realms server: Failed to parse into SignedJWT: 0` | 同上，离线身份无法访问 Realms。 |
| `Failed sysctl call: hw.cpufrequency, Error code: 2` | Apple Silicon 上 oshi 读取传统 CPU 频率失败，无害。 |
| `Missing sound for event: goat_horn...` | 1.20.1 原版资源本身的缺失音效告警，无害。 |
| `Shader rendertype_entity_translucent_emissive could not find sampler ...` | 原版 shader 告警，无害。 |

**没有** `UnsatisfiedLinkError`、`ClassNotFoundException`、`NoSuchMethodError`、GLFW/OpenGL 初始化错误或崩溃。

## 未覆盖

- 未创建测试世界、未验证世界内玩法：按用户要求止步于主菜单（启动闭环已验证）。
- 未测试 Microsoft 正版认证（M3）、Fabric（M4）、GUI（M5）。
- 未在 x86_64 JVM 上真机运行（本机未安装 x86_64 JDK）；x86_64/Rosetta 路径由单元测试覆盖。
