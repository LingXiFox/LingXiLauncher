import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import {
  api,
  onAuthChanged,
  onGameExited,
  onGameLog,
  onInstallProgress,
  type ActiveAccount,
  type AccountKind,
  type AccountSnapshot,
  type Appearance,
  type GameInstance,
  type GameLogEvent,
  type GameVersion,
  type InstallProgress,
  type JavaRuntime,
  type LauncherSettings,
  type LocalAccount,
  type MicrosoftAccount,
  type VersionFilter,
} from "../services/api";
import type { ToastItem, ToastTone } from "../components/Toast";

export type Section = "home" | "instances" | "downloads" | "accounts" | "logs" | "settings";

export type AppModal =
  | { type: "install"; versionId?: string }
  | { type: "mods"; instanceId: string }
  | { type: "mrpack" }
  | { type: "modpackUpdate"; instanceId: string }
  | { type: "graphics"; instanceId: string }
  | { type: "performance"; instanceId: string }
  | { type: "resourcepacks"; instanceId: string }
  | { type: "shaders"; instanceId: string }
  | { type: "tools"; instanceId: string; initialTab?: "manage" | "worlds" | "diagnostics" }
  | { type: "crash"; instanceId: string };

export interface ActiveProfile {
  kind: AccountKind;
  identifier: string;
  name: string;
  skinUrl: string | null;
  microsoft: MicrosoftAccount | null;
  local: LocalAccount | null;
}

const DEFAULT_SETTINGS: LauncherSettings = {
  javaPath: null,
  source: "auto",
  mirrorConfigPath: null,
  defaultMemoryMiB: 4096,
  appearance: "dark",
};

function readStoredSection(): Section {
  const raw = localStorage.getItem("lingxi.section");
  if (raw === "home" || raw === "instances" || raw === "downloads" || raw === "accounts" || raw === "logs" || raw === "settings") {
    return raw;
  }
  return "home";
}

