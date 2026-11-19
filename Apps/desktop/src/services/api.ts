import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type { InstallEvent as InstallProgressEvent } from "./progress";

export type { InstallProgressEvent };

/* ------------------------------------------------------------------ */
/* Domain types                                                        */
/* ------------------------------------------------------------------ */

export type Appearance = "dark" | "light" | "system";
export type AccentColor = "orange" | "blue" | "green" | "purple" | "pink" | "red";
export type Language = "zh-CN" | "en-US";
export type ProxyMode = "system" | "manual" | "off";
export type UpdateChannel = "stable" | "rc" | "beta";
export type DownloadSource = "official" | "mirror" | "auto" | "local-cache-only";
export type MemoryMode = "auto" | "fixed";
export type VersionFilter = "release" | "snapshot" | "all";
export type AccountKind = "microsoft" | "local";
export type LogKind = "launcher" | "game" | "latest";
export type CheckStatus = "pass" | "warn" | "fail";

export interface LauncherSettings {
  javaPath?: string | null;
  source: DownloadSource;
  mirrorConfigPath?: string | null;
  defaultMemoryMib: number;
  /** `auto` derives the heap from physical memory; `fixed` uses the value above. */
  memoryMode: MemoryMode;
  /** Read-only result of the automatic policy, computed by the backend. */
  automaticMemoryMib: number;
  appearance: Appearance;
  language: Language;
  accent: AccentColor;
  backgroundImage?: string | null;
  proxyMode: ProxyMode;
  proxyUrl?: string | null;
  gameRoot?: string | null;
  logWindowOnStart: boolean;
  updateChannel: UpdateChannel;
}

export interface MicrosoftAccount {
  id: string;
  playerName: string;
  uuid?: string | null;
  skinTextureUrl?: string | null;
  skinTextureURL?: string | null;
  signedInAt?: string | null;
}

export interface LocalAccount {
  name: string;
  uuid?: string | null;
  createdAt?: string | null;
}

export interface AccountSnapshot {
  microsoft: MicrosoftAccount[];
  local: LocalAccount[];
}

export interface ActiveAccount {
  kind: AccountKind;
  identifier: string;
}

export interface GameInstance {
  id: string;
  name: string;
  versionId: string;
  gameVersion?: string | null;
  loader?: string | null;
  loaderVersion?: string | null;
  memoryMib?: number | null;
  jvmArguments?: string | null;
  lastLaunchedAt?: string | null;
  modCount?: number | null;
  resourcePackCount?: number | null;
  shaderCount?: number | null;
  path?: string | null;
  launch?: InstanceLaunchSettings | null;
  modpack?: { name: string; version: string; projectId?: string | null } | null;
}

export type WindowMode = "windowed" | "fullscreen" | "maximized";
export type ProcessPriority = "low" | "belowNormal" | "normal" | "aboveNormal" | "high";
export type GraphicsApi = "auto" | "openGl" | "vulkan";
export type LauncherVisibility = "keep" | "minimize" | "close" | "hide";

export interface InstanceLaunchSettings {
  windowMode: WindowMode;
  windowWidth: number;
  windowHeight: number;
  processPriority: ProcessPriority;
  environment: Record<string, string>;
  preLaunchCommand?: string | null;
  wrapperCommand?: string | null;
  postLaunchCommand?: string | null;
  graphicsApi: GraphicsApi;
  vulkanValidation: boolean;
  verifyBeforeLaunch: boolean;
  launcherVisibility: LauncherVisibility;
}

export interface JavaRuntime {
  path: string;
  version: string;
  vendor?: string | null;
  architecture?: string | null;
  majorVersion?: number | null;
}

export interface GameExit {
  code?: number | null;
  message?: string | null;
}

export interface GameStatus {
  running: boolean;
  pid?: number | null;
  startedAt?: string | null;
  lastExit?: GameExit | null;
}

export interface LauncherBootstrap {
  version: string;
  dataRoot: string;
  gameRoot: string;
  platform: string;
  settings: LauncherSettings;
  accounts: AccountSnapshot;
  activeAccount: ActiveAccount | null;
  instances: GameInstance[];
  javaRuntimes: JavaRuntime[];
  isGameRunning: boolean;
  gamePid?: number | null;
}

