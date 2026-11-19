#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = new URL("../../", import.meta.url);

export function releaseVersion(version) {
  const match = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(beta|rc)\.([1-9]\d*))?$/.exec(version);
  if (match?.[0] !== version) {
    throw new Error(`Expected X.Y.Z, X.Y.Z-beta.N or X.Y.Z-rc.N: ${version}`);
  }
  const [, major, minor, patch, channel = "stable", sequence] = match;
  if (Number(major) > 255 || Number(minor) > 255 || Number(patch) > 255 || Number(sequence) > 127) {
    throw new Error(`Version exceeds MSI limits (255 per core field, 127 builds per channel): ${version}`);
  }
  const core = `${major}.${minor}.${patch}`;
  // MSI compares only three fields. Reserve one byte of the third field for prerelease order.
  const installerBuild = channel === "stable" ? 255 : Number(sequence) + (channel === "rc" ? 127 : 0);
  // Keep normalized packages above historical DEBs and RPMs with the same core version.
  const rpmRelease = channel === "stable" ? "2" : `1.${channel === "beta" ? 1 : 2}.${sequence}`;
  const debSuffix = channel === "stable" ? "" : `~${channel}.${sequence}`;
  return {
    tag: `v${version}`,
    channel,
    core,
    wix: `${major}.${minor}.${Number(patch) * 256 + installerBuild}`,
    rpmRelease,
    deb: `${core}+lingxi${debSuffix}`,
  };
}

async function main([command = "check", argument] = process.argv.slice(2)) {
  const manifest = await readFile(new URL("Cargo.toml", root), "utf8");
  const workspace = manifest.split(/^\[workspace\.package\][ \t]*$/m)[1]?.split(/^\[/m)[0];
  const version = /^version\s*=\s*"([^"]+)"/m.exec(workspace ?? "")?.[1];
  if (!version) throw new Error("Cargo.toml [workspace.package] has no version");
  const release = releaseVersion(version);

  if ((command === "check" || command === "channel") && argument && argument !== release.tag) {
    throw new Error(`Git tag ${argument} does not match ${release.tag}`);
  }

  switch (command) {
    case "prepare": {
      const cargo = spawnSync("cargo", ["update", "--workspace"], { cwd: fileURLToPath(root), stdio: "inherit" });
      if (cargo.error) throw cargo.error;
      if (cargo.status !== 0) throw new Error("Could not refresh Cargo.lock");
      console.log(release.tag);
      break;
    }
    case "check": {
      for (const file of ["Apps/desktop/package.json", "Apps/desktop/src-tauri/tauri.conf.json"]) {
        const config = JSON.parse(await readFile(new URL(file, root), "utf8"));
        if (Object.hasOwn(config, "version")) throw new Error(`Remove version from ${file}; use Cargo.toml`);
      }
      console.log(`version: ${version} (${release.channel})`);
      break;
    }
    case "channel":
      console.log(release.channel);
      break;
    case "tag":
      console.log(release.tag);
      break;
    case "numeric":
      console.log(release.core);
      break;
    case "deb-version":
      console.log(release.deb);
      break;
    case "wix-config":
    case "rpm-config": {
      if (!argument) throw new Error(`${command} requires an output path`);
      const config = command === "wix-config"
        ? { bundle: { windows: { wix: { version: release.wix } } } }
        : { version: release.core, bundle: { linux: { rpm: { release: release.rpmRelease } } } };
      await writeFile(argument, `${JSON.stringify(config, null, 2)}\n`);
      break;
    }
    default:
      throw new Error(`Unknown command: ${command}`);
  }
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  try {
    await main();
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
