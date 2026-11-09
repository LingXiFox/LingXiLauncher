# Apps

- `desktop/` — Tauri 2 + React + TypeScript 桌面端，命令层在 `desktop/src-tauri/`，界面在 `desktop/src/`。
- 桌面端与 `crates/launcher-cli` 共用 `launcher-core`，不重复实现安装、启动、账户或内容管理逻辑。

开发与构建命令见根目录 `README.md` 与 `docs/DEVELOPMENT.md`。