export interface GameVersion {
  id: string;
  type: string;
  releaseTime?: string | null;
  installed?: boolean;
  installStatus?: "installing" | "complete" | "failed" | "cancelled" | "interrupted" | null;
  url?: string | null;
}

export interface InstallProgress {
  phase: string;
  totalFiles: number;
  completedFiles: number;
  totalBytes: number;
  downloadedBytes: number;
  currentFile?: string | null;
  message?: string | null;
  /** Bytes per second measured by the backend speed reporter. */
  bytesPerSecond?: number;
  /** Estimated seconds remaining, when the backend can compute it. */
  remainingSeconds?: number | null;
  /** Files currently being transferred. */
  activeFiles?: number;
  /** Retry notice for the file that just failed and will be retried. */
  retry?: { path: string; attempt: number; maxAttempts: number; message: string } | null;
}

export interface UpdateInfo {
  currentVersion: string;
  release: {
    version: string;
    url: string;
    notes: string | null;
    publishedAt: string | null;
  } | null;
}

export interface LogContent {
  path: string;
  content: string;
}

export interface LoaderVersion {
  version: string;
  gameVersion: string;
  stable: boolean;
}

export interface InstalledMod {
  projectId: string;
  name: string;
  versionId?: string | null;
  versionNumber?: string | null;
  fileName?: string | null;
  enabled: boolean;
  updateAvailable?: boolean;
  latestVersionId?: string | null;
  latestVersionNumber?: string | null;
  iconUrl?: string | null;
  description?: string | null;
}

export interface ModSearchHit {
  projectId: string;
  slug?: string | null;
  title: string;
  description?: string | null;
  iconUrl?: string | null;
  downloads?: number | null;
  follows?: number | null;
  versions?: string[];
  latestVersionId?: string | null;
  loader?: string | null;
}

export interface ModSearchResponse {
  hits: ModSearchHit[];
  totalHits: number;
  offset: number;
  limit: number;
}

export interface MrpackSummary {
  name: string;
  version?: string | null;
  author?: string | null;
  description?: string | null;
  modCount?: number | null;
  minecraftVersion?: string | null;
  loader?: string | null;
  files?: { path: string; size?: number | null }[];
  path: string;
}

export interface ModpackUpdateInfo {
  currentVersion: string;
  latestVersion: string;
  changelog?: string | null;
  publishedAt?: string | null;
  downloadUrl?: string | null;
}

export interface World {
  folder: string;
  name: string;
  lastPlayed?: string | null;
  sizeBytes?: number | null;
  gameMode?: string | null;
  version?: string | null;
}

export interface WorldBackup {
  id: string;
  name: string;
  folder?: string | null;
  path?: string | null;
  createdAt?: string | null;
  sizeBytes?: number | null;
}

export interface ContentPack {
  fileName: string;
  name?: string | null;
  description?: string | null;
  enabled: boolean;
  sizeBytes?: number | null;
  iconUrl?: string | null;
}

export type GraphicsPreset = "fast" | "fancy" | "fabulous";
export type ParticleMode = "all" | "decreased" | "minimal";

export interface GraphicsSettings {
  preset: GraphicsPreset;
  renderDistance: number;
  simulationDistance: number;
  maxFps: number;
  guiScale: number;
  particles: ParticleMode;
  clouds: boolean;
  entityShadows: boolean;
  ambientOcclusion: boolean;
  vsync: boolean;
  fullscreen: boolean;
}

export interface GraphicsSnapshot {
  path: string;
  exists: boolean;
  settings: GraphicsSettings;
}

export interface PerformanceSystemProfile {
  cpu?: string | null;
  memoryMib?: number | null;
  gpu?: string | null;
  os?: string | null;
}

export interface LegacyPerformanceReport {
  id: string;
  createdAt: string;
  instanceId: string;
  minecraftVersion: string;
  loader: string;
  samples: number;
  startupAverageMs?: number | null;
  cpuAverage?: number | null;
  residentPeakBytes?: number | null;
  notes?: string[];
}

