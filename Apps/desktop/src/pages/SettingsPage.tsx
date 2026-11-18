import { useEffect, useMemo, useState } from "react";
import { Badge } from "../components/Badge";
import { Button } from "../components/Button";
import { Card, SectionHeader } from "../components/Card";
import { ErrorBanner } from "../components/ErrorBanner";
import { Icon, type IconName } from "../components/Icons";
import { Switch, TextInput } from "../components/Input";
import { PageHeader } from "../components/PageHeader";
import { Select } from "../components/Select";
import {
  api,
  type AccentColor,
  type Appearance,
  type DownloadSource,
  type JavaRuntime,
  type Language,
  type LauncherSettings,
  type ProxyMode,
  type UpdateInfo,
} from "../services/api";
import { useApp } from "../stores/app";
import { formatMemory } from "../lib/format";

const appearanceOptions: Array<{ value: Appearance; title: string; description: string; icon: IconName }> = [
  { value: "dark", title: "深色", description: "夜色与暖橙，默认外观", icon: "moon" },
  { value: "light", title: "浅色", description: "米白纸张质感", icon: "sun" },
  { value: "system", title: "跟随系统", description: "随 macOS / Windows 主题切换", icon: "monitor" },
];

const accentOptions: Array<{ value: AccentColor; label: string; color: string }> = [
  { value: "orange", label: "暖橙", color: "#f29a5f" },
  { value: "blue", label: "天青", color: "#6fa8f2" },
  { value: "green", label: "苔绿", color: "#7fd2a4" },
  { value: "purple", label: "紫藤", color: "#b193f0" },
  { value: "pink", label: "绯樱", color: "#f093b9" },
  { value: "red", label: "丹砂", color: "#ef8d84" },
];

const sourceOptions: Array<{ value: DownloadSource; label: string }> = [
  { value: "auto", label: "自动选择（推荐）" },
  { value: "official", label: "官方源" },
  { value: "mirror", label: "镜像源" },
  { value: "local-cache-only", label: "仅本地缓存" },
];

const proxyOptions: Array<{ value: ProxyMode; label: string }> = [
  { value: "system", label: "跟随系统（环境变量与系统代理）" },
  { value: "manual", label: "手动指定" },
  { value: "off", label: "不使用代理" },
];

const languageOptions: Array<{ value: Language; label: string }> = [
  { value: "zh-CN", label: "简体中文" },
  { value: "en-US", label: "English（预览）" },
];

const memoryPresets = [2048, 4096, 6144, 8192, 12288];

type SettingsTab = "game" | "launcher" | "about";

const tabs: Array<{ value: SettingsTab; label: string; hint: string }> = [
  { value: "game", label: "游戏", hint: "全局游戏设置与 Java" },
  { value: "launcher", label: "启动器", hint: "通用、外观与下载" },
  { value: "about", label: "关于", hint: "版本与更新" },
];

const repositoryUrl = "https://github.com/LingXiFox/LingXiLauncher";

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function sameSettings(left: LauncherSettings, right: LauncherSettings): boolean {
  return (
    (left.javaPath ?? "") === (right.javaPath ?? "") &&
    left.source === right.source &&
    (left.mirrorConfigPath ?? "") === (right.mirrorConfigPath ?? "") &&
    left.defaultMemoryMiB === right.defaultMemoryMiB &&
    left.appearance === right.appearance &&
    left.language === right.language &&
    left.accent === right.accent &&
    (left.backgroundImage ?? "") === (right.backgroundImage ?? "") &&
    left.proxyMode === right.proxyMode &&
    (left.proxyUrl ?? "") === (right.proxyUrl ?? "") &&
    (left.gameRoot ?? "") === (right.gameRoot ?? "") &&
    left.logWindowOnStart === right.logWindowOnStart
  );
}

