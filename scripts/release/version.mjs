#!/usr/bin/env node
// Single source of truth for the release version.
//
// The launcher version lives in three manifests. This script fails the build
// when they drift apart, when a release tag does not match, and it derives the
// numeric WiX version that MSI installers require.
//
// Usage:
//   node scripts/release/version.mjs check [vX.Y.Z-pre]
//   node scripts/release/version.mjs wix-config <output.json>
//   node scripts/release/version.mjs rpm-config <output.json>
//   node scripts/release/version.mjs numeric

import { readFile, writeFile, mkdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

async function readWorkspaceVersion() {
  const manifest = await readFile(path.join(root, "Cargo.toml"), "utf8");
  const section = manifest.split(/^\[workspace\.package\]/m)[1];
  if (!section) throw new Error("Cargo.toml has no [workspace.package] section");
  const match = section.match(/^version\s*=\s*"([^"]+)"/m);
  if (!match) throw new Error("Cargo.toml [workspace.package] has no version");
  return match[1];
}

async function readJsonVersion(relative) {
  const data = JSON.parse(await readFile(path.join(root, relative), "utf8"));
  if (typeof data.version !== "string") throw new Error(`${relative} has no version`);
  return data.version;
}

async function versions() {
  return {
    "Cargo.toml [workspace.package]": await readWorkspaceVersion(),
    "Apps/desktop/package.json": await readJsonVersion("Apps/desktop/package.json"),
    "Apps/desktop/src-tauri/tauri.conf.json": await readJsonVersion(
      "Apps/desktop/src-tauri/tauri.conf.json"
    ),
  };
}

function numericVersion(version) {
  const match = version.match(/^(\d+)\.(\d+)\.(\d+)/);
  if (!match) throw new Error(`not a semantic version: ${version}`);
  return `${match[1]}.${match[2]}.${match[3]}`;
}

async function check(tag) {
  const found = await versions();
  const unique = new Set(Object.values(found));
  const rows = Object.entries(found).map(([file, value]) => `  ${file}: ${value}`);
  if (unique.size !== 1) {
    console.error("Version mismatch between manifests:\n" + rows.join("\n"));
    process.exit(1);
  }
  const version = [...unique][0];
  if (!/^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/.test(version)) {
    console.error(`Version "${version}" is not a semantic version`);
    process.exit(1);
  }
  if (/[+]/.test(version)) {
    console.error("Build metadata is not supported in release versions");
    process.exit(1);
  }
  if (tag) {
    const expected = `v${version}`;
    if (tag !== expected) {
      console.error(`Git tag "${tag}" does not match the manifest version ("${expected}")`);
      process.exit(1);
    }
  }
  console.log(`version: ${version}`);
  for (const row of rows) console.log(row);
}

async function wixConfig(output) {
  const version = await readWorkspaceVersion();
  const numeric = numericVersion(version);
  // Windows Installer requires a purely numeric product version. The prerelease
  // suffix keeps living in the bundle file name, the tag and the release title.
  const config = {
    bundle: { windows: { wix: { version: `${numeric}.0` } } },
  };
  await mkdir(path.dirname(path.resolve(output)), { recursive: true });
  await writeFile(output, JSON.stringify(config, null, 2) + "\n");
  console.log(`wix version: ${numeric}.0 -> ${output}`);
}

async function rpmConfig(output) {
  const numeric = numericVersion(await readWorkspaceVersion());
  // The rpm bundler rejects prerelease suffixes in the package version. The rpm
  // metadata carries the numeric version while the file name keeps the rc tag.
  const config = { version: numeric };
  await mkdir(path.dirname(path.resolve(output)), { recursive: true });
  await writeFile(output, JSON.stringify(config, null, 2) + "\n");
  console.log(`rpm version: ${numeric} -> ${output}`);
}

const [command = "check", argument] = process.argv.slice(2);
switch (command) {
  case "check":
    await check(argument);
    break;
  case "wix-config":
    if (!argument) {
      console.error("wix-config requires an output path");
      process.exit(1);
    }
    await wixConfig(argument);
    break;
  case "rpm-config":
    if (!argument) {
      console.error("rpm-config requires an output path");
      process.exit(1);
    }
    await rpmConfig(argument);
    break;
  case "numeric":
    console.log(numericVersion(await readWorkspaceVersion()));
    break;
  default:
    console.error(`unknown command: ${command}`);
    process.exit(1);
}