function readStoredTheme(): "dark" | "light" {
  return localStorage.getItem("lingxi.theme") === "light" ? "light" : "dark";
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export interface AppStore {
  ready: boolean;
  bootstrapping: boolean;
  bootError: string | null;
  backendOnline: boolean;
  version: string;
  platform: string;
  dataRoot: string;
  gameRoot: string;
  settings: LauncherSettings;
  accounts: AccountSnapshot;
  activeAccount: ActiveAccount | null;
  activeProfile: ActiveProfile | null;
  instances: GameInstance[];
  javaRuntimes: JavaRuntime[];
  versions: GameVersion[];
  versionsLoading: boolean;
  isGameRunning: boolean;
  gamePid: number | null;
  section: Section;
  modal: AppModal | null;
  installedProgress: InstallProgress | null;
  resolvedTheme: "dark" | "light";
  toasts: ToastItem[];
  setSection: (section: Section) => void;
  openModal: (modal: AppModal) => void;
  closeModal: () => void;
  toast: (tone: ToastTone, message: string, detail?: string) => void;
  dismissToast: (id: number) => void;
  bootstrap: () => Promise<void>;
  dismissBootError: () => void;
  refreshInstances: (silent?: boolean) => Promise<void>;
  refreshAccounts: () => Promise<void>;
  refreshVersions: (filter?: VersionFilter, silent?: boolean) => Promise<void>;
  refreshGameStatus: () => Promise<void>;
  createInstance: (name: string, versionId: string) => Promise<GameInstance | null>;
  updateInstance: (id: string, patch: { memoryMiB?: number; jvmArguments?: string }) => Promise<boolean>;
  deleteInstance: (id: string) => Promise<boolean>;
  copyInstance: (id: string) => Promise<GameInstance | null>;
  launchInstance: (id: string) => Promise<boolean>;
  stopGame: () => Promise<boolean>;
  saveSettings: (patch: Partial<LauncherSettings>) => Promise<boolean>;
  setAppearance: (appearance: Appearance) => void;
  toggleTheme: () => void;
  setActiveAccount: (kind: AccountKind, identifier: string) => Promise<boolean>;
  createLocalAccount: (name: string) => Promise<LocalAccount | null>;
  deleteLocalAccount: (name: string) => Promise<boolean>;
  signOutMicrosoft: (id: string) => Promise<boolean>;
  beginMicrosoftLogin: () => Promise<string | null>;
  cancelMicrosoftLogin: () => Promise<void>;
  resetInstallProgress: () => void;
  notifyInstallProgress: (progress: InstallProgress) => void;
  recordGameLog: (event: GameLogEvent) => void;
  gameLogTail: GameLogEvent[];
}

const AppContext = createContext<AppStore | null>(null);

export function AppProvider({ children }: { children: ReactNode }) {
  const [ready, setReady] = useState(false);
  const [bootstrapping, setBootstrapping] = useState(true);
  const [bootError, setBootError] = useState<string | null>(null);
  const [backendOnline, setBackendOnline] = useState(false);
  const [version, setVersion] = useState("—");
  const [platform, setPlatform] = useState("—");
  const [dataRoot, setDataRoot] = useState("");
  const [gameRoot, setGameRoot] = useState("");
  const [settings, setSettings] = useState<LauncherSettings>(() => {
    const stored = localStorage.getItem("lingxi.appearance");
    const appearance: Appearance =
      stored === "light" || stored === "dark" || stored === "system" ? stored : readStoredTheme();
    return { ...DEFAULT_SETTINGS, appearance };
  });
  const [accounts, setAccounts] = useState<AccountSnapshot>({ microsoft: [], local: [] });
  const [activeAccount, setActiveAccount] = useState<ActiveAccount | null>(null);
  const [instances, setInstances] = useState<GameInstance[]>([]);
  const [javaRuntimes, setJavaRuntimes] = useState<JavaRuntime[]>([]);
  const [versions, setVersions] = useState<GameVersion[]>([]);
  const [versionsLoading, setVersionsLoading] = useState(false);
  const [isGameRunning, setIsGameRunning] = useState(false);
  const [gamePid, setGamePid] = useState<number | null>(null);
  const [section, setSectionState] = useState<Section>(() => readStoredSection());
  const [modal, setModal] = useState<AppModal | null>(null);
  const [installedProgress, setInstalledProgress] = useState<InstallProgress | null>(null);
  const [toasts, setToasts] = useState<ToastItem[]>([]);
  const [gameLogTail, setGameLogTail] = useState<GameLogEvent[]>([]);
  const [systemDark, setSystemDark] = useState(() =>
    typeof window.matchMedia === "function" ? window.matchMedia("(prefers-color-scheme: dark)").matches : true,
  );

  const toastId = useRef(0);
  const recentToasts = useRef(new Map<string, number>());
  const bootstrappedOnce = useRef(false);

  const dismissToast = useCallback((id: number) => {
    setToasts((previous) => previous.filter((item) => item.id !== id));
  }, []);

  const toast = useCallback((tone: ToastTone, message: string, detail?: string) => {
    const key = `${tone}:${message}`;
    const now = Date.now();
    const previous = recentToasts.current.get(key);
    if (previous && now - previous < 3500) return;
    recentToasts.current.set(key, now);
    const id = ++toastId.current;
    setToasts((items) => [...items.slice(-3), { id, tone, message, detail }]);
    window.setTimeout(() => {
      setToasts((items) => items.filter((item) => item.id !== id));
    }, 4600);
  }, []);

  const reportError = useCallback(
    (message: string, error: unknown) => {
      toast("error", message, errorText(error));
    },
    [toast],
  );

  const applyBootstrap = useCallback(
    (data: Awaited<ReturnType<typeof api.bootstrap>>) => {
      setVersion(data.version || "—");
      setPlatform(data.platform || "—");
      setDataRoot(data.dataRoot || "");
      setGameRoot(data.gameRoot || "");
      setSettings((previous) => ({
        ...DEFAULT_SETTINGS,
        ...previous,
        ...data.settings,
      }));
      setAccounts(data.accounts);
      setActiveAccount(data.activeAccount ?? null);
      setInstances(data.instances);
      setJavaRuntimes(data.javaRuntimes);
      setIsGameRunning(Boolean(data.isGameRunning));
      setGamePid(typeof data.gamePid === "number" ? data.gamePid : null);
      setBootError(null);
      setBackendOnline(true);
    },
    [],
  );

  const bootstrap = useCallback(async () => {
    setBootstrapping(true);
    try {
      const data = await api.bootstrap();
      applyBootstrap(data);
      bootstrappedOnce.current = true;
    } catch (error) {
      setBackendOnline(false);
      setBootError(errorText(error));
      if (bootstrappedOnce.current) {
        toast("error", "重新连接启动核心失败", errorText(error));
      }
    } finally {
      setBootstrapping(false);
      setReady(true);
    }
  }, [applyBootstrap, toast]);

  useEffect(() => {
    void bootstrap();
  }, [bootstrap]);

  /* Theme resolution + persistence */
  useEffect(() => {
    if (typeof window.matchMedia !== "function") return;
    const query = window.matchMedia("(prefers-color-scheme: dark)");
    const handler = (event: MediaQueryListEvent) => setSystemDark(event.matches);
    query.addEventListener("change", handler);
    return () => query.removeEventListener("change", handler);
  }, []);

  const resolvedTheme: "dark" | "light" =
    settings.appearance === "system" ? (systemDark ? "dark" : "light") : settings.appearance;

  useEffect(() => {
    document.documentElement.dataset.theme = resolvedTheme;
    document.documentElement.style.colorScheme = resolvedTheme;
    localStorage.setItem("lingxi.theme", resolvedTheme);
    localStorage.setItem("lingxi.appearance", settings.appearance);
    const meta = document.querySelector<HTMLMetaElement>('meta[name="theme-color"]');
    if (meta) meta.content = resolvedTheme === "dark" ? "#0D0F12" : "#F4F1EB";
  }, [resolvedTheme, settings.appearance]);

  const setSection = useCallback((next: Section) => {
    setSectionState(next);
    localStorage.setItem("lingxi.section", next);
    window.scrollTo({ top: 0 });
  }, []);

  const openModal = useCallback((next: AppModal) => setModal(next), []);
  const closeModal = useCallback(() => setModal(null), []);

  const refreshInstances = useCallback(
    async (silent = false) => {
      try {
        const next = await api.listInstances();
        setInstances(Array.isArray(next) ? next : []);
      } catch (error) {
        if (!silent) reportError("实例列表刷新失败", error);
      }
    },
    [reportError],
  );

  const refreshAccounts = useCallback(async () => {
    try {
      const [microsoft, local] = await Promise.all([api.listMicrosoftAccounts(), api.listLocalAccounts()]);
      setAccounts({
        microsoft: Array.isArray(microsoft) ? microsoft : [],
        local: Array.isArray(local) ? local : [],
      });
    } catch (error) {
      reportError("账户列表刷新失败", error);
    }
  }, [reportError]);

  const refreshVersions = useCallback(
    async (filter: VersionFilter = "all", silent = false) => {
      setVersionsLoading(true);
      try {
        const next = await api.listVersions(filter);
        setVersions(Array.isArray(next) ? next : []);
      } catch (error) {
        if (!silent) reportError("版本列表加载失败", error);
      } finally {
        setVersionsLoading(false);
      }
    },
    [reportError],
  );

  const refreshGameStatus = useCallback(async () => {
    try {
      const status = await api.gameStatus();
      setIsGameRunning(Boolean(status.running));
      setGamePid(typeof status.pid === "number" ? status.pid : null);
    } catch {
      /* status is polled opportunistically; a missing command is not fatal */
    }
  }, []);

  /* Tauri events */
  useEffect(() => {
    let cancelled = false;
    const unlisten: Array<() => void> = [];

    async function register<T>(promise: Promise<T>, push: (value: T) => void) {
      try {
        const value = await promise;
        if (cancelled) {
          if (typeof value === "function") (value as () => void)();
          return;
        }
        push(value);
      } catch {
        /* Events are unavailable outside Tauri; commands still work when run in the app. */
      }
    }

    void register(onInstallProgress((progress) => setInstalledProgress(progress)), (fn) => unlisten.push(fn));

    void register(
      onGameExited((exit) => {
        setIsGameRunning(false);
        setGamePid(null);
        void api.listInstances().then(setInstances).catch(() => undefined);
        if (exit.code && exit.code !== 0) {
          toast("error", `游戏异常退出（代码 ${exit.code}）`, exit.message ?? undefined);
        } else {
          toast("info", "游戏已退出", exit.message ?? undefined);
        }
      }),
      (fn) => unlisten.push(fn),
    );

    void register(
      onAuthChanged(() => {
        void api
          .bootstrap()
          .then((data) => {
            setAccounts(data.accounts);
            setActiveAccount(data.activeAccount ?? null);
            setJavaRuntimes(data.javaRuntimes);
          })
          .catch(() => undefined);
      }),
      (fn) => unlisten.push(fn),
    );

    return () => {
      cancelled = true;
      for (const dispose of unlisten) dispose();
    };
  }, [toast]);

  /* Keep the install progress fresh when a new wizard starts. */
  const resetInstallProgress = useCallback(() => setInstalledProgress(null), []);
  const notifyInstallProgress = useCallback((progress: InstallProgress) => setInstalledProgress(progress), []);
  const recordGameLog = useCallback((event: GameLogEvent) => {
    if (!event.line) return;
    setGameLogTail((previous) => [...previous.slice(-199), event]);
  }, []);

  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | null = null;
    void onGameLog(recordGameLog)
      .then((fn) => {
        if (disposed) fn();
        else unlisten = fn;
      })
      .catch(() => undefined);
    return () => {
      disposed = true;
      unlisten?.();
    };
  }, [recordGameLog]);

  const activeProfile = useMemo<ActiveProfile | null>(() => {
    if (!activeAccount) return null;
    if (activeAccount.kind === "microsoft") {
      const account =
        accounts.microsoft.find((item) => item.id === activeAccount.identifier) ??
        accounts.microsoft.find((item) => item.playerName === activeAccount.identifier) ??
        null;
      return {
        kind: "microsoft",
        identifier: activeAccount.identifier,
        name: account?.playerName ?? activeAccount.identifier,
        skinUrl: account?.skinTextureUrl ?? account?.skinTextureURL ?? null,
        microsoft: account,
        local: null,
      };
    }
    const local =
      accounts.local.find((item) => item.name === activeAccount.identifier) ?? null;
    return {
      kind: "local",
      identifier: activeAccount.identifier,
      name: local?.name ?? activeAccount.identifier,
      skinUrl: null,
      microsoft: null,
      local,
    };
  }, [activeAccount, accounts]);

  const createInstance = useCallback(
    async (name: string, versionId: string) => {
      try {
        const instance = await api.createInstance(name, versionId);
        await refreshInstances(true);
        toast("success", `实例「${name}」已创建`);
        return instance;
      } catch (error) {
        reportError("创建实例失败", error);
        return null;
      }
    },
    [refreshInstances, reportError, toast],
  );

  const updateInstance = useCallback(
    async (id: string, patch: { memoryMiB?: number; jvmArguments?: string }) => {
      try {
        await api.updateInstance(id, patch);
        await refreshInstances(true);
        toast("success", "实例设置已更新");
        return true;
      } catch (error) {
        reportError("更新实例失败", error);
        return false;
      }
    },
    [refreshInstances, reportError, toast],
  );

  const deleteInstance = useCallback(
    async (id: string) => {
      try {
        await api.deleteInstance(id);
        setInstances((previous) => previous.filter((item) => item.id !== id));
        toast("success", "实例已删除");
        return true;
      } catch (error) {
        reportError("删除实例失败", error);
        return false;
      }
    },
    [reportError, toast],
  );

  const copyInstance = useCallback(
    async (id: string) => {
      try {
        const instance = await api.copyInstance(id, "副本");
        await refreshInstances(true);
        toast("success", "实例副本已创建");
        return instance;
      } catch (error) {
        reportError("复制实例失败", error);
        return null;
      }
    },
    [refreshInstances, reportError, toast],
  );

  const launchInstance = useCallback(
    async (id: string) => {
      try {
        await api.launchInstance(id);
        setIsGameRunning(true);
        await refreshGameStatus();
        toast("success", "游戏启动指令已发送");
        return true;
      } catch (error) {
        reportError("启动游戏失败", error);
        return false;
      }
    },
    [refreshGameStatus, reportError, toast],
  );

  const stopGame = useCallback(async () => {
    try {
      await api.stopGame();
      await refreshGameStatus();
      toast("info", "已请求停止游戏");
      return true;
    } catch (error) {
      reportError("停止游戏失败", error);
      return false;
    }
  }, [refreshGameStatus, reportError, toast]);

  const saveSettings = useCallback(
    async (patch: Partial<LauncherSettings>) => {
      try {
        await api.saveSettings(patch);
        setSettings((previous) => ({ ...previous, ...patch }));
        toast("success", "设置已保存");
        return true;
      } catch (error) {
        reportError("设置保存失败", error);
        return false;
      }
    },
    [reportError, toast],
  );

  const setAppearance = useCallback(
    (appearance: Appearance) => {
      setSettings((previous) => ({ ...previous, appearance }));
      void api.saveSettings({ appearance }).catch((error) => {
        toast("error", "外观已切换，但未能保存到启动核心", errorText(error));
      });
    },
    [toast],
  );

  const toggleTheme = useCallback(() => {
    setAppearance(resolvedTheme === "dark" ? "light" : "dark");
  }, [resolvedTheme, setAppearance]);

  const setActiveAccountAction = useCallback(
    async (kind: AccountKind, identifier: string) => {
      try {
        await api.setActiveAccount(kind, identifier);
        setActiveAccount({ kind, identifier });
        toast("success", "当前账户已切换");
        return true;
      } catch (error) {
        reportError("切换账户失败", error);
        return false;
      }
    },
    [reportError, toast],
  );

  const createLocalAccount = useCallback(
    async (name: string) => {
      try {
        const account = await api.createLocalAccount(name);
        await refreshAccounts();
        toast("success", `离线账户「${name}」已创建`);
        return account;
      } catch (error) {
        reportError("创建离线账户失败", error);
        return null;
      }
    },
    [refreshAccounts, reportError, toast],
  );

  const deleteLocalAccount = useCallback(
    async (name: string) => {
      try {
        await api.deleteLocalAccount(name);
        await refreshAccounts();
        toast("success", "离线账户已删除");
        return true;
      } catch (error) {
        reportError("删除离线账户失败", error);
        return false;
      }
    },
    [refreshAccounts, reportError, toast],
  );

  const signOutMicrosoft = useCallback(
    async (id: string) => {
      try {
        await api.signOutMicrosoft(id);
        await refreshAccounts();
        toast("success", "Microsoft 账户已退出");
        return true;
      } catch (error) {
        reportError("退出 Microsoft 账户失败", error);
        return false;
      }
    },
    [refreshAccounts, reportError, toast],
  );

  const beginMicrosoftLogin = useCallback(async () => {
    try {
      const result = await api.beginMicrosoftLogin();
      return result?.url ?? null;
    } catch (error) {
      reportError("无法开始 Microsoft 登录", error);
      return null;
    }
  }, [reportError]);

  const cancelMicrosoftLogin = useCallback(async () => {
    try {
      await api.cancelMicrosoftLogin();
    } catch (error) {
      reportError("取消登录失败", error);
    }
  }, [reportError]);

  const dismissBootError = useCallback(() => setBootError(null), []);

  const value: AppStore = {
    ready,
    bootstrapping,
    bootError,
    backendOnline,
    version,
    platform,
    dataRoot,
    gameRoot,
    settings,
    accounts,
    activeAccount,
    activeProfile,
    instances,
    javaRuntimes,
    versions,
    versionsLoading,
    isGameRunning,
    gamePid,
    section,
    modal,
    installedProgress,
    resolvedTheme,
    toasts,
    setSection,
    openModal,
    closeModal,
    toast,
    dismissToast,
    bootstrap,
    dismissBootError,
    refreshInstances,
    refreshAccounts,
    refreshVersions,
    refreshGameStatus,
    createInstance,
    updateInstance,
    deleteInstance,
    copyInstance,
    launchInstance,
    stopGame,
    saveSettings,
    setAppearance,
    toggleTheme,
    setActiveAccount: setActiveAccountAction,
    createLocalAccount,
    deleteLocalAccount,
    signOutMicrosoft,
    beginMicrosoftLogin,
    cancelMicrosoftLogin,
    resetInstallProgress,
    notifyInstallProgress,
    recordGameLog,
    gameLogTail,
  };

  return <AppContext.Provider value={value}>{children}</AppContext.Provider>;
}

export function useApp(): AppStore {
  const store = useContext(AppContext);
  if (!store) throw new Error("useApp must be used inside AppProvider");
  return store;
}
