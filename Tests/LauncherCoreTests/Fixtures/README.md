# Test fixtures

`versions/26.3.json`, `versions/1.20.1.json`, `versions/1.16.5.json` are **unmodified public
Mojang metadata**, downloaded on 2026-10-24 from `piston-meta.mojang.com` (URLs listed in
`version_manifest_v2.json`). They are re-serialised with sorted keys and 1-space indentation so
diffs stay readable; no field was added, removed or changed.

Why these three:

| Fixture | Format characteristic it covers |
|---|---|
| `26.3.json` | Newest format: no native classifiers, natives shipped as ordinary libraries, `default-user-jvm`, `os.versionRange`, `--clientId` / `--xuid` game args |
| `1.20.1.json` | Modern `arguments` format with `natives-macos` / `natives-macos-arm64` libraries on the classpath |
| `1.16.5.json` | Legacy format: `natives.osx` + `downloads.classifiers` + `extract.exclude` |

`manifest/version_manifest_trimmed.json` is a hand-trimmed manifest (3 entries) that keeps the
real structure of `version_manifest_v2.json`; `invalid/` holds deliberately broken documents
used to assert explicit error reporting.

`zip/` holds small synthetic archives used by the native-extraction and Mach-O tests: a normal
JAR, a stored (uncompressed) archive, traversal/absolute/symlink attack cases, a corrupt file,
and arm64/x86_64/fat Mach-O payloads. None of them contains real Mojang binaries.

These files are test input only. Nothing here may be shipped inside the launcher, and no game
JAR, asset or library is redistributed in this repository.
