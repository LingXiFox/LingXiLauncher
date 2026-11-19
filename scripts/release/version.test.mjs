import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import { releaseVersion } from "./version.mjs";

const releases = ["0.10.0-beta.4", "0.10.0-beta.10", "0.10.0-rc.1", "0.10.0", "0.10.1-beta.1"]
  .map(releaseVersion);

test("derives tags, channels, and installer versions from SemVer", () => {
  assert.deepEqual(releases.map(({ channel }) => channel), ["beta", "beta", "rc", "stable", "beta"]);
  assert.deepEqual(releases.map(({ wix }) => wix), ["0.10.4", "0.10.10", "0.10.128", "0.10.255", "0.10.257"]);
  assert.deepEqual(releases.map(({ rpmRelease }) => rpmRelease), ["1.1.4", "1.1.10", "1.2.1", "2", "1.1.1"]);
  assert.equal(releases[0].tag, "v0.10.0-beta.4");
  assert.equal(releaseVersion("255.255.255-rc.127").wix, "255.255.65534");
  for (const invalid of ["0.10", "0.010.0", "0.10.0-alpha.1", "0.10.0-rc.01", "0.10.0-beta.128", "0.10.256", "0.10.0+build"]) {
    assert.throws(() => releaseVersion(invalid));
  }
});

test("DEB versions advance from the old RC packages through Beta, RC and Stable", { skip: process.platform !== "linux" }, () => {
  const debVersions = ["0.10.0-rc.2", ...releases.map(({ deb }) => deb)];
  for (let i = 1; i < debVersions.length; i++) {
    const result = spawnSync("dpkg", ["--compare-versions", debVersions[i - 1], "lt", debVersions[i]], { encoding: "utf8" });
    assert.ifError(result.error);
    assert.equal(result.status, 0, `${debVersions[i - 1]} < ${debVersions[i]}: ${result.stderr}`);
  }
});
