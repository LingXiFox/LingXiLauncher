# M8.2 Modpack Lifecycle & Data Safety — 验证记录

## 状态

M8.2 的资源包事务、真实 `.mrpack` 内部差异、更新事务、GUI/CLI 和自动化测试已经实现，并完成真实 Modrinth 整合包更新与启动验证。

## 自动化测试

```text
swift test --parallel --num-workers 4
Executed 327 tests, with 0 failures (0 unexpected)
```

Debug `LauncherCore`、CLI、SwiftUI GUI 均构建通过。

## 已完成

### 实例复制

- 复制 `<instance>/resourcepacks.json`，同时保留 `mods.json`、`shaderpacks.json`、`modpack.json`。
- 不复制全局 libraries/assets；失败只清理新实例。

### 资源包生命周期

- 删除为可回滚事务，并同步清理受支持版本的 `options.txt` 启用项。
- 更新支持跨文件名：下载并校验新 ZIP 后，删除旧 ZIP、迁移启用状态、写元数据；失败恢复 ZIP、`options.txt` 和元数据。
- 同一实例使用 `flock` 串行化资源包写操作。
- 未管理文件/其他项目文件不会被覆盖。

### 整合包身份与更新

- `ModpackRecord` 区分 `.mrpack` 内部 `packVersionID` 与 Modrinth `modrinthProjectID`/`modrinthVersionID`；旧记录不猜测 Modrinth 版本。
- `ModpackUpdateManager` 执行：目标版本查询 → `.mrpack` 下载/大小/SHA-512 或 SHA-1 校验 → `MrpackParser` 解析 → 内部文件/overrides 差异 → 下载/校验目标文件 → 事务备份 → 应用 → 记录写入 → 完整性验证 → 清理事务。
- 用户修改与未知文件默认保留；冲突可显式替换/跳过。
- 进程中断留下 `state.json`，`recover` 可恢复；成功/失败后清理事务目录。
- CLI：`modpack info|update check|preview|apply|recover`。
- GUI：实例行“更新整合包”打开差异预览，支持保留/替换/跳过、确认应用和恢复未完成事务。

## 真实验证

- 在独立 `.dev-sandbox` 安装 Fabulously Optimized 5.4.0（Fabric 1.20.1，78 个文件，48 个 Modrinth 来源）。
- 目标 5.3.3 预览 26 项变化，实际应用：18 个文件更新、8 个移除。
- 更新后 `modpack.json` 记录 `packVersionID=5.3.3`、`modrinthVersionID=yP9fYMLA`，事务目录已清理。
- 使用 Microsoft Java 17 启动更新后的实例，成功到标题界面：Fabulously Optimized 5.3.3，45 个模组。
- 截图：[游戏标题](evidence/m82-real-update-title.png)、[GUI 更新预览/Loader 阻止](evidence/m82-gui-update-loader-block.png)。
- 5.4.1 需要 Fabric Loader 0.14.22 → 0.14.23；当前更新事务拒绝自动切换运行环境，并显示“请先创建兼容实例”，这是有意的安全边界。

## 未完成/未验证

- Loader 版本切换型整合包更新（当前要求新建实例）。
- 真实资源包进入游戏后的视觉验证。
- 更新中途进程崩溃的真实恢复演练；当前由合成事务状态测试覆盖。
- 实例复制后的真实启动验证。

## 风险

- 真实交叉验证使用的是 5.4.0 → 5.3.3 显式目标更新；推荐更新到 5.4.1 会因 Loader 变更被安全阻止。
- 更新事务依赖实例目录可写和足够磁盘；预检按目标下载量估算两倍空间。
- 只支持同一实例的 Loader/Minecraft 版本内更新；需要切换运行时拒绝并要求新实例。

## 构建

```text
swift build
swift test
swift build -c release --product lingxi
swift build -c release --product LingXiMac
Scripts/build-app.sh --release
```

## CI

- 运行：[CI #41006645747](https://github.com/LingXiFox/LingXiLauncher/actions/runs/41006645747)，commit `cb3ed4f`，`xcode-27` Apple Silicon Runner — **success**。
- Debug 构建、完整测试、Release CLI/GUI、App Bundle、签名检查和 Artifact 上传均通过。
- 测试：327，0 failures，0 unexpected。
- Artifact：`LingXiMac-ci-cb3ed4fb484d4a434e2e21554795c3ea6714d541`（4,590,851 bytes，CI-only/ad-hoc，非正式发行）。
