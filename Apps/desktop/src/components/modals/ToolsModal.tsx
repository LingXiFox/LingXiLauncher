import { useEffect, useState } from "react";
import {
  api,
  type CrashReport,
  type DiagnosticsReport,
  type GraphicsApi,
  type InstanceLaunchSettings,
  type LauncherVisibility,
  type ProcessPriority,
  type WindowMode,
  type World,
  type WorldBackup,
} from "../../services/api";
import { useApp } from "../../stores/app";
import { Badge } from "../Badge";
import { Button } from "../Button";
import { EmptyState } from "../EmptyState";
import { Icon } from "../Icons";
import { Switch, TextArea, TextInput } from "../Input";
import { Select } from "../Select";
import { Modal, ConfirmDialog } from "../Modal";
import { minecraftVersion } from "../../lib/format";
import {
  ModalError,
  errorMessage,
  formatBytes,
  formatDateTime,
  formatRelative,
  useInstance,
} from "./shared";

type ToolTab = "manage" | "worlds" | "diagnostics";

interface ToolsModalProps {
  instanceId: string;
  initialTab?: ToolTab;
}

const DEFAULT_LAUNCH: InstanceLaunchSettings = {
  windowMode: "windowed",
  windowWidth: 1280,
  windowHeight: 720,
  processPriority: "normal",
  environment: {},
  preLaunchCommand: "",
  wrapperCommand: "",
  postLaunchCommand: "",
  graphicsApi: "auto",
  vulkanValidation: false,
  verifyBeforeLaunch: false,
  launcherVisibility: "keep",
};

const windowModeOptions: Array<{ value: WindowMode; label: string }> = [
  { value: "windowed", label: "窗口化" },
  { value: "maximized", label: "最大化" },
  { value: "fullscreen", label: "全屏" },
];

const priorityOptions: Array<{ value: ProcessPriority; label: string }> = [
  { value: "low", label: "最低" },
  { value: "belowNormal", label: "低于正常" },
  { value: "normal", label: "正常" },
  { value: "aboveNormal", label: "高于正常" },
  { value: "high", label: "最高" },
];

const graphicsOptions: Array<{ value: GraphicsApi; label: string }> = [
  { value: "auto", label: "自动（由游戏决定）" },
  { value: "openGl", label: "OpenGL" },
  { value: "vulkan", label: "Vulkan（仅 26.2+）" },
];

const visibilityOptions: Array<{ value: LauncherVisibility; label: string }> = [
  { value: "keep", label: "保持启动器可见" },
  { value: "minimize", label: "最小化启动器" },
  { value: "hide", label: "隐藏启动器" },
  { value: "close", label: "启动后关闭启动器" },
];

function environmentToText(environment: Record<string, string>): string {
  return Object.entries(environment)
    .map(([key, value]) => `${key}=${value}`)
    .join("\n");
}

function textToEnvironment(text: string): Record<string, string> {
  const result: Record<string, string> = {};
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const index = trimmed.indexOf("=");
    if (index <= 0) continue;
    const key = trimmed.slice(0, index).trim();
    if (!key) continue;
    result[key] = trimmed.slice(index + 1).trim();
  }
  return result;
}

const TABS: { value: ToolTab; label: string }[] = [
  { value: "manage", label: "实例设置" },
  { value: "worlds", label: "世界与备份" },
  { value: "diagnostics", label: "崩溃诊断" },
];

