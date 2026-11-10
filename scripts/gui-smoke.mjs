#!/usr/bin/env node
/**
 * GUI smoke test for the built React frontend.
 *
 * It serves Apps/desktop/dist, stubs the Tauri IPC bridge in a headless
 * Chrome page, then drives the real UI through navigation, instance details,
 * modals and settings validation. No extra npm dependencies are required.
 */
import { createServer } from "node:http";
import { readFile, mkdir, readFile as readFileAsync, rm } from "node:fs/promises";
import { existsSync } from "node:fs";
import { spawn } from "node:child_process";
import { extname, join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const ROOT = resolve(import.meta.dirname, "..");
const DIST = join(ROOT, "Apps/desktop/dist");
const ARTIFACTS = join(ROOT, ".tmp/gui-smoke");
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

if (!existsSync(join(DIST, "index.html"))) {
  console.error("error: Apps/desktop/dist/index.html is missing; run pnpm build first");
  process.exit(2);
}
if (!existsSync(CHROME)) {
  console.error("error: Google Chrome is required for the GUI smoke test");
  process.exit(2);
}

const instance = {
  id: "smoke",
  name: "冒烟实例",
  versionId: "1.21.11",
  gameVersion: "1.21.11",
  loader: "fabric",
  loaderVersion: "0.20.1",
  memoryMiB: 4096,
  jvmArguments: "",
  lastLaunchedAt: "2026-11-10T04:00:00Z",
  modCount: 0,
  resourcePackCount: 0,
  shaderCount: 0,
  path: "/tmp/lingxi-smoke/instances/smoke",
  modpack: null,
};

const versions = [
  { id: "1.21.11", type: "release", releaseTime: "2026-10-01T00:00:00Z", installed: true },
  { id: "1.21.10", type: "release", releaseTime: "2026-09-01T00:00:00Z", installed: false },
  { id: "1.22-snapshot-3", type: "snapshot", releaseTime: "2026-10-20T00:00:00Z", installed: false },
  { id: "1.22-snapshot-2", type: "snapshot", releaseTime: "2026-10-10T00:00:00Z", installed: false },
];

const bootstrap = {
  version: "0.10.0",
  dataRoot: "/tmp/lingxi-smoke/data",
  gameRoot: "/tmp/lingxi-smoke/game",
  platform: "macos",
  architecture: "aarch64",
  settings: {
    javaPath: null,
    source: "auto",
    mirrorConfigPath: null,
    defaultMemoryMiB: 4096,
    appearance: "dark",
  },
  accounts: {
    microsoft: [],
    local: [{ name: "Tester", uuid: "f3d28cb0-7225-3cb1-baeb-2dadd2be89ae", createdAt: "2026-11-10T03:00:00Z" }],
  },
  activeAccount: { kind: "local", identifier: "Tester" },
  instances: [instance],
  javaRuntimes: [
    {
      path: "/Library/Java/JavaVirtualMachines/microsoft-21.jdk/Contents/Home/bin/java",
      version: "21.0.9",
      vendor: "Microsoft",
      architecture: "aarch64",
      majorVersion: 21,
    },
  ],
  isGameRunning: false,
  gamePid: null,
};

const graphics = {
  preset: "fancy",
  renderDistance: 12,
  simulationDistance: 12,
  maxFps: 120,
  guiScale: 0,
  particles: "all",
  clouds: true,
  entityShadows: true,
  ambientOcclusion: true,
  vsync: true,
  fullscreen: false,
};

const replies = {
  bootstrap,
  list_instances: [instance],
  list_local_accounts: bootstrap.accounts.local,
  list_microsoft_accounts: [],
  list_versions: versions,
  refresh_versions: versions,
  list_loader_versions: [{ version: "0.20.1", gameVersion: "1.21.11", stable: true }],
  read_logs: {
    path: "/tmp/lingxi-smoke/data/logs/latest.log",
    content: "[12:00:00] [main/INFO] smoke launcher log\n[12:00:01] [Render thread/INFO] OpenGL initialized",
  },
  list_mods: [],
  search_modrinth: { hits: [], totalHits: 0, offset: 0, limit: 24 },
  list_worlds: [],
  list_backups: [],
  list_resource_packs: [],
  list_shaders: [],
  read_instance_graphics: { path: "/tmp/lingxi-smoke/instances/smoke/options.txt", exists: false, settings: graphics },
  performance_report: {
    profile: "fancy",
    summary: "冒烟测试配置",
    recommendations: ["分配 4 GiB 内存", "渲染距离 12 区块"],
    system: { cpu: "Apple M3 Pro", memoryMiB: 36864, gpu: null, os: "macOS" },
    score: 87,
    benchmarkScore: 87,
    legacy_reports: [],
  },
  diagnose: {
    checks: [
      { id: "java", label: "Java 运行时", status: "pass", detail: "Java 21" },
      { id: "game", label: "游戏文件", status: "warn", detail: "冒烟数据未安装客户端" },
    ],
    summary: "冒烟检查完成",
  },
  latest_crash_report: null,
  game_status: { running: false, pid: null, startedAt: null, lastExit: null },
  "plugin:event|listen": 1,
  "plugin:event|unlisten": true,
  "plugin:dialog|open": null,
};

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".woff2": "font/woff2",
  ".json": "application/json",
};