export interface PerformanceReport {
  profile?: string | null;
  summary?: string | null;
  recommendations?: string[];
  system?: PerformanceSystemProfile | null;
  score?: number | null;
  benchmarkScore?: number | null;
  legacyReports?: LegacyPerformanceReport[];
}

export interface BenchmarkResult {
  score: number;
  summary?: string | null;
  durationMs?: number | null;
  sample?: number[] | null;
}

export interface DiagnosticCheck {
  id: string;
  label: string;
  status: CheckStatus;
  detail?: string | null;
}

export interface DiagnosticsReport {
  checks: DiagnosticCheck[];
  summary?: string | null;
}

export interface CrashReport {
  id?: string | null;
  occurredAt?: string | null;
  reason?: string | null;
  description?: string | null;
  stackTrace?: string | null;
  filePath?: string | null;
  instanceId?: string | null;
}

export interface GameLogEvent {
  line: string;
  stream?: string | null;
  instanceId?: string | null;
  timestamp?: string | null;
}

/* ------------------------------------------------------------------ */
/* Error handling                                                      */
/* ------------------------------------------------------------------ */

export class ApiError extends Error {
  readonly command: string;

  constructor(command: string, message: string) {
    super(message);
    this.name = "ApiError";
    this.command = command;
  }
}

function describeError(error: unknown): string {
  if (typeof error === "string") return error;
  if (error instanceof Error) return error.message;
  if (error && typeof error === "object") {
    const record = error as Record<string, unknown>;
    if (typeof record.message === "string") return record.message;
    if (typeof record.error === "string") return record.error;
    try {
      return JSON.stringify(error);
    } catch {
      return "未知错误";
    }
  }
  return "未知错误";
}

async function call<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  const payload = args
    ? Object.fromEntries(Object.entries(args).filter(([, value]) => value !== undefined))
    : undefined;
  try {
    return await invoke<T>(command, payload);
  } catch (error) {
    throw new ApiError(command, describeError(error));
  }
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" ? (value as Record<string, unknown>) : {};
}

function asString(value: unknown, fallback = ""): string {
  return typeof value === "string" ? value : fallback;
}

function asNumber(value: unknown, fallback = 0): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function asBoolean(value: unknown, fallback = false): boolean {
  return typeof value === "boolean" ? value : fallback;
}

function normalizeAccounts(raw: unknown): AccountSnapshot {
  const snapshot: AccountSnapshot = { microsoft: [], local: [] };
  if (Array.isArray(raw)) {
    for (const entry of raw) {
      const item = asRecord(entry);
      const kind = asString(item.kind, asString(item.type));
      if (kind === "microsoft") {
        snapshot.microsoft.push(entry as MicrosoftAccount);
      } else if (kind === "local") {
        snapshot.local.push(entry as LocalAccount);
      }
    }
    return snapshot;
  }
  const record = asRecord(raw);
  if (Array.isArray(record.microsoft)) snapshot.microsoft = record.microsoft as MicrosoftAccount[];
  if (Array.isArray(record.local)) snapshot.local = record.local as LocalAccount[];
  return snapshot;
}

