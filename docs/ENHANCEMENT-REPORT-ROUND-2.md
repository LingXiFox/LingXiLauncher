# LingXi Launcher · 第二轮功能增强交付报告

| 项 | 值 |
| --- | --- |
| 分支 | `rewrite/rust` |
| 本轮提交范围 | `9166982` … `370b85f`（17 个提交，父提交 `99b2b8f`） |
| 代码变更 | 60 个文件，+6,140 / −833 行 |
| 状态日期 | 2026-11-18 |
| 验证环境 | macOS Apple Silicon（本机）· Rust stable · Node 22 · pnpm 9 · Vite 5.4.21 |
| CI | GitHub Actions run #87，5 个 job 全部 success |

本报告只记录实际执行过的验证。没有执行过的项目在第 8 节明确列出，不以“编译通过”代替“功能验证”。

## 1. 交付概览

| 检查项 | 结果 |
| --- | --- |
| `cargo test --workspace` | 92 passed / 0 failed / 1 ignored |
| `cargo fmt --all -- --check` | 通过 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 通过（CI 执行） |
| `pnpm typecheck` | 通过 |
| `pnpm build` | 81 modules；CSS 88.30 kB、JS 310.97 kB（gzip 95.09 kB） |
| GUI 冒烟 `pnpm test:gui` | 通过，覆盖引导、导航、实例详情、安装/模组/图形弹窗、设置三栏、更新检查、内存校验、账户、首页日志预览 |
| CI `Desktop build` | macOS ARM64、Windows x64、Linux x64 三平台 `cargo build --release -p lingxi-desktop` 全部通过 |
| CI `CLI smoke test` | `java list` / `account list` / `instance list` / `doctor --json` 通过 |

## 2. 18 项需求对照

| # | 需求 | 状态 | 落点 |
| --- | --- | --- | --- |
| 1 | 下载引擎：多线程分段、断点续传、去重缓存 | 完成 | `crates/launcher-core/src/install/downloader/`（`mod.rs`、`source.rs`、`cache.rs`） |
| 2 | 取消安装不残留、不误报失败 | 完成 | `install/downloader`、`commands/versions.rs`（`cancel_install`）、`InstallTaskGuard` |
| 3 | 真实下载进度与速度，取消可感知 | 完成 | `services/progress.ts`、`commands/versions.rs`、`DownloadsPage.tsx` |
| 4 | GitHub Release 自动更新 | 部分完成 | `commands/update.rs`（`check_update`）+ 设置页「关于 → 更新」；只做检查与跳转，不做静默安装 |
| 5 | 运行日志从主导航移出，改为独立窗口 | 完成 | `commands/window.rs`、`src/lib/window.ts`、`App.tsx`（`LogWindow`）、设置项 `logWindowOnStart` |
| 6 | 版本完全隔离 | 达成（用户数据层） | `layout.rs::instance_game_directory` → `data_root/.minecraft/versions/<instance-id>`；详见第 7 节 |
| 7 | 自动内存分配 | 完成 | `InstanceMemory::automatic_mib`、`launch.rs`（`-Xms` = `-Xmx`/2，下限 256 MiB） |
| 8 | 窗口模式与尺寸 | 完成 | `InstanceLaunchSettings`（`windowMode`/`windowWidth`/`windowHeight`）、`launch.rs::launcher_game_arguments` |
| 9 | 进程优先级 | 完成 | `ProcessPriority`、`launch.rs::apply_process_priority`（Windows 走 `PriorityClass`，其它平台 `renice`） |
| 10 | 实例环境变量 | 完成 | `InstanceLaunchSettings.environment`，注入 `LINGXI_INSTANCE_ID` / `LINGXI_INSTANCE_DIR` 之后覆盖 |
| 11 | 前置命令、包装命令、收尾命令 | 完成 | `LaunchHooks`、`launch.rs::run_hook` / `launch_command` / `split_command` |
| 12 | 图形后端与 Vulkan 校验层 | 完成 | `GraphicsApi`、`supports_graphics_backend`（26.2+ 才传 `--graphicsBackend`）、`--vulkanValidation` |
| 13 | 启动前文件校验与启动器可见性 | 完成 | `verify_installation` + `verify_before_launch`；`LauncherVisibility`（保持/最小化/隐藏/退出） |
| 14 | 设置分栏 | 完成 | `SettingsPage.tsx` 三栏：游戏 / 启动器 / 关于 |
| 15 | 通用、外观、下载 | 完成 | 语言、强调色（6 色）、背景图、代理三态、四类下载源 |
| 16 | 关于页 | 完成 | `SettingsPage.tsx` 关于栏：版本、平台、目录、项目主页、全部版本、重启、更新卡片 |
| 17 | 自定义 .minecraft 位置 | 完成 | `Settings.game_root` + `Settings::resolved_game_root`，保存后提示重启生效 |
| 18 | 首次启动引导 | 完成 | `components/Onboarding.tsx` 五步：欢迎 / Java / 游戏目录 / 离线账户 / 完成 |

