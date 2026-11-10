# RC 发布验收记录：v0.10.0-rc.1

记录对象：LingXi Launcher Rust 重写版首个 RC（tag `v0.10.0-rc.1`）。
验收口径依据 `LXLRC.md`：三平台安装包可下载、安装包带签名状态说明、质量门禁全绿、已知限制如实披露。

## 1. 结论

| 项目 | 结果 |
| --- | --- |
| 版本一致性 | 通过：Cargo workspace / `Apps/desktop/package.json` / `Apps/desktop/src-tauri/tauri.conf.json` 均为 `0.10.0-rc.1`，tag 与之一致 |
| 质量门禁 | 通过：fmt、clippy `-D warnings`、`cargo test` 65 项、前端 typecheck / build、GUI 冒烟 |
| macOS 产物 | 通过：`.app` 11.30 MiB、`.dmg` 6.51 MiB，ad-hoc 签名且资源已封闭，`hdiutil verify` VALID |
| Windows / Linux 产物 | 由 CI 构建，本机不做实机验证（见第 6 节） |
| 发布形态 | GitHub pre-release，7 个安装包 + SHA256 校验文件 |

结论：满足 RC 发布条件。签名状态已在 Release Notes 与 `KNOWN-ISSUES.md` 明示，未冒称 Apple 公证或 Windows 代码签名。

## 2. 版本与标识

- `node scripts/release/version.mjs check v0.10.0-rc.1` 输出 `version: 0.10.0-rc.1`，三处清单一致。
- tag 命名 `v` + 版本号；`release.yml` 的 quality-gate 与 publish 都做该断言，tag 与清单不一致会直接失败。
- Windows 安装包的版本资源由 `scripts/release/version.mjs wix-config` 生成 `0.10.0.0`（Windows 版本资源只接受纯数字），文件名仍带 `0.10.0-rc.1`。
- rpm 打包器拒绝预发布后缀，Linux 先出 AppImage/deb（0.10.0-rc.1），再用 `scripts/release/version.mjs rpm-config` 生成的 `{"version":"0.10.0"}` 覆盖层单独构建 rpm；rpm 元数据是 0.10.0，文件名仍带 `0.10.0-rc.1`。

## 3. 质量门禁（本机实测）

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 格式 | `cargo fmt --all -- --check` | 通过 |
| 静态检查 | `cargo clippy --workspace --all-targets -- -D warnings` | 通过，0 警告 |
| Rust 测试 | `cargo test --workspace` | 65 项通过（launcher-core 59、launcher-auth 6） |
| 前端类型 | `pnpm typecheck` | 通过 |
| 前端构建 | `pnpm build` | 通过：JS 286.77 kB（gzip 87.17 kB）、CSS 80.62 kB（gzip 13.64 kB） |
| GUI 冒烟 | `pnpm test:gui` | 通过：启动、导航、实例详情、模组/光影/安装弹窗、设置校验、账户、日志 |

新增测试覆盖：版本继承与规则合并（12）、Java 版本解析与运行时组件（4）、命令行尾部读取与类路径分隔符（4）。

## 4. 构建产物（macOS 本机）

| 产物 | 路径 | 大小 | 校验 |
| --- | --- | --- | --- |
| 应用包 | `target/release/bundle/macos/LingXi Launcher.app` | 11.30 MiB | `codesign --verify --deep --strict` 通过 |
| 磁盘映像 | `target/release/bundle/dmg/LingXi Launcher_0.10.0-rc.1_aarch64.dmg` | 6.51 MiB | `hdiutil verify` CRC32 VALID |
| 前端资源 | `Apps/desktop/dist` | 376 KB | Vite 生产构建 |

签名实测（`codesign -dv`）：`Identifier=com.lingxifox.LingXiLauncher`、`flags=0x10002(adhoc,runtime)`、`Info.plist entries=15`、`Sealed Resources version=2`。
挂载 DMG 后对内部 `.app` 做同样检查，签名与标识一致。