export function SettingsPage() {
  const {
    settings,
    saveSettings,
    setAppearance,
    javaRuntimes,
    version,
    platform,
    dataRoot,
    gameRoot,
    toast,
  } = useApp();

  const [tab, setTab] = useState<SettingsTab>("game");
  const [draft, setDraft] = useState<LauncherSettings>(settings);
  const [detected, setDetected] = useState<JavaRuntime[]>(javaRuntimes);
  const [detecting, setDetecting] = useState(false);
  const [saving, setSaving] = useState(false);
  const [browsing, setBrowsing] = useState(false);
  const [picking, setPicking] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [memoryText, setMemoryText] = useState(String(settings.defaultMemoryMiB));
  const [checking, setChecking] = useState(false);
  const [update, setUpdate] = useState<UpdateInfo | null>(null);
  const [updateError, setUpdateError] = useState<string | null>(null);

  useEffect(() => {
    setDraft(settings);
    setMemoryText(String(settings.defaultMemoryMiB));
  }, [settings]);

  useEffect(() => {
    setDetected(javaRuntimes);
  }, [javaRuntimes]);

  const dirty = useMemo(() => !sameSettings(draft, settings), [draft, settings]);

  const selectedRuntime = useMemo(() => {
    if (!draft.javaPath) return null;
    return detected.find((runtime) => runtime.path === draft.javaPath) ?? null;
  }, [detected, draft.javaPath]);

  function updateDraft(patch: Partial<LauncherSettings>) {
    setDraft((previous) => ({ ...previous, ...patch }));
    setError(null);
  }

  function commitMemory(value: number) {
    const clamped = Math.max(512, Math.min(65536, Math.round(value / 256) * 256));
    updateDraft({ defaultMemoryMiB: clamped });
    setMemoryText(String(clamped));
  }

  async function handleDetect() {
    setDetecting(true);
    setError(null);
    try {
      const runtimes = await api.detectJava();
      setDetected(Array.isArray(runtimes) ? runtimes : []);
      toast("success", "Java 检测完成", `发现 ${runtimes.length} 个可用运行时`);
    } catch (reason) {
      setError(`Java 检测失败：${errorText(reason)}`);
    } finally {
      setDetecting(false);
    }
  }

  async function handleBrowse() {
    setBrowsing(true);
    setError(null);
    try {
      const path = await api.browseJava();
      if (!path) return;
      updateDraft({ javaPath: path });
      if (!detected.some((runtime) => runtime.path === path)) {
        setDetected((previous) => [
          { path, version: "手动选择", vendor: "自定义", architecture: null, majorVersion: null },
          ...previous,
        ]);
      }
    } catch (reason) {
      setError(`选择 Java 失败：${errorText(reason)}`);
    } finally {
      setBrowsing(false);
    }
  }

  async function handlePickFolder(field: "gameRoot") {
    setPicking(true);
    setError(null);
    try {
      const path = await api.browseFolder();
      if (path) updateDraft({ [field]: path } as Partial<LauncherSettings>);
    } catch (reason) {
      setError(`选择目录失败：${errorText(reason)}`);
    } finally {
      setPicking(false);
    }
  }

  async function handlePickBackground() {
    setPicking(true);
    setError(null);
    try {
      const path = await api.browseFolder();
      if (path) updateDraft({ backgroundImage: path });
    } catch (reason) {
      setError(`选择背景图片失败：${errorText(reason)}`);
    } finally {
      setPicking(false);
    }
  }

  async function handleSave() {
    const parsed = Number(memoryText);
    if (!Number.isFinite(parsed) || parsed < 512 || parsed > 65536) {
      setError("默认内存需在 512 MiB 到 65536 MiB 之间。");
      setTab("game");
      return;
    }
    if (draft.proxyMode === "manual" && !/^(https?|socks5):\/\//.test((draft.proxyUrl ?? "").trim())) {
      setError("手动代理需要形如 http://127.0.0.1:7890 的地址。");
      setTab("launcher");
      return;
    }
    setSaving(true);
    setError(null);
    const before = settings;
    /* Rust sees an explicit null as "leave unchanged", so cleared paths are sent
       as empty strings to actually unset them. */
    const ok = await saveSettings({
      ...draft,
      javaPath: draft.javaPath ?? "",
      mirrorConfigPath: draft.mirrorConfigPath ?? "",
      backgroundImage: draft.backgroundImage ?? "",
      proxyUrl: draft.proxyUrl ?? "",
      gameRoot: draft.gameRoot ?? "",
      defaultMemoryMiB: parsed,
    });
    setSaving(false);
    if (!ok) return;
    setDraft((previous) => ({ ...previous, defaultMemoryMiB: parsed }));
    setMemoryText(String(parsed));
    if ((before.gameRoot ?? "") !== (draft.gameRoot ?? "")) {
      toast("info", "Minecraft 目录已更新", "重新启动启动器后生效");
    }
  }

  async function handleReveal(path: string) {
    try {
      await api.revealPath(path);
    } catch (reason) {
      toast("error", "无法打开目录", errorText(reason));
    }
  }

  function handleAppearance(appearance: Appearance) {
    updateDraft({ appearance });
    setAppearance(appearance);
  }

  function handleAccent(accent: AccentColor) {
    updateDraft({ accent });
    /* The accent is a pure CSS token swap, so preview it right away. */
    document.documentElement.dataset.accent = accent;
  }

  async function handleCheckUpdate() {
    setChecking(true);
    setUpdateError(null);
    try {
      const info = await api.checkUpdate();
      setUpdate(info);
      if (info.available) {
        toast("info", "发现新版本", `${info.latestVersion}（当前 ${info.currentVersion}）`);
      } else {
        toast("success", "已是最新版本", `当前 ${info.currentVersion}`);
      }
    } catch (reason) {
      setUpdateError(errorText(reason));
    } finally {
      setChecking(false);
    }
  }

  async function handleOpen(url: string) {
    try {
      await api.openExternal(url);
    } catch (reason) {
      toast("error", "无法打开链接", errorText(reason));
    }
  }

  async function handleRestart() {
    try {
      await api.restartApp();
    } catch (reason) {
      toast("error", "重启失败", errorText(reason));
    }
  }

  return (
    <>
      <PageHeader
        eyebrow="Preferences / 系统"
        title="设置"
        subtitle="游戏、启动器与下载各自成栏；所有修改会写入启动核心的配置文件。"
        actions={
          <>
            {dirty ? <Badge tone="warning" dot>有未保存的修改</Badge> : null}
            <Button variant="primary" icon="save" loading={saving} disabled={!dirty || saving} onClick={() => void handleSave()}>
              保存设置
            </Button>
          </>
        }
      />

      <div className="page-stack settings-page">
        {error ? <ErrorBanner message={error} onDismiss={() => setError(null)} /> : null}

        <div className="tabs settings-tabs" role="tablist" aria-label="设置分类">
          {tabs.map((item) => (
            <button
              key={item.value}
              type="button"
              role="tab"
              aria-selected={tab === item.value}
              className={`tab ${tab === item.value ? "is-active" : ""}`}
              title={item.hint}
              onClick={() => setTab(item.value)}
            >
              {item.label}
            </button>
          ))}
        </div>

        {tab === "game" ? (
          <div className="settings-layout">
            <div className="settings-column">
              <Card className="settings-card">
                <SectionHeader title="全局游戏设置" caption="这些值作为新实例的默认值，已有实例可在实例工具中单独覆盖。" />
                <div className="settings-form">
                  <div className="memory-field">
                    <div className="memory-field__head">
                      <div>
                        <p className="field__label">默认内存分配</p>
                        <p className="memory-field__value">{formatMemory(Number(memoryText) || 0)}</p>
                      </div>
                      <input
                        className="memory-field__range"
                        type="range"
                        min={512}
                        max={16384}
                        step={256}
                        value={Math.min(16384, Math.max(512, Number(memoryText) || 4096))}
                        onChange={(event) => commitMemory(Number(event.target.value))}
                        aria-label="默认内存分配"
                      />
                    </div>
                    <div className="memory-field__row">
                      <TextInput
                        label="精确数值（MiB）"
                        type="number"
                        min={512}
                        max={65536}
                        step={256}
                        value={memoryText}
                        onChange={(event) => {
                          setMemoryText(event.target.value);
                          const value = Number(event.target.value);
                          if (Number.isFinite(value) && value >= 512 && value <= 65536) {
                            setDraft((previous) => ({ ...previous, defaultMemoryMiB: Math.round(value) }));
                          }
                        }}
                        hint="允许 512 – 65536 MiB；留空则在每个实例使用自动值（物理内存的 1/4，限制在 2 – 8 GiB）。"
                      />
                      <div className="memory-presets" role="group" aria-label="内存预设">
                        {memoryPresets.map((value) => (
                          <button
                            key={value}
                            type="button"
                            className={`memory-preset ${Number(memoryText) === value ? "is-active" : ""}`}
                            onClick={() => commitMemory(value)}
                          >
                            {value >= 1024 ? `${value / 1024} GB` : `${value} MB`}
                          </button>
                        ))}
                      </div>
                    </div>
                  </div>

                  <div className="field">
                    <p className="field__label">Minecraft 目录</p>
                    <div className="path-picker">
                      <span className="path-picker__value mono truncate">{draft.gameRoot || gameRoot || "使用启动器探测到的目录"}</span>
                      <Button size="sm" variant="secondary" icon="folder" loading={picking} onClick={() => void handlePickFolder("gameRoot")}>
                        选择
                      </Button>
                      {draft.gameRoot ? (
                        <Button size="sm" variant="ghost" onClick={() => updateDraft({ gameRoot: null })}>
                          恢复默认
                        </Button>
                      ) : null}
                    </div>
                    <p className="field__message">
                      存放 versions / libraries / assets 的共享游戏目录；实例、账户与设置仍留在启动器数据目录。修改后需重启启动器生效。
                    </p>
                  </div>
                </div>
              </Card>

              <Card className="settings-card">
                <SectionHeader
                  title="Java 运行环境"
                  caption="未指定时将自动选择与游戏版本匹配的 Java；也可固定使用某个运行时。"
                  action={
                    <Button size="sm" variant="secondary" icon="refresh" loading={detecting} onClick={() => void handleDetect()}>
                      重新检测
                    </Button>
                  }
                />

                <div className="settings-runtime">
                  <div className="settings-runtime__current">
                    <span className="settings-runtime__icon" aria-hidden="true">
                      <Icon name="coffee" size={20} />
                    </span>
                    <div className="settings-runtime__copy">
                      <p className="settings-runtime__title">
                        {draft.javaPath ? selectedRuntime?.version ?? "自定义运行时" : "自动选择"}
                        {selectedRuntime?.majorVersion ? <Badge tone="accent">Java {selectedRuntime.majorVersion}</Badge> : null}
                      </p>
                      <p className="settings-runtime__path mono">{draft.javaPath ?? "由启动器按 Minecraft 版本自动匹配"}</p>
                    </div>
                    <div className="settings-runtime__actions">
                      <Button size="sm" variant="secondary" icon="folder" loading={browsing} onClick={() => void handleBrowse()}>
                        选择
                      </Button>
                      {draft.javaPath ? (
                        <Button size="sm" variant="ghost" onClick={() => updateDraft({ javaPath: null })}>
                          改回自动
                        </Button>
                      ) : null}
                    </div>
                  </div>

                  <div className="runtime-list" role="list" aria-label="已检测的 Java 运行时">
                    <button
                      type="button"
                      role="listitem"
                      className={`runtime-row ${!draft.javaPath ? "is-selected" : ""}`}
                      onClick={() => updateDraft({ javaPath: null })}
                    >
                      <span className="runtime-row__radio" aria-hidden="true" />
                      <span className="runtime-row__copy">
                        <span className="runtime-row__title">自动选择</span>
                        <span className="runtime-row__meta">按游戏版本选择需要的 Java 主版本</span>
                      </span>
                      <Badge tone="neutral">默认</Badge>
                    </button>
                    {detected.length === 0 ? (
                      <div className="runtime-list__empty">尚未检测到 Java 运行时，点击「重新检测」或手动选择。</div>
                    ) : (
                      detected.map((runtime) => (
                        <button
                          key={`${runtime.path}-${runtime.version}`}
                          type="button"
                          role="listitem"
                          className={`runtime-row ${draft.javaPath === runtime.path ? "is-selected" : ""}`}
                          onClick={() => updateDraft({ javaPath: runtime.path })}
                        >
                          <span className="runtime-row__radio" aria-hidden="true" />
                          <span className="runtime-row__copy">
                            <span className="runtime-row__title">
                              {runtime.version}
                              {runtime.majorVersion ? <span className="runtime-row__major">Java {runtime.majorVersion}</span> : null}
                            </span>
                            <span className="runtime-row__meta truncate">
                              {[runtime.vendor, runtime.architecture, runtime.path].filter(Boolean).join(" · ")}
                            </span>
                          </span>
                          {draft.javaPath === runtime.path ? <Badge tone="accent">使用中</Badge> : null}
                        </button>
                      ))
                    )}
                  </div>
                </div>
              </Card>
            </div>

            <aside className="settings-aside">
              <Card className="settings-card settings-card--compact">
                <SectionHeader title="存储位置" caption="启动器与游戏数据目录" />
                <div className="settings-paths">
                  <div className="settings-path">
                    <span className="settings-path__label">启动器数据</span>
                    <span className="settings-path__value mono">{dataRoot || "—"}</span>
                    <Button size="sm" variant="ghost" icon="external" disabled={!dataRoot} onClick={() => void handleReveal(dataRoot)}>
                      打开
                    </Button>
                  </div>
                  <div className="settings-path">
                    <span className="settings-path__label">游戏目录</span>
                    <span className="settings-path__value mono">{gameRoot || "—"}</span>
                    <Button size="sm" variant="ghost" icon="external" disabled={!gameRoot} onClick={() => void handleReveal(gameRoot)}>
                      打开
                    </Button>
                  </div>
                </div>
              </Card>

              <Card className="settings-card settings-card--compact">
                <SectionHeader title="运行信息" caption="当前启动核心" />
                <dl className="settings-facts">
                  <div>
                    <dt>版本</dt>
                    <dd>v{version.replace(/^v/i, "")}</dd>
                  </div>
                  <div>
                    <dt>平台</dt>
                    <dd>{platform}</dd>
                  </div>
                  <div>
                    <dt>Java 运行时</dt>
                    <dd>{detected.length} 个</dd>
                  </div>
                  <div>
                    <dt>当前主题</dt>
                    <dd>{appearanceOptions.find((option) => option.value === draft.appearance)?.title ?? "深色"}</dd>
                  </div>
                </dl>
              </Card>
            </aside>
          </div>
        ) : null}

        {tab === "launcher" ? (
          <div className="settings-layout">
            <div className="settings-column">
              <Card className="settings-card">
                <SectionHeader title="通用" caption="影响启动器自身的行为。" />
                <div className="settings-form">
                  <div className="grid grid--2">
                    <Select
                      label="界面语言"
                      value={draft.language}
                      onChange={(value) => updateDraft({ language: value as Language })}
                      options={languageOptions}
                      hint="英文界面仍在逐页补齐，切换后部分文案仍显示中文。"
                    />
                    <Select
                      label="下载源"
                      value={draft.source}
                      onChange={(value) => updateDraft({ source: value as DownloadSource })}
                      options={sourceOptions}
                      hint="自动模式优先官方源，仅在已配置镜像时回退到镜像。"
                    />
                  </div>
                  <div className="settings-switches">
                    <Switch
                      checked={draft.logWindowOnStart}
                      onChange={(checked) => updateDraft({ logWindowOnStart: checked })}
                      label="启动时打开日志窗口"
                      description="把运行日志放到独立窗口，主界面不再占用导航栏。"
                    />
                  </div>
                </div>
              </Card>

              <Card className="settings-card">
                <SectionHeader title="外观" caption="主题与配色会立即生效，并同步到启动器配置。" />
                <div className="appearance-grid" role="radiogroup" aria-label="外观主题">
                  {appearanceOptions.map((option) => (
                    <button
                      key={option.value}
                      type="button"
                      role="radio"
                      aria-checked={draft.appearance === option.value}
                      className={`appearance-option ${draft.appearance === option.value ? "is-selected" : ""}`}
                      onClick={() => handleAppearance(option.value)}
                    >
                      <span className="appearance-option__preview" data-variant={option.value} aria-hidden="true">
                        <span className="appearance-option__sidebar" />
                        <span className="appearance-option__body">
                          <span />
                          <span />
                        </span>
                      </span>
                      <span className="appearance-option__copy">
                        <span className="appearance-option__title">
                          <Icon name={option.icon} size={14} />
                          {option.title}
                        </span>
                        <span className="appearance-option__description">{option.description}</span>
                      </span>
                      {draft.appearance === option.value ? (
                        <span className="appearance-option__check" aria-hidden="true">
                          <Icon name="check" size={12} />
                        </span>
                      ) : null}
                    </button>
                  ))}
                </div>

                <div className="settings-form settings-form--stacked">
                  <div className="field">
                    <p className="field__label">强调色</p>
                    <div className="accent-grid" role="radiogroup" aria-label="强调色">
                      {accentOptions.map((option) => (
                        <button
                          key={option.value}
                          type="button"
                          role="radio"
                          aria-checked={draft.accent === option.value}
                          aria-label={option.label}
                          title={option.label}
                          className={`accent-swatch ${draft.accent === option.value ? "is-selected" : ""}`}
                          style={{ ["--swatch" as string]: option.color }}
                          onClick={() => handleAccent(option.value)}
                        >
                          <span className="accent-swatch__dot" aria-hidden="true" />
                          <span className="accent-swatch__label">{option.label}</span>
                        </button>
                      ))}
                    </div>
                  </div>

                  <div className="field">
                    <p className="field__label">背景图片</p>
                    <div className="path-picker">
                      <span className="path-picker__value mono truncate">
                        {draft.backgroundImage || "未设置：使用主题默认的渐变背景"}
                      </span>
                      <Button size="sm" variant="secondary" icon="image" loading={picking} onClick={() => void handlePickBackground()}>
                        选择
                      </Button>
                      {draft.backgroundImage ? (
                        <Button size="sm" variant="ghost" onClick={() => updateDraft({ backgroundImage: null })}>
                          清除
                        </Button>
                      ) : null}
                    </div>
                    <p className="field__message">支持本地 PNG / JPG / WebP；图片会以低不透明度铺在主界面背景上。</p>
                  </div>
                </div>
              </Card>

              <Card className="settings-card">
                <SectionHeader title="下载" caption="下载源、镜像与网络代理；对所有版本、模组与 Java 下载生效。" />
                <div className="settings-form">
                  <TextInput
                    label="镜像配置路径"
                    value={draft.mirrorConfigPath ?? ""}
                    onChange={(event) => updateDraft({ mirrorConfigPath: event.target.value || null })}
                    placeholder="可选：mirror.json 的绝对路径"
                    leadingIcon="folder"
                    hint="可选：配置后自动/镜像模式才会使用第三方镜像源。"
                  />
                  <div className="grid grid--2">
                    <Select
                      label="代理模式"
                      value={draft.proxyMode}
                      onChange={(value) => updateDraft({ proxyMode: value as ProxyMode })}
                      options={proxyOptions}
                      hint="跟随系统会读取 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY。"
                    />
                    <TextInput
                      label="代理地址"
                      value={draft.proxyUrl ?? ""}
                      onChange={(event) => updateDraft({ proxyUrl: event.target.value || null })}
                      placeholder="http://127.0.0.1:7890"
                      disabled={draft.proxyMode !== "manual"}
                      hint={draft.proxyMode === "manual" ? "支持 http:// 与 socks5://。" : "仅在「手动指定」模式下使用。"}
                    />
                  </div>
                </div>
              </Card>
            </div>

            <aside className="settings-aside">
              <Card className="settings-card settings-card--compact">
                <SectionHeader title="配置提示" caption="写入位置" />
                <div className="settings-tip">
                  <span className="settings-tip__icon" aria-hidden="true">
                    <Icon name="info" size={16} />
                  </span>
                  <div>
                    <p className="settings-tip__title">保存到哪里？</p>
                    <p className="settings-tip__body">
                      设置写入数据目录下的 <span className="mono">settings.json</span>，不会改动实例内的文件。实例级窗口与 Java
                      参数可在实例工具中覆盖。
                    </p>
                  </div>
                </div>
              </Card>
            </aside>
          </div>
        ) : null}

        {tab === "about" ? (
          <div className="settings-layout">
            <div className="settings-column">
              <Card className="settings-card">
                <SectionHeader title="灵曦启动器" caption="LingXi Launcher" />
                <div className="about-hero">
                  <div className="about-hero__mark" aria-hidden="true">
                    <Icon name="sparkles" size={26} />
                  </div>
                  <div className="about-hero__copy">
                    <p className="about-hero__title">v{version.replace(/^v/i, "")}</p>
                    <p className="about-hero__subtitle">Rust 启动核心 · Tauri 2 桌面壳 · React 界面</p>
                  </div>
                </div>
                <dl className="settings-facts">
                  <div>
                    <dt>平台</dt>
                    <dd>{platform}</dd>
                  </div>
                  <div>
                    <dt>数据目录</dt>
                    <dd className="mono">{dataRoot || "—"}</dd>
                  </div>
                  <div>
                    <dt>游戏目录</dt>
                    <dd className="mono">{gameRoot || "—"}</dd>
                  </div>
                </dl>
                <div className="about-actions">
                  <Button variant="secondary" icon="external" onClick={() => void handleOpen(repositoryUrl)}>
                    项目主页
                  </Button>
                  <Button
                    variant="secondary"
                    icon="file"
                    onClick={() => void handleOpen(`${repositoryUrl}/releases`)}
                  >
                    全部版本
                  </Button>
                  <Button variant="ghost" icon="refresh" onClick={() => void handleRestart()}>
                    重启启动器
                  </Button>
                </div>
              </Card>

              <Card className="settings-card">
                <SectionHeader
                  title="更新"
                  caption="从 GitHub Releases 检查最新版本。"
                  action={
                    <Button size="sm" variant="secondary" icon="download" loading={checking} onClick={() => void handleCheckUpdate()}>
                      检查更新
                    </Button>
                  }
                />
                {updateError ? <ErrorBanner message={updateError} title="检查更新失败" onDismiss={() => setUpdateError(null)} /> : null}
                {update ? (
                  <div className="update-card">
                    <div className="update-card__head">
                      <div>
                        <p className="update-card__version">
                          {update.available ? `新版本 ${update.latestVersion}` : "已是最新版本"}
                        </p>
                        <p className="update-card__meta">
                          当前 {update.currentVersion}
                          {update.publishedAt ? ` · 发布于 ${update.publishedAt}` : ""}
                        </p>
                      </div>
                      <Badge tone={update.available ? "accent" : "success"} dot>
                        {update.available ? "可更新" : "最新"}
                      </Badge>
                    </div>
                    {update.releaseNotes ? (
                      <pre className="update-card__notes">{update.releaseNotes.slice(0, 1200)}</pre>
                    ) : null}
                    <div className="about-actions">
                      <Button variant="primary" icon="external" onClick={() => void handleOpen(update.releaseUrl)}>
                        打开下载页面
                      </Button>
                    </div>
                    <p className="field__message">自动下载与静默安装尚未接入；当前版本会打开 Release 页面由你手动安装。</p>
                  </div>
                ) : (
                  <p className="field__message">尚未检查更新。点击右上角「检查更新」从 GitHub 拉取最新发布。</p>
                )}
              </Card>
            </div>

            <aside className="settings-aside">
              <Card className="settings-card settings-card--compact">
                <SectionHeader title="致谢" caption="开源与社区" />
                <p className="settings-tip__body">
                  启动核心基于 Rust 与 tokio 构建，界面使用 React 18；版本清单来自 Mojang 官方 Piston 元数据，模组检索来自 Modrinth。
                </p>
              </Card>
            </aside>
          </div>
        ) : null}
      </div>
    </>
  );
}