function normalizeBootstrap(raw: LauncherBootstrap & { accounts?: unknown }): LauncherBootstrap {
  const settings = asRecord(raw.settings);
  return {
    ...raw,
    settings: {
      javaPath: (settings.javaPath as string | null | undefined) ?? null,
      source: (settings.source as DownloadSource) ?? "auto",
      mirrorConfigPath: (settings.mirrorConfigPath as string | null | undefined) ?? null,
      defaultMemoryMib: asNumber(settings.defaultMemoryMib, 4096),
      memoryMode: settings.memoryMode === "fixed" ? "fixed" : "auto",
      automaticMemoryMib: asNumber(settings.automaticMemoryMib, 0),
      appearance: (settings.appearance as Appearance) ?? "dark",
      language: (settings.language as LauncherSettings["language"]) ?? "zh-CN",
      accent: (settings.accent as LauncherSettings["accent"]) ?? "orange",
      backgroundImage: (settings.backgroundImage as string | null | undefined) ?? null,
      proxyMode: (settings.proxyMode as LauncherSettings["proxyMode"]) ?? "system",
      proxyUrl: (settings.proxyUrl as string | null | undefined) ?? null,
      gameRoot: (settings.gameRoot as string | null | undefined) ?? null,
      logWindowOnStart: asBoolean(settings.logWindowOnStart),
      updateChannel: (settings.updateChannel as UpdateChannel) ?? "stable",
    },
    accounts: normalizeAccounts(raw.accounts),
    instances: Array.isArray(raw.instances) ? raw.instances : [],
    javaRuntimes: Array.isArray(raw.javaRuntimes) ? raw.javaRuntimes : [],
    isGameRunning: asBoolean(raw.isGameRunning),
  };
}


/* ------------------------------------------------------------------ */
/* Commands                                                            */
/* ------------------------------------------------------------------ */

