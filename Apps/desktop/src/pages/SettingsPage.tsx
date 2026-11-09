import { useEffect, useMemo, useState } from "react";
import { Badge } from "../components/Badge";
import { Button } from "../components/Button";
import { Card, SectionHeader } from "../components/Card";
import { ErrorBanner } from "../components/ErrorBanner";
import { Icon, type IconName } from "../components/Icons";
import { TextInput } from "../components/Input";
import { PageHeader } from "../components/PageHeader";
import { Select } from "../components/Select";
import { api, type Appearance, type DownloadSource, type JavaRuntime, type LauncherSettings } from "../services/api";
import { useApp } from "../stores/app";
import { formatMemory } from "../lib/format";

const appearanceOptions: Array<{ value: Appearance; title: string; description: string; icon: IconName }> = [
  { value: "dark", title: "深色", description: "夜色与暖橙，默认外观", icon: "moon" },
  { value: "light", title: "浅色", description: "米白纸张质感", icon: "sun" },
  { value: "system", title: "跟随系统", description: "随 macOS / Windows 主题切换", icon: "monitor" },
];

const sourceOptions: Array<{ value: DownloadSource; label: string }> = [
  { value: "auto", label: "自动选择（推荐）" },
  { value: "official", label: "官方源" },
  { value: "mirror", label: "镜像源" },
  { value: "localCache", label: "仅本地缓存" },
];

const memoryPresets = [2048, 4096, 6144, 8192, 12288];

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function sameSettings(left: LauncherSettings, right: LauncherSettings): boolean {
  return (
    (left.javaPath ?? "") === (right.javaPath ?? "") &&
    left.source === right.source &&
    (left.mirrorConfigPath ?? "") === (right.mirrorConfigPath ?? "") &&
    left.defaultMemoryMiB === right.defaultMemoryMiB &&
    left.appearance === right.appearance
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

  const [draft, setDraft] = useState<LauncherSettings>(settings);
  const [detected, setDetected] = useState<JavaRuntime[]>(javaRuntimes);
  const [detecting, setDetecting] = useState(false);
  const [saving, setSaving] = useState(false);
  const [browsing, setBrowsing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [memoryText, setMemoryText] = useState(String(settings.defaultMemoryMiB));

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

  async function handleSave() {
    const parsed = Number(memoryText);
    if (!Number.isFinite(parsed) || parsed < 512 || parsed > 65536) {
      setError("默认内存需在 512 MiB 到 65536 MiB 之间。");
      return;
    }
    setSaving(true);
    setError(null);
    const ok = await saveSettings({ ...draft, defaultMemoryMiB: parsed });
    setSaving(false);
    if (ok) {
      setDraft((previous) => ({ ...previous, defaultMemoryMiB: parsed }));
      setMemoryText(String(parsed));
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

  return (
    <>
      <PageHeader
        eyebrow="Preferences / 系统"
        title="设置"
        subtitle="调整启动器外观、Java 运行时、下载源与内存分配。所有修改会写入启动核心的配置文件。"
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

        <div className="settings-layout">
          <div className="settings-column">
            <Card className="settings-card">
              <SectionHeader title="外观" caption="主题会立即生效，并同步到启动器配置。" />
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

            <Card className="settings-card">
              <SectionHeader title="游戏与下载" caption="这些设置会作为新实例的默认值，已有实例可在实例工具中单独覆盖。" />
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
                      hint="允许 512 – 65536 MiB；过大可能导致系统交换。"
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

                <div className="grid grid--2">
                  <Select
                    label="下载源"
                    value={draft.source}
                    onChange={(value) => updateDraft({ source: value as DownloadSource })}
                    options={sourceOptions}
                    hint="自动模式会优先官方源，失败时回退镜像。"
                  />
                  <TextInput
                    label="镜像配置路径"
                    value={draft.mirrorConfigPath ?? ""}
                    onChange={(event) => updateDraft({ mirrorConfigPath: event.target.value || null })}
                    placeholder="可选：mirror.json 的绝对路径"
                    leadingIcon="folder"
                    hint="留空则使用内置镜像列表。"
                  />
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

            <Card className="settings-card settings-card--compact settings-card--tips">
              <span className="settings-tip__icon" aria-hidden="true">
                <Icon name="info" size={16} />
              </span>
              <div>
                <p className="settings-tip__title">配置存放在哪里？</p>
                <p className="settings-tip__body">
                  设置写入 <span className="mono">launcher-settings.json</span>，不会改动实例内的文件。Java 路径与内存也可随时在实例工具中覆盖。
                </p>
              </div>
            </Card>
          </aside>
        </div>
      </div>
    </>
  );
}