## 3. 下载引擎

默认参数（`crates/launcher-core/src/install/models.rs:176`）：

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `concurrency` | 8 | 并发文件数；启用自适应时是初始窗口 |
| `global_concurrency` | 24 | 文件 × 分段的总并发上限 |
| `per_host_concurrency` | 8 | 单主机上限，避免慢镜像拖垮整个队列 |
| `segments` | 4 | 单文件最大分段数 |
| `segment_threshold_bytes` | 4 MiB | 达到该大小才分段（下限 1 MiB） |
| `adaptive_concurrency` | true | 按失败率放大/收缩窗口 |
| `max_retries` / `retry_delay_ms` | 3 / 500 | 单文件重试 |
| `cache_directory` | 由安装器注入 | 内容寻址缓存，跨实例复用 |

行为要点：

- 服务器不支持 `Range`（返回 200）时自动退回单流，不重试分段。
- 分段文件落在 `<目标>.part.N`，中断后按已有字节续传，不会从头重下。
- 合并完成后删除分段文件；`partial_and_segment_paths_are_predictable` 等测试覆盖路径规则。
- 缓存按 SHA-1 内容寻址，第二个目标命中缓存时零网络请求。

### 吞吐基准

`crates/launcher-core/tests/downloader_bench.rs`，loopback HTTP 服务，48 MiB 单文件 + 50 个 64 KiB 小文件：

| 场景 | debug | release |
| --- | --- | --- |
| 单文件单流 | 31.9 MiB/s | 95.6 MiB/s |
| 单文件八段 | 32.0 MiB/s | 95.7 MiB/s |
| 50 小文件顺序 | 6.2 MiB/s（100 files/s） | 6.2 MiB/s（100 files/s） |
| 50 小文件并发 | 6.2 MiB/s（99 files/s） | 6.2 MiB/s（99 files/s） |

**局限必须写清**：服务端在同一台机器上，瓶颈是引擎自身的哈希/合并/落盘，不是网络 RTT。这组数字证明分段与并发不会拖慢吞吐（八段 ≈ 单流），不能证明公网环境下快多少倍。真实收益来自断点续传（不重下已完成的字节）与缓存命中（不重复下载共享库），这两点在集成测试 `downloader_segmented.rs` / `downloader_progress.rs` 里有断言，但没有做公网对照测量。

## 4. 网络与代理

- `crates/launcher-core/src/net.rs` 新增全局代理槽：`ProxyMode::{System, Manual, Off}` + `ProxySettings`。
- `net::client_builder()` 是唯一入口：`System` 直接返回 `reqwest::ClientBuilder`（reqwest 0.12 默认读取 `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`/`NO_PROXY`），`Off` 调 `.no_proxy()`，`Manual` 用 `reqwest::Proxy::all(url)`。
- 9 处 `reqwest::Client::builder()` 全部改为走该入口：`install/vanilla.rs`、`install/downloader/mod.rs`（客户端 + 探测客户端）、`install/loader.rs`、`manifest.rs`、`java.rs`、`modrinth.rs`、`launcher-auth/src/oauth.rs`、`launcher-auth/src/xbox.rs`。
- 保存设置时校验手动代理必须以 `http://` / `https://` / `socks5://` 开头，否则拒绝；启动时 `apply_saved_proxy` 先装载代理，再构造其它服务。

## 5. 日志

- 主导航与 `Section` 类型移除 `logs`，`TopBar`/`Sidebar` 同步删除。
- `commands/window.rs::open_log_window` 打开 label 为 `logs` 的独立 WebviewWindow；已存在则聚焦。
- 前端不新增构建入口：`src/lib/window.ts::isLogWindow()` 读 `__TAURI_INTERNALS__.metadata.currentWindow.label`，`App.tsx` 分流到 `LogWindow`（只渲染 `LogsPage`，无侧栏/顶栏）。
- `capabilities/default.json` 的 `windows` 加入 `logs`。
- 设置项 `logWindowOnStart` 在启动就绪后自动开窗（`useLogWindowOnStart`）。
- `read_logs` 只读文件尾部（上限 4 MiB），并新增 `perf(logs): read only the log tail` 的尾读实现。