构建要点：未配置 Developer ID 时会产出只有链接器签名的坏包（`spctl` 报 `code has no resources but signature indicates they must be present`），
因此 `release.yml` 在 macOS 构建步骤设置 `APPLE_SIGNING_IDENTITY: "-"` 让打包器做 ad-hoc 签名，并在打包后校验 `Sealed Resources`。

## 5. 性能实测（macOS 本机，Apple Silicon）

| 指标 | 数值 | 测量方式 |
| --- | --- | --- |
| 冷启动到主窗口 | 0.78 s（首次）/ 0.27 s（随后两次） | `open -a` 到 System Events 报出首个窗口的时间差；首次含 LaunchServices 缓存构建 |
| 主进程常驻内存 | 89.3–89.6 MB | 窗口就绪 20 s 后 `ps -o rss` |
| 含 WebContent 总内存 | 146.7–150.2 MB | 主进程 + 本次启动新出现的 WebKit WebContent 进程 RSS 之和 |
| 空闲 CPU | 0.0 / 0.0 / 0.1 % | 空闲 20 s 后每 5 s 采样一次，三次 |
| 主进程线程数 | 16 | `ps -M` |
| 前端资源 | JS 286.77 kB（gzip 87.17 kB）、CSS 80.62 kB（gzip 13.64 kB） | Vite 生产构建输出 |
| `.app` / `.dmg` | 11.30 MiB / 6.51 MiB | 打包输出 |

测量条件是本机、无其他负载；未与旧 Swift 版做同机对比，因此这些数字只作为 RC 基线，不用于跨版本结论。

启动游戏时的下载吞吐另作记录：官方源在本机约 100 KB/s（24 并发），1.21.11 的 501 MB 资源需要较长时间，属于网络条件而非启动器缺陷；
CLI 支持 `--concurrency` 与 `--mirror-config`，GUI 在设置页可填镜像配置路径。
## 6. 未验证项与风险

| 项 | 状态 | 说明 |
| --- | --- | --- |
| Windows 实机 GUI 与启动 | 未验证 | 只验证构建成功与产物非空，标记「待 RC 测试者验证」 |
| Linux 实机 GUI 与启动 | 未验证 | 同上；AppImage 需 FUSE2 或 `--appimage-extract-and-run` |
| Apple Developer ID 签名与公证 | 未配置 | 仓库无证书，产物为 ad-hoc 签名 |
| Windows Authenticode 签名 | 未配置 | 产物未签名，SmartScreen 会拦截 |
| Microsoft 真实账号登录 | 需真实凭据 | 授权链路代码完整，本轮未用真实账号跑通全流程 |
| macOS 完整进入世界 | 本轮跳过 | 官方源下载 1.21.11 约 501 MB、本机约 100 KB/s，按主人要求停止等待；此前验证已到渲染线程初始化（`Created atlas`） |
| macOS 启动器本体 GUI | 已验证 | 打好的 `.app` 直接启动到主界面；`pnpm test:gui` 覆盖导航、实例详情、模组/光影/安装弹窗、设置校验、账户、日志 |

## 7. 发布流程（`release.yml`）

1. `quality-gate`：版本一致性 → fmt → clippy → test → 前端 typecheck/build。
2. `build`：macOS（macos-15）、Windows（windows-2022）、Linux（ubuntu-22.04）并行打包，`if-no-files-found: error`。
3. `publish`：仅 tag push 且前两个 job 全绿时执行；下载全部产物 → 归一化文件名 → 逐个校验非空与含版本号 → 生成并校验 SHA256 → 拒绝覆盖已存在的 Release → `gh release create --prerelease --verify-tag`。

## 8. 回滚与重发

- 发布前失败：无 Release 产生，修完重新打 tag 即可。
- 发布后发现严重问题：`gh release delete v0.10.0-rc.1 --yes` 并删除远端 tag，修复后重新打 tag；不要把同一个 tag 指向新的提交。
- 本地数据：RC 不修改用户 `minecraft` 目录结构，卸载启动器不会删除世界与存档。