function readBody(request) {
  return new Promise((resolveBody, reject) => {
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => resolveBody(Buffer.concat(chunks).toString("utf8")));
    request.on("error", reject);
  });
}

const server = createServer(async (request, response) => {
  if (request.url === "/__ipc" && request.method === "POST") {
    try {
      const { cmd } = JSON.parse(await readBody(request));
      const value = Object.prototype.hasOwnProperty.call(replies, cmd) ? replies[cmd] : null;
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(value));
    } catch (error) {
      response.writeHead(500, { "content-type": "text/plain" });
      response.end(String(error));
    }
    return;
  }

  const pathname = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
  const target = resolve(DIST, "." + (pathname === "/" ? "/index.html" : pathname));
  if (!target.startsWith(DIST)) {
    response.writeHead(403).end();
    return;
  }
  try {
    const body = await readFile(target);
    response.writeHead(200, { "content-type": MIME[extname(target)] ?? "application/octet-stream" });
    response.end(body);
  } catch {
    response.writeHead(404, { "content-type": "text/plain" });
    response.end("not found");
  }
});

await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
const appPort = server.address().port;

await mkdir(ARTIFACTS, { recursive: true });
const profile = join("/tmp", `lingxi-gui-smoke-${process.pid}`);
const chrome = spawn(
  CHROME,
  [
    "--headless=new",
    "--no-sandbox",
    "--disable-gpu",
    "--disable-gpu-sandbox",
    "--disable-dev-shm-usage",
    "--no-first-run",
    "--no-default-browser-check",
    "--user-data-dir=" + profile,
    "--remote-debugging-port=0",
    "--remote-allow-origins=*",
    "--window-size=1280,820",
    "about:blank",
  ],
  { stdio: "ignore" },
);

async function waitForDevtools() {
  const portFile = join(profile, "DevToolsActivePort");
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      const [port] = (await readFileAsync(portFile, "utf8")).trim().split("\n");
      if (port) return Number(port);
    } catch {
      /* Chrome is still starting. */
    }
    await delay(100);
  }
  throw new Error("Chrome DevTools port did not appear");
}

let ws;
let nextId = 1;
const pending = new Map();

function send(method, params = {}) {
  const id = nextId++;
  return new Promise((resolveSend, rejectSend) => {
    pending.set(id, { resolve: resolveSend, reject: rejectSend });
    ws.send(JSON.stringify({ id, method, params }));
  });
}

async function evaluate(expression) {
  const response = await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
  if (response.exceptionDetails) {
    throw new Error(`page evaluation failed: ${response.exceptionDetails.text ?? "unknown"}`);
  }
  return response.result?.value;
}

async function waitFor(description, expression, timeout = 15000) {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    if (await evaluate(expression)) return;
    await delay(120);
  }
  throw new Error(`timed out waiting for ${description}`);
}

async function clickButton(text) {
  const clicked = await evaluate(`(() => {
    const buttons = [...document.querySelectorAll("button")];
    const wanted = ${JSON.stringify(text)};
    const node =
      buttons.find((item) => item.textContent.trim() === wanted) ??
      buttons.find((item) => item.textContent.trim().includes(wanted));
    if (!node) return false;
    node.click();
    return true;
  })()`);
  if (!clicked) throw new Error(`button not found: ${text}`);
}

async function screenshot(name) {
  const shot = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: false });
  await import("node:fs/promises").then((fs) => fs.writeFile(join(ARTIFACTS, `${name}.png`), Buffer.from(shot.data, "base64")));
}