export const api = {
  bootstrap: async (): Promise<LauncherBootstrap> => {
    const raw = await call<LauncherBootstrap & { accounts?: unknown }>("bootstrap");
    return normalizeBootstrap(raw);
  },

  listInstances: () => call<GameInstance[]>("list_instances"),
  createInstance: (name: string, versionId: string) =>
    call<GameInstance>("create_instance", { name, versionId }),
  updateInstance: (id: string, patch: { memoryMib?: number; jvmArguments?: string }) =>
    call<void>("update_instance", { id, ...patch }),
  updateInstanceLaunch: (id: string, launch: InstanceLaunchSettings) =>
    call<GameInstance>("update_instance_launch", { id, launch }),
  deleteInstance: (id: string, keepSaves = true) =>
    call<void>("delete_instance", { id, keepSaves }),
  copyInstance: (id: string, name: string) => call<GameInstance>("copy_instance", { id, name }),
  setInstanceVersion: (id: string, versionId: string) =>
    call<void>("set_instance_version", { id, versionId }),

  listVersions: (filter: VersionFilter = "all") =>
    call<GameVersion[]>("list_versions", { filter }),
  refreshVersions: () => call<GameVersion[]>("refresh_versions"),
  installVersion: (versionId: string, instanceId?: string, source?: DownloadSource) =>
    call<void>("install_version", { versionId, instanceId, source }),
  cancelInstall: (versionId: string) => call<boolean>("cancel_install", { versionId }),
  listInstallTasks: () => call<string[]>("list_install_tasks"),
  listLoaderVersions: (loader: string, gameVersion: string) =>
    call<LoaderVersion[]>("list_loader_versions", { loader, gameVersion }),
  installLoader: (loader: string, instanceId: string, gameVersion: string, loaderVersion?: string) =>
    call<unknown>("install_loader", { loader, instanceId, gameVersion, loaderVersion }),

  launchInstance: (instanceId: string, identityMode?: string, playerName?: string) =>
    call<void>("launch_instance", { instanceId, identityMode, playerName }),
  stopGame: () => call<void>("stop_game"),
  gameStatus: () => call<GameStatus>("game_status"),

  listLocalAccounts: () => call<LocalAccount[]>("list_local_accounts"),
  createLocalAccount: (name: string) => call<LocalAccount>("create_local_account", { name }),
  deleteLocalAccount: (name: string) => call<void>("delete_local_account", { name }),
  listMicrosoftAccounts: () => call<MicrosoftAccount[]>("list_microsoft_accounts"),
  beginMicrosoftLogin: () => call<{ url: string }>("begin_microsoft_login"),
  cancelMicrosoftLogin: () => call<void>("cancel_microsoft_login"),
  signOutMicrosoft: (id: string) => call<void>("sign_out_microsoft", { id }),
  setActiveAccount: (kind: AccountKind, identifier: string) =>
    call<void>("set_active_account", { kind, identifier }),

  readLogs: (kind: LogKind, instanceId?: string) =>
    call<LogContent>("read_logs", { kind, instanceId }),
  openLogsFolder: () => call<void>("open_logs_folder"),
  revealPath: (path: string) => call<void>("reveal_path", { path }),
  getSettings: () => call<LauncherSettings>("get_settings"),
  saveSettings: (patch: Partial<LauncherSettings>) =>
    call<LauncherSettings>("save_settings", { ...patch }),
  detectJava: () => call<JavaRuntime[]>("detect_java"),
  browseJava: () => call<string | null>("browse_java"),
  browseFolder: () => call<string | null>("browse_folder"),
  browseImage: () => call<string | null>("browse_image"),
  readBackgroundImage: (path: string) =>
    call<string>("read_background_image", { path }),
  restartApp: () => call<void>("restart_app"),
  openLogWindow: () => call<void>("open_log_window"),
  checkUpdate: () => call<UpdateInfo>("check_update"),
  openExternal: (url: string) => call<void>("open_external", { url }),

  listMods: (instanceId: string) => call<InstalledMod[]>("list_mods", { instanceId }),
  searchModrinth: async (params: {
    query: string;
    gameVersion?: string;
    loader?: string;
    limit?: number;
    offset?: number;
  }): Promise<ModSearchResponse> => {
    const raw = await call<unknown>("search_modrinth", { ...params });
    const record = asRecord(raw);
    const hits = Array.isArray(record.hits) ? (record.hits as ModSearchHit[]) : [];
    return {
      hits,
      totalHits: asNumber(record.totalHits, hits.length),
      offset: asNumber(record.offset, params.offset ?? 0),
      limit: asNumber(record.limit, params.limit ?? hits.length),
    };
  },
  installMod: (instanceId: string, versionId: string) =>
    call<InstalledMod>("install_mod", { instanceId, versionId }),
  toggleMod: (instanceId: string, projectId: string, enabled: boolean) =>
    call<void>("toggle_mod", { instanceId, projectId, enabled }),
  deleteMod: (instanceId: string, projectId: string) =>
    call<void>("delete_mod", { instanceId, projectId }),
  checkModUpdates: (instanceId: string) => call<InstalledMod[]>("check_mod_updates", { instanceId }),
  updateMod: (instanceId: string, projectId: string) =>
    call<InstalledMod>("update_mod", { instanceId, projectId }),

  inspectMrpack: (path: string) => call<MrpackSummary>("inspect_mrpack", { path }),
  importMrpack: (path: string, name?: string) =>
    call<GameInstance>("import_mrpack", { path, name }),
  checkModpackUpdate: (instanceId: string) =>
    call<ModpackUpdateInfo | null>("check_modpack_update", { instanceId }),
  applyModpackUpdate: (instanceId: string) =>
    call<void>("apply_modpack_update", { instanceId }),

  listWorlds: (instanceId: string) => call<World[]>("list_worlds", { instanceId }),
  backupWorld: (instanceId: string, folder: string) =>
    call<WorldBackup>("backup_world", { instanceId, folder }),
  restoreWorld: (instanceId: string, backup: string) =>
    call<void>("restore_world", { instanceId, backup }),
  deleteWorld: (instanceId: string, folder: string) =>
    call<void>("delete_world", { instanceId, folder }),
  listBackups: (instanceId: string) => call<WorldBackup[]>("list_backups", { instanceId }),

  listResourcePacks: (instanceId: string) =>
    call<ContentPack[]>("list_resourcepacks", { instanceId }),
  importResourcePack: (instanceId: string, path: string) =>
    call<ContentPack>("import_resourcepack", { instanceId, path }),
  toggleResourcePack: (instanceId: string, fileName: string, enabled: boolean) =>
    call<void>("toggle_resourcepack", { instanceId, fileName, enabled }),
  deleteResourcePack: (instanceId: string, fileName: string) =>
    call<void>("delete_resourcepack", { instanceId, fileName }),

  listShaders: (instanceId: string) => call<ContentPack[]>("list_shaders", { instanceId }),
  importShader: (instanceId: string, path: string) =>
    call<ContentPack>("import_shader", { instanceId, path }),
  toggleShader: (instanceId: string, fileName: string, enabled: boolean) =>
    call<void>("toggle_shader", { instanceId, fileName, enabled }),
  deleteShader: (instanceId: string, fileName: string) =>
    call<void>("delete_shader", { instanceId, fileName }),

  readInstanceGraphics: (instanceId: string) =>
    call<GraphicsSnapshot>("read_instance_graphics", { instanceId }),
  saveInstanceGraphics: (instanceId: string, settings: GraphicsSettings) =>
    call<GraphicsSnapshot>("save_instance_graphics", { instanceId, settings }),

  performanceReport: (instanceId: string) =>
    call<PerformanceReport>("performance_report", { instanceId }),
  runBenchmark: (instanceId: string) =>
    call<BenchmarkResult | number>("run_benchmark", { instanceId }),
  applyPerformance: (instanceId: string) =>
    call<void>("apply_performance", { instanceId }),

  diagnose: (instanceId: string) => call<DiagnosticsReport>("diagnose", { instanceId }),
  latestCrashReport: (instanceId: string) =>
    call<CrashReport | null>("latest_crash_report", { instanceId }),
  diagnosticBundle: (instanceId: string) =>
    call<string>("diagnostic_bundle", { instanceId }),
};