export function ToolsModal({ instanceId, initialTab = "manage" }: ToolsModalProps) {
  const { closeModal, refreshInstances, toast, openModal } = useApp();
  const instance = useInstance(instanceId);
  const [tab, setTab] = useState<ToolTab>(initialTab);

  const [memory, setMemory] = useState(instance?.memoryMib ? String(instance.memoryMib) : "");
  const [jvmArgs, setJvmArgs] = useState(instance?.jvmArguments ?? "");
  const [saving, setSaving] = useState(false);
  const [manageError, setManageError] = useState<string | null>(null);
  const [pendingDelete, setPendingDelete] = useState(false);

  const [launch, setLaunch] = useState<InstanceLaunchSettings>(instance?.launch ?? DEFAULT_LAUNCH);
  const [environmentText, setEnvironmentText] = useState(environmentToText(instance?.launch?.environment ?? {}));
  const [savingLaunch, setSavingLaunch] = useState(false);
  const [launchError, setLaunchError] = useState<string | null>(null);

  const [worlds, setWorlds] = useState<World[]>([]);
  const [backups, setBackups] = useState<WorldBackup[]>([]);
  const [worldsLoading, setWorldsLoading] = useState(false);
  const [worldsError, setWorldsError] = useState<string | null>(null);
  const [worldBusy, setWorldBusy] = useState<string | null>(null);
  const [pendingWorld, setPendingWorld] = useState<World | null>(null);
  const [pendingRestore, setPendingRestore] = useState<WorldBackup | null>(null);

  const [diagnostics, setDiagnostics] = useState<DiagnosticsReport | null>(null);
  const [diagnosing, setDiagnosing] = useState(false);
  const [diagnosticsError, setDiagnosticsError] = useState<string | null>(null);
  const [copyingBundle, setCopyingBundle] = useState(false);
  const [crash, setCrash] = useState<CrashReport | null>(null);

  useEffect(() => {
    setMemory(instance?.memoryMib ? String(instance.memoryMib) : "");
    setJvmArgs(instance?.jvmArguments ?? "");
  }, [instance?.memoryMib, instance?.jvmArguments]);

  useEffect(() => {
    if (!instance?.launch) return;
    setLaunch(instance.launch);
    setEnvironmentText(environmentToText(instance.launch.environment ?? {}));
  }, [instance?.launch]);

  async function loadWorlds() {
    setWorldsLoading(true);
    setWorldsError(null);
    try {
      const [worldList, backupList] = await Promise.all([api.listWorlds(instanceId), api.listBackups(instanceId)]);
      setWorlds(worldList);
      setBackups(backupList);
    } catch (cause) {
      setWorldsError(errorMessage(cause));
    } finally {
      setWorldsLoading(false);
    }
  }

  useEffect(() => {
    if (tab === "worlds") void loadWorlds();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tab, instanceId]);

  async function saveInstance() {
    const parsed = Number(memory);
    if (!Number.isFinite(parsed) || parsed < 512 || parsed > 65536) {
      setManageError("内存需在 512 MiB 到 65536 MiB 之间。");
      return;
    }
    setSaving(true);
    setManageError(null);
    try {
      await api.updateInstance(instanceId, { memoryMib: parsed, jvmArguments: jvmArgs });
      await refreshInstances(true);
      toast("success", "实例设置已保存", "启动实例时生效");
    } catch (cause) {
      setManageError(errorMessage(cause));
    } finally {
      setSaving(false);
    }
  }

  async function saveLaunch() {
    const width = Math.round(launch.windowWidth);
    const height = Math.round(launch.windowHeight);
    if (!Number.isFinite(width) || width < 320 || width > 7680 || !Number.isFinite(height) || height < 240 || height > 4320) {
      setLaunchError("窗口尺寸需在 320×240 到 7680×4320 之间。");
      return;
    }
    setSavingLaunch(true);
    setLaunchError(null);
    try {
      await api.updateInstanceLaunch(instanceId, {
        ...launch,
        windowWidth: width,
        windowHeight: height,
        environment: textToEnvironment(environmentText),
        preLaunchCommand: launch.preLaunchCommand?.trim() ? launch.preLaunchCommand.trim() : null,
        wrapperCommand: launch.wrapperCommand?.trim() ? launch.wrapperCommand.trim() : null,
        postLaunchCommand: launch.postLaunchCommand?.trim() ? launch.postLaunchCommand.trim() : null,
      });
      await refreshInstances(true);
      toast("success", "启动设置已保存", "下次启动该实例时生效");
    } catch (cause) {
      setLaunchError(errorMessage(cause));
    } finally {
      setSavingLaunch(false);
    }
  }

  async function deleteInstance() {
    setSaving(true);
    setManageError(null);
    try {
      await api.deleteInstance(instanceId);
      await refreshInstances();
      closeModal();
      toast("success", "实例已删除", instance?.name ?? instanceId);
    } catch (cause) {
      setManageError(errorMessage(cause));
      setPendingDelete(false);
    } finally {
      setSaving(false);
    }
  }

  async function backup(world: World) {
    setWorldBusy(world.folder);
    try {
      const created = await api.backupWorld(instanceId, world.folder);
      setBackups((current) => [created, ...current]);
      toast("success", "世界已备份", created.name);
    } catch (cause) {
      toast("error", "备份世界失败", errorMessage(cause));
    } finally {
      setWorldBusy(null);
    }
  }

  async function restore(backupItem: WorldBackup) {
    setWorldBusy(backupItem.id);
    try {
      await api.restoreWorld(instanceId, backupItem.id);
      toast("success", "世界已恢复", backupItem.name);
      setPendingRestore(null);
      await loadWorlds();
    } catch (cause) {
      toast("error", "恢复世界失败", errorMessage(cause));
    } finally {
      setWorldBusy(null);
    }
  }

  async function removeWorld(world: World) {
    setWorldBusy(world.folder);
    try {
      await api.deleteWorld(instanceId, world.folder);
      setWorlds((current) => current.filter((item) => item.folder !== world.folder));
      toast("success", "世界已删除", world.name);
      setPendingWorld(null);
    } catch (cause) {
      toast("error", "删除世界失败", errorMessage(cause));
    } finally {
      setWorldBusy(null);
    }
  }

  async function diagnose() {
    setDiagnosing(true);
    setDiagnosticsError(null);
    try {
      const report = await api.diagnose(instanceId);
      setDiagnostics(report);
      setCrash(await api.latestCrashReport(instanceId));
    } catch (cause) {
      setDiagnosticsError(errorMessage(cause));
    } finally {
      setDiagnosing(false);
    }
  }

  async function copyDiagnostics() {
    setCopyingBundle(true);
    try {
      const text = await api.diagnosticBundle(instanceId);
      await navigator.clipboard.writeText(text);
      toast("success", "诊断信息已复制", "已脱敏，可直接粘贴到 GitHub Issue");
    } catch (cause) {
      toast("error", "复制诊断信息失败", errorMessage(cause));
    } finally {
      setCopyingBundle(false);
    }
  }

  useEffect(() => {
    if (tab === "diagnostics") void diagnose();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tab, instanceId]);

  return (
    <>
      <Modal
        title="实例工具"
        eyebrow={instance?.name ?? "实例"}
        subtitle={instance ? `${minecraftVersion(instance)} · ${instance.loader ? `${instance.loader} ${instance.loaderVersion ?? ""}` : "原版"}` : undefined}
        onClose={closeModal}
        size="xl"
        bodyClassName="modal-panel--flush"
      >
        <div className="modal-tabs">
          {TABS.map((item) => (
            <button key={item.value} type="button" className={tab === item.value ? "is-active" : ""} onClick={() => setTab(item.value)}>
              {item.label}
            </button>
          ))}
        </div>

        <div className="modal-scroll">
          {tab === "manage" ? (
            <div className="tools-manage">
              <div className="tools-paths">
                <div className="tools-path">
                  <span className="tools-path__label">实例目录</span>
                  <span className="tools-path__value">{instance?.path || "—"}</span>
                  <Button size="sm" variant="ghost" icon="folder" disabled={!instance?.path} onClick={() => instance?.path && void api.revealPath(instance.path)}>
                    打开
                  </Button>
                </div>
                <div className="tools-path">
                  <span className="tools-path__label">日志目录</span>
                  <span className="tools-path__value">launcher 与游戏日志</span>
                  <Button size="sm" variant="ghost" icon="logs" onClick={() => void api.openLogsFolder()}>
                    打开
                  </Button>
                </div>
              </div>

              <div className="modal-form">
                <TextInput
                  label="内存上限（MiB）"
                  type="number"
                  min={512}
                  max={65536}
                  value={memory}
                  onChange={(event) => setMemory(event.target.value)}
                  hint="留空则使用启动器默认内存；建议不低于 2048 MiB。"
                />
                <TextArea
                  label="额外 JVM 参数"
                  rows={4}
                  value={jvmArgs}
                  onChange={(event) => setJvmArgs(event.target.value)}
                  placeholder="-XX:+UseG1GC&#10;-XX:+ParallelRefProcEnabled"
                  hint="每行一个参数，保存时会写入实例清单。"
                />
                <ModalError error={manageError} />
                <div className="modal-form__actions">
                  <Button variant="primary" icon="save" loading={saving} onClick={() => void saveInstance()}>
                    保存设置
                  </Button>
                </div>
              </div>

              <div className="tools-section-head tools-section-head--spaced">
                <div>
                  <h4>启动行为</h4>
                  <p>窗口、进程优先级、前置与收尾命令都按实例保存。</p>
                </div>
              </div>

              <div className="modal-form">
                <div className="grid grid--2">
                  <Select
                    label="窗口模式"
                    value={launch.windowMode}
                    onChange={(value) => setLaunch((current) => ({ ...current, windowMode: value as WindowMode }))}
                    options={windowModeOptions}
                    hint="最大化会用主显示器尺寸作为窗口大小。"
                  />
                  <Select
                    label="启动器可见性"
                    value={launch.launcherVisibility}
                    onChange={(value) => setLaunch((current) => ({ ...current, launcherVisibility: value as LauncherVisibility }))}
                    options={visibilityOptions}
                    hint="游戏启动成功后立即生效。"
                  />
                </div>
                <div className="grid grid--2">
                  <TextInput
                    label="窗口宽度"
                    type="number"
                    min={320}
                    max={7680}
                    value={String(launch.windowWidth)}
                    onChange={(event) => setLaunch((current) => ({ ...current, windowWidth: Number(event.target.value) }))}
                    hint="320 – 7680 像素。"
                  />
                  <TextInput
                    label="窗口高度"
                    type="number"
                    min={240}
                    max={4320}
                    value={String(launch.windowHeight)}
                    onChange={(event) => setLaunch((current) => ({ ...current, windowHeight: Number(event.target.value) }))}
                    hint="240 – 4320 像素。"
                  />
                </div>
                <div className="grid grid--2">
                  <Select
                    label="进程优先级"
                    value={launch.processPriority}
                    onChange={(value) => setLaunch((current) => ({ ...current, processPriority: value as ProcessPriority }))}
                    options={priorityOptions}
                    hint="Windows 与 macOS/Linux 分别通过系统工具设置。"
                  />
                  <Select
                    label="图形后端"
                    value={launch.graphicsApi}
                    onChange={(value) => setLaunch((current) => ({ ...current, graphicsApi: value as GraphicsApi }))}
                    options={graphicsOptions}
                    hint="Vulkan 需要 Minecraft 26.2 及以上版本。"
                  />
                </div>
                <Switch
                  label="启用 Vulkan 校验层"
                  description="仅在选择 Vulkan 且版本支持时传给游戏，用于排查驱动问题。"
                  checked={launch.vulkanValidation}
                  onChange={(checked) => setLaunch((current) => ({ ...current, vulkanValidation: checked }))}
                  disabled={launch.graphicsApi !== "vulkan"}
                />
                <Switch
                  label="启动前校验游戏文件"
                  description="按版本清单逐项校验库与客户端 jar 的大小和 SHA-1，发现损坏立即中止启动。"
                  checked={launch.verifyBeforeLaunch}
                  onChange={(checked) => setLaunch((current) => ({ ...current, verifyBeforeLaunch: checked }))}
                />
                <TextArea
                  label="环境变量"
                  rows={3}
                  value={environmentText}
                  onChange={(event) => setEnvironmentText(event.target.value)}
                  placeholder="MESA_GL_VERSION_OVERRIDE=4.6&#10;# 每行一个 KEY=VALUE"
                  hint="会注入到游戏进程，覆盖启动器自身环境。"
                />
                <TextInput
                  label="启动前命令"
                  value={launch.preLaunchCommand ?? ""}
                  onChange={(event) => setLaunch((current) => ({ ...current, preLaunchCommand: event.target.value }))}
                  placeholder="可选：例如 ./prepare.sh"
                  hint="在游戏目录执行；返回非零会中止启动。"
                />
                <TextInput
                  label="包装命令"
                  value={launch.wrapperCommand ?? ""}
                  onChange={(event) => setLaunch((current) => ({ ...current, wrapperCommand: event.target.value }))}
                  placeholder="可选：例如 gamemoderun / prime-run"
                  hint="命令会前缀在 Java 之前，例如 gamemoderun 可提升 Linux 下性能。"
                />
                <TextInput
                  label="启动后命令"
                  value={launch.postLaunchCommand ?? ""}
                  onChange={(event) => setLaunch((current) => ({ ...current, postLaunchCommand: event.target.value }))}
                  placeholder="可选：例如 notify-send '游戏已退出'"
                  hint="游戏进程结束后在后台执行，失败只会记录日志。"
                />
                <ModalError error={launchError} />
                <div className="modal-form__actions">
                  <Button variant="primary" icon="save" loading={savingLaunch} onClick={() => void saveLaunch()}>
                    保存启动设置
                  </Button>
                </div>
              </div>

              <div className="danger-zone">
                <div>
                  <h4 className="danger-zone__title">删除实例</h4>
                  <p className="danger-zone__description">删除实例目录、模组、存档与日志。此操作不可撤销。</p>
                </div>
                <Button variant="danger" icon="trash" onClick={() => setPendingDelete(true)}>
                  删除实例
                </Button>
              </div>
            </div>
          ) : null}

          {tab === "worlds" ? (
            <div className="tools-worlds">
              <div className="tools-section-head">
                <div>
                  <h4>世界</h4>
                  <p>备份会保存在启动器数据目录中，可随时恢复。</p>
                </div>
                <Button size="sm" variant="secondary" icon="refresh" loading={worldsLoading} onClick={() => void loadWorlds()}>
                  刷新
                </Button>
              </div>
              {worldsLoading ? (
                <div className="modal-loading"><span className="spinner" aria-hidden="true" />正在扫描世界</div>
              ) : worldsError ? (
                <ModalError error={worldsError} onRetry={() => void loadWorlds()} />
              ) : worlds.length === 0 ? (
                <EmptyState icon="world" title="还没有世界" description="进入游戏创建一个世界后，这里会显示本地存档。" compact />
              ) : (
                <ul className="entry-list">
                  {worlds.map((world) => (
                    <li key={world.folder} className="entry-row">
                      <span className="entry-row__icon"><Icon name="world" size={18} /></span>
                      <div className="entry-row__body">
                        <div className="entry-row__title">
                          <span>{world.name}</span>
                          {world.gameMode ? <Badge tone="outline">{world.gameMode}</Badge> : null}
                        </div>
                        <p className="entry-row__meta">
                          {world.version ? `${world.version} · ` : ""}
                          {formatRelative(world.lastPlayed)}
                          {world.sizeBytes ? ` · ${formatBytes(world.sizeBytes)}` : ""}
                        </p>
                      </div>
                      <div className="entry-row__actions">
                        <Button size="sm" variant="secondary" icon="archive" loading={worldBusy === world.folder} onClick={() => void backup(world)}>
                          备份
                        </Button>
                        <Button size="sm" variant="ghost" icon="trash" aria-label={`删除 ${world.name}`} onClick={() => setPendingWorld(world)} />
                      </div>
                    </li>
                  ))}
                </ul>
              )}

              <div className="tools-section-head tools-section-head--spaced">
                <div>
                  <h4>备份</h4>
                  <p>{backups.length} 个可恢复的世界备份</p>
                </div>
              </div>
              {backups.length === 0 ? (
                <EmptyState icon="archive" title="还没有备份" description="在世界列表点击备份即可创建快照。" compact />
              ) : (
                <ul className="entry-list">
                  {backups.map((backupItem) => (
                    <li key={backupItem.id} className="entry-row">
                      <span className="entry-row__icon"><Icon name="archive" size={18} /></span>
                      <div className="entry-row__body">
                        <div className="entry-row__title"><span>{backupItem.name}</span></div>
                        <p className="entry-row__meta">
                          {formatDateTime(backupItem.createdAt)}
                          {backupItem.sizeBytes ? ` · ${formatBytes(backupItem.sizeBytes)}` : ""}
                        </p>
                      </div>
                      <div className="entry-row__actions">
                        <Button size="sm" variant="secondary" loading={worldBusy === backupItem.id} onClick={() => setPendingRestore(backupItem)}>
                          恢复
                        </Button>
                      </div>
                    </li>
                  ))}
                </ul>
              )}
            </div>
          ) : null}

          {tab === "diagnostics" ? (
            <div className="tools-diagnostics">
              <div className="tools-section-head">
                <div>
                  <h4>健康检查</h4>
                  <p>检查 Java、游戏文件、内存、磁盘、账户与最近日志。</p>
                </div>
                <div className="row">
                  <Button size="sm" variant="ghost" icon="copy" loading={copyingBundle} onClick={() => void copyDiagnostics()}>
                    复制诊断信息
                  </Button>
                  <Button size="sm" variant="secondary" icon="activity" loading={diagnosing} onClick={() => void diagnose()}>
                    重新诊断
                  </Button>
                </div>
              </div>
              {diagnosing && !diagnostics ? (
                <div className="modal-loading"><span className="spinner" aria-hidden="true" />正在检查实例</div>
              ) : diagnostics ? (
                <>
                  <div className="diagnostics-summary">
                    <span className="diagnostics-summary__title">诊断结果</span>
                    <span className="diagnostics-summary__text">{diagnostics.summary || "检查完成"}</span>
                  </div>
                  <ul className="check-list">
                    {diagnostics.checks.map((check) => (
                      <li key={check.id} className={`check-row check-row--${check.status}`}>
                        <span className="check-row__icon">
                          <Icon name={check.status === "pass" ? "checkCircle" : check.status === "warn" ? "warning" : "xCircle"} size={16} />
                        </span>
                        <div className="check-row__body">
                          <div className="check-row__title">
                            <span>{check.label}</span>
                            <Badge tone={check.status === "pass" ? "success" : check.status === "warn" ? "warning" : "danger"}>
                              {check.status === "pass" ? "通过" : check.status === "warn" ? "注意" : "失败"}
                            </Badge>
                          </div>
                          {check.detail ? <p className="check-row__detail">{check.detail}</p> : null}
                        </div>
                      </li>
                    ))}
                  </ul>
                </>
              ) : diagnosticsError ? (
                <ModalError error={diagnosticsError} onRetry={() => void diagnose()} />
              ) : null}

              <div className="tools-section-head tools-section-head--spaced">
                <div>
                  <h4>最近崩溃</h4>
                  <p>{crash ? crash.reason || "检测到崩溃报告" : "没有检测到最近的崩溃报告"}</p>
                </div>
                {crash ? (
                  <Button size="sm" variant="secondary" icon="external" onClick={() => openModal({ type: "crash", instanceId })}>
                    查看报告
                  </Button>
                ) : null}
              </div>
              {crash ? (
                <div className="crash-teaser">
                  <p className="crash-teaser__time">{formatDateTime(crash.occurredAt)}</p>
                  <p className="crash-teaser__reason">{crash.reason || crash.description || "未知原因"}</p>
                  {crash.stackTrace ? <pre className="crash-teaser__stack">{crash.stackTrace.split("\n").slice(0, 6).join("\n")}</pre> : null}
                </div>
              ) : (
                <EmptyState icon="checkCircle" title="运行状态良好" description="最近没有发现崩溃报告或严重日志错误。" compact />
              )}
              <ModalError error={diagnosticsError} />
            </div>
          ) : null}
        </div>
      </Modal>

      {pendingDelete ? (
        <ConfirmDialog
          title="删除实例"
          description={`确定要永久删除「${instance?.name ?? instanceId}」吗？实例目录中的所有文件都会被移除。`}
          confirmLabel="永久删除"
          busy={saving}
          onConfirm={() => void deleteInstance()}
          onCancel={() => setPendingDelete(false)}
        />
      ) : null}

      {pendingWorld ? (
        <ConfirmDialog
          title="删除世界"
          description={`确定要删除「${pendingWorld.name}」吗？建议先创建备份。`}
          confirmLabel="删除世界"
          busy={worldBusy === pendingWorld.folder}
          onConfirm={() => void removeWorld(pendingWorld)}
          onCancel={() => setPendingWorld(null)}
        />
      ) : null}

      {pendingRestore ? (
        <ConfirmDialog
          title="恢复世界备份"
          description={`会用备份「${pendingRestore.name}」覆盖当前世界。现有世界会先被替换，确定继续吗？`}
          confirmLabel="恢复备份"
          tone="accent"
          busy={worldBusy === pendingRestore.id}
          onConfirm={() => void restore(pendingRestore)}
          onCancel={() => setPendingRestore(null)}
        />
      ) : null}
    </>
  );
}