## 6. 设置与外观

- 三栏：游戏（默认内存、Minecraft 目录、Java 运行时）、启动器（语言、下载源、日志窗口开关、外观、下载与代理）、关于（版本、更新、链接）。
- 强调色 6 种（暖橙 / 天青 / 苔绿 / 紫藤 / 绯樱 / 丹砂），实现方式是 `:root[data-accent="…"]` 覆盖 4 个 CSS 变量（`--accent`、`--accent-strong`、`--on-accent`、`--accent-soft`），深浅色各一套。
- 背景图为本地文件，读取后转 data URL 写入 CSS 变量，避免启用 `asset` 协议的额外配置面；`[data-background="custom"]` 才启用遮罩层。
- 保存后由后端返回归一化后的完整设置回填 UI，避免“前端以为存了、后端其实改了值”。

## 7. 版本隔离的实际边界

每个实例的游戏目录是 `data_root/.minecraft/versions/<instance-id>`（`layout.rs::instance_game_directory`），启动时 `--gameDir` 与进程工作目录都指向它（`launch.rs` 的 `game_directory` / `working_directory`）。因此下列内容**天然按实例隔离**：`mods`、`config`、`saves`、`logs`、`resourcepacks`、`shaderpacks`、`options.txt`、`screenshots`、`crash-reports`。

仍然共享的是**版本产物**：`game_root/versions/<version-id>`、`libraries`、`assets`、`natives`。这些是安装生成、不可变的下载结果，与官方启动器、HMCL、PCL2 的默认行为一致；若强行按实例复制，会让每个实例多占数百 MB 到 1 GB，并破坏 `install-state.json` 的完整性校验模型。本轮没有做这件事，属于有意的范围边界。

## 8. 未完成与已知限制

| 项 | 说明 |
| --- | --- |
| 自动安装更新 | 只实现「检查最新 Release + 打开下载页面」。静默下载替换需要 `tauri-plugin-updater` 及签名密钥配置；按“新增依赖先请示”的约定没有引入。 |
| 语言设置 | `language` 字段已落盘并可切换，但界面文案仍是中文硬编码，没有接入 i18n 词典。切换 `en-US` 不会改变任何可见文本。 |
| Windows / Linux 真机 | CI 只做 `cargo build --release`，没有在 Windows 或 Linux 上安装并运行安装包。macOS `.app`/`.dmg` 也未在本轮重新做 Gatekeeper 验证。 |
| 下载性能 | 见第 3 节：loopback 基准，无公网对照。 |
| 版本产物共享 | 见第 7 节，有意保留。 |
| Windows 交叉编译 | 本机 macOS 无法交叉编译依赖 `ring` 的 C 代码（缺 MSVC 头文件），只能依赖 CI 的 `windows-2025` runner。 |

## 9. 提交清单

| 提交 | 说明 |
| --- | --- |
| `9166982` | fix(platform): open Windows URLs without a shell |
| `765581f` | fix(instances): keep worlds when an instance is deleted |
| `0b89099` | feat(desktop): track installs as cancellable tasks with real progress |
| `5fdc6dc` | perf(logs): read only the log tail instead of the whole file |
| `085cfe9` | fix(desktop): release install task slots on every exit path |
| `ee2916a` | test(install): cover the download pipeline against a local HTTP server |
| `d2fe298` | Log every cancellation request against in-flight install tasks |
| `3df4d99` | feat(download): range-segmented, resumable transfers with adaptive concurrency and a shared object cache |
| `7ddf8f8` | fix(desktop): treat cancellation as a normal outcome and drop the stale progress card |
| `81744cf` | feat(launch): per-instance window, priority, hook and GPU options |
| `b7b88bd` | feat(settings): global language, accent, proxy and game-root settings |
| `16b77e5` | feat(desktop): tabbed settings, detached log window and update check |
| `a197fca` | test(gui): exercise onboarding, settings tabs and detached log entry in smoke run |
| `b33dae5` | style: apply rustfmt and replace hand-written Default impls with derives |
| `5b06459` | fix(settings): make the custom background image actually render |
| `5cc51a8` | style: apply rustfmt to the background image command |
| `370b85f` | ci: move runners to the newest generally available images |

## 10. 复现命令

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo test -p launcher-core --test downloader_bench -- --ignored --nocapture
cargo test --release -p launcher-core --test downloader_bench -- --ignored --nocapture
pnpm -C Apps/desktop typecheck
pnpm -C Apps/desktop build
pnpm -C Apps/desktop test:gui
```
