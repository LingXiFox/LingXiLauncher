# 安装与卸载（v0.10.0-rc.1）

> 本版本是 RC 测试包：**macOS 只做了 ad-hoc 签名，未做 Apple 公证；Windows 未做代码签名。** 首次打开出现系统安全提示属于预期，按下面的步骤放行即可。

## 下载哪个包

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| macOS（Apple Silicon） | `LingXi-Launcher_0.10.0-rc.1_macos-aarch64.dmg` | 推荐；拖入「应用程序」即可 |
| macOS（备用） | `LingXi-Launcher_0.10.0-rc.1_macos-aarch64.app.zip` | 解压后得到 `.app`，适合排查 Gatekeeper 问题 |
| Windows | `LingXi-Launcher_0.10.0-rc.1_windows-x64-setup.exe` | NSIS 安装包，含开始菜单项 |
| Windows（企业部署） | `LingXi-Launcher_0.10.0-rc.1_windows-x64.msi` | MSI 安装包 |
| Linux | `LingXi-Launcher_0.10.0-rc.1_linux-x86_64.AppImage` | 免安装 |
| Linux（Debian / Ubuntu） | `LingXi-Launcher_0.10.0-rc.1_linux-amd64.deb` | `sudo apt install ./文件路径` |
| Linux（Fedora / RHEL） | `LingXi-Launcher_0.10.0-rc.1_linux-x86_64.rpm` | `sudo dnf install ./文件路径` |

每个文件旁边都有同名 `.sha256` 校验值，可用 `sha256sum -c`（Linux）或 `shasum -a 256`（macOS）核对。

## macOS

1. 打开 DMG，把 **LingXi Launcher** 拖进「应用程序」。
2. 第一次打开：在「应用程序」里右键点击图标 →「打开」→ 再次确认「打开」。
   如果系统只提示「已损坏」或无法验证开发者，到「系统设置 → 隐私与安全性」底部点「仍要打开」。
3. 如仍被拦截，可在终端移除隔离属性：

   ```sh
   xattr -dr com.apple.quarantine "/Applications/LingXi Launcher.app"
   ```

4. 启动器需要联网下载游戏文件；首次启动会检测系统 Java，也可以让它自动下载 Mojang 提供的运行时。

## Windows

1. 运行 `setup.exe`（或双击 MSI）。
2. SmartScreen 提示「Windows 已保护你的电脑」时，点「更多信息」→「仍要运行」。
3. 按向导完成安装，启动器会创建开始菜单与桌面快捷方式。

## Linux

AppImage：

```sh
chmod +x LingXi-Launcher_0.10.0-rc.1_linux-x86_64.AppImage
./LingXi-Launcher_0.10.0-rc.1_linux-x86_64.AppImage
```

如果提示缺少 WebKitGTK：

- Debian / Ubuntu：`sudo apt install libwebkit2gtk-4.1-0 libgtk-3-0`
- Fedora：`sudo dnf install webkit2gtk4.1 gtk3`

deb / rpm 直接用系统包管理器安装即可。

## 数据目录

| 平台 | 启动器数据 | 共享的游戏目录 |
| --- | --- | --- |
| macOS | `~/Library/Application Support/LingXiLauncher` | `~/Library/Application Support/minecraft` |
| Windows | `%APPDATA%\LingXiLauncher` | `%APPDATA%\.minecraft` |
| Linux | `${XDG_DATA_HOME:-~/.local/share}/lingxi-launcher` | `~/.minecraft` |

设置页的「打开数据目录」「打开日志目录」可以直接跳转。实例、日志、崩溃报告都在启动器数据目录下，不会写进游戏目录之外的随机位置。

## 从旧版迁移

- **设置**：macOS 上如果不存在 Rust 版的设置文件，会从旧版（Swift）的 `com.lingxifox.LingXiLauncher` UserDefaults 读取一次，然后写入新文件；之后以新文件为准，不会覆盖你后来的修改。
- **正版登录**：旧版把 refresh token 存在钥匙串服务 `com.lingxifox.LingXiLauncher.microsoft` 下，新版在读取不到自己的条目时会回退读取该服务，因此多数情况下不需要重新登录。首次启动后建议确认一下账户页的玩家名。
- **实例与版本文件**：位于同一个数据目录，新版直接复用；不会删除或改写旧版文件。
- 迁移不做不可逆操作：旧设置与旧钥匙串条目都会保留，确认新版可用后再自行清理。

## 卸载

- macOS：把「应用程序」里的 LingXi Launcher 拖到废纸篓；如需清空数据，删除 `~/Library/Application Support/LingXiLauncher`。要清掉登录凭据，打开「钥匙串访问」搜索 `LingXiLauncher` 删除对应条目。
- Windows：设置 → 应用 → LingXi Launcher → 卸载；数据目录 `%APPDATA%\LingXiLauncher` 需手动删除。
- Linux：deb 用 `sudo apt remove lingxi-launcher`，rpm 用 `sudo dnf remove`；AppImage 直接删除文件，数据目录手动删除。

卸载不会删除 `.minecraft` 里的世界与存档，需要时请自行清理。
