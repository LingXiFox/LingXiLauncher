# Apps/

`LingXiMac` — native SwiftUI GUI for macOS 14+ / Apple Silicon (M5-Alpha).

- Package target: `LingXiMac` (path `Apps/LingXiMac/Sources`), depends directly on `LauncherCore`.
- It never shells out to the `lingxi` CLI; launch/download/auth all go through Core APIs.
- Build the double-clickable bundle with `Scripts/build-app.sh` → `dist/LingXiMac.app`.
- `Info.plist` lives here; the bundle is ad-hoc signed for local development only.

See `README.md` and `docs/VERIFICATION-M3-M5.md` at the repository root.