/* ------------------------------------------------------------------ */
/* Events                                                              */
/* ------------------------------------------------------------------ */

export function onInstallProgress(handler: (event: InstallProgressEvent) => void): Promise<UnlistenFn> {
  return listen<unknown>("install-progress", (event) => {
    const item = asRecord(event.payload);
    handler({
      kind: asString(item.kind, "unknown"),
      taskId: typeof item.taskId === "string" ? item.taskId : null,
      phase: typeof item.phase === "string" ? item.phase : undefined,
      message: typeof item.message === "string" ? item.message : null,
      totalFiles: typeof item.totalFiles === "number" ? item.totalFiles : undefined,
      totalBytes: typeof item.totalBytes === "number" ? item.totalBytes : undefined,
      cacheHits: typeof item.cacheHits === "number" ? item.cacheHits : undefined,
      path: typeof item.path === "string" ? item.path : undefined,
      size: typeof item.size === "number" ? item.size : undefined,
      bytes: typeof item.bytes === "number" ? item.bytes : undefined,
      source: typeof item.source === "string" ? item.source : undefined,
      downloaded: typeof item.downloaded === "number" ? item.downloaded : undefined,
      total: typeof item.total === "number" ? item.total : undefined,
      bytesPerSecond: typeof item.bytesPerSecond === "number" ? item.bytesPerSecond : undefined,
      remainingSeconds:
        typeof item.remainingSeconds === "number" ? item.remainingSeconds : null,
      activeFiles: typeof item.activeFiles === "number" ? item.activeFiles : undefined,
      attempt: typeof item.attempt === "number" ? item.attempt : undefined,
      maxAttempts: typeof item.maxAttempts === "number" ? item.maxAttempts : undefined,
    });
  });
}

export function onGameLog(handler: (event: GameLogEvent) => void): Promise<UnlistenFn> {
  return listen<unknown>("game-log", (event) => {
    const payload = event.payload;
    if (typeof payload === "string") {
      handler({ line: payload });
      return;
    }
    const item = asRecord(payload);
    handler({
      line: asString(item.line, asString(item.message)),
      stream: (item.stream as string | null | undefined) ?? null,
      instanceId: typeof item.instanceId === "string" ? item.instanceId : null,
      timestamp: typeof item.timestamp === "string" ? item.timestamp : null,
    });
  });
}

export function onGameExited(handler: (exit: GameExit) => void): Promise<UnlistenFn> {
  return listen<unknown>("game-exited", (event) => {
    const item = asRecord(event.payload);
    handler({
      code: typeof item.code === "number" ? item.code : null,
      message: typeof item.message === "string" ? item.message : null,
    });
  });
}

export function onAuthChanged(handler: () => void): Promise<UnlistenFn> {
  return listen<unknown>("auth-changed", () => handler());
}