let failed = false;
try {
  const devtoolsPort = await waitForDevtools();
  let target;
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const list = await fetch(`http://127.0.0.1:${devtoolsPort}/json/list`).then((response) => response.json());
    target = list.find((item) => item.type === "page");
    if (target) break;
    await delay(100);
  }
  if (!target) throw new Error("no Chrome page target found");

  ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolveOpen, rejectOpen) => {
    ws.addEventListener("open", resolveOpen, { once: true });
    ws.addEventListener("error", rejectOpen, { once: true });
  });
  ws.addEventListener("close", (event) => {
    if (event.code !== 1000) console.error("WebSocket closed", event.code, event.reason);
  });
  ws.addEventListener("error", (event) => console.error("ws error", event));
  ws.addEventListener("message", async (event) => {
    let raw = event.data;
    if (raw instanceof Blob) raw = await raw.text();
    else if (raw instanceof ArrayBuffer) raw = new TextDecoder().decode(raw);
    else if (Buffer.isBuffer(raw)) raw = raw.toString("utf8");
    const message = JSON.parse(String(raw));
    if (!message.id) return;
    const handler = pending.get(message.id);
    if (!handler) return;
    pending.delete(message.id);
    if (message.error) handler.reject(new Error(message.error.message));
    else handler.resolve(message.result);
  });

  await send("Page.enable");
  await send("Runtime.enable");
  await send("Page.addScriptToEvaluateOnNewDocument", {
    source: `(() => {
      let nextCallback = 1;
      const callbacks = new Map();
      window.__TAURI_INTERNALS__ = {
        invoke: async (cmd, args) => {
          const response = await fetch("/__ipc", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ cmd, args }),
          });
          if (!response.ok) throw new Error(await response.text());
          return await response.json();
        },
        transformCallback: (callback, once) => {
          const id = nextCallback++;
          callbacks.set(id, { callback, once });
          return id;
        },
        unregisterCallback: (id) => callbacks.delete(id),
        convertFileSrc: (path) => path,
        metadata: { currentWindow: { label: "main" }, currentWebview: { label: "main", windowLabel: "main" } },
      };
      window.__TAURI__ = {};
      window.__TAURI_EVENT_PLUGIN_INTERNALS__ = {
        unregisterListener: () => {},
        registerListener: () => {},
      };
    })();`,
  });

  await send("Page.navigate", { url: `http://127.0.0.1:${appPort}/` });
  await waitFor("launcher shell", "!!document.querySelector('.sidebar') && document.body.innerText.includes('首页')");
  await screenshot("01-home");

  await clickButton("游戏实例");
  await waitFor("instances page", "document.body.innerText.includes('冒烟实例')");
  await screenshot("02-instances");

  const opened = await evaluate(`(() => {
    const node = document.querySelector(".instance-card__main");
    if (!node) return false;
    node.click();
    return true;
  })()`);
  if (!opened) throw new Error("instance card not found");
  await waitFor("instance detail", "document.body.innerText.includes('实例详情')");

  await clickButton("模组");
  await waitFor("mods modal", "!!document.querySelector('[role=dialog]') && document.body.innerText.includes('模组管理')");
  await screenshot("03-mods-modal");
  await evaluate("document.querySelector('.modal-close').click()");
  await waitFor("mods modal closed", "!document.querySelector('[role=dialog]')");

  await clickButton("图形");
  await waitFor("graphics modal", "document.body.innerText.includes('图形设置')");
  await screenshot("04-graphics-modal");
  await evaluate("document.querySelector('.modal-close').click()");
  await waitFor("graphics modal closed", "!document.querySelector('[role=dialog]')");

  await clickButton("安装游戏");
  await waitFor("install wizard", "document.body.innerText.includes('安装新的 Minecraft')");
  await screenshot("05-install-wizard");
  await evaluate("document.querySelector('.modal-close').click()");
  await waitFor("install wizard closed", "!document.querySelector('[role=dialog]')");

  await clickButton("设置");
  await waitFor("settings page", "document.body.innerText.includes('默认内存分配')");
  await screenshot("06-settings");

  const changed = await evaluate(`(() => {
    const input = document.querySelector('input[type="number"]');
    if (!input) return false;
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
    setter.call(input, "1024");
    input.dispatchEvent(new Event("input", { bubbles: true }));
    setter.call(input, "100");
    input.dispatchEvent(new Event("input", { bubbles: true }));
    return true;
  })()`);
  if (!changed) throw new Error("memory input not found");
  await delay(150);
  await clickButton("保存设置");
  await waitFor("memory validation", "document.body.innerText.includes('默认内存需在 512 MiB 到 65536 MiB 之间')");
  await screenshot("07-validation");

  await clickButton("账户管理");
  await waitFor("accounts page", "document.body.innerText.includes('Tester')");
  await screenshot("08-accounts");

  await clickButton("运行日志");
  await waitFor("logs page", "document.body.innerText.includes('smoke launcher log')");
  await screenshot("09-logs");

  console.log("GUI smoke passed: boot, navigation, instance detail, mods/graphics/install modals, settings validation, accounts, logs");
  console.log(`Screenshots: ${ARTIFACTS}`);
} catch (error) {
  failed = true;
  console.error(`GUI smoke failed: ${error instanceof Error ? error.message : String(error)}`);
  try {
    await screenshot("failure");
  } catch {
    /* Ignore screenshot failures while reporting the original error. */
  }
} finally {
  try {
    ws?.close();
  } catch {
    /* ignore */
  }
  chrome.kill("SIGTERM");
  server.close();
  try { await rm(profile, { recursive: true, force: true }); } catch { /* Chrome may still be flushing its profile. */ }
}

process.exit(failed ? 1 : 0);
