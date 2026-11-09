import { useEffect, useState } from "react";
import {
  api,
  type CrashReport,
  type DiagnosticsReport,
  type World,
  type WorldBackup,
} from "../../services/api";
import { useApp } from "../../stores/app";
import { Badge } from "../Badge";
import { Button } from "../Button";
import { EmptyState } from "../EmptyState";
import { Icon } from "../Icons";
import { TextArea, TextInput } from "../Input";
import { Modal, ConfirmDialog } from "../Modal";
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

const TABS: { value: ToolTab; label: string }[] = [
  { value: "manage", label: "实例设置" },
  { value: "worlds", label: "世界与备份" },
  { value: "diagnostics", label: "崩溃诊断" },
];

export function ToolsModal({ instanceId, initialTab = "manage" }: ToolsModalProps) {
  const { closeModal, refreshInstances, toast, openModal } = useApp();
  const instance = useInstance(instanceId);
  const [tab, setTab] = useState<ToolTab>(initialTab);

  const [memory, setMemory] = useState(instance?.memoryMiB ? String(instance.memoryMiB) : "");
  const [jvmArgs, setJvmArgs] = useState(instance?.jvmArguments ?? "");
  const [saving, setSaving] = useState(false);
  const [manageError, setManageError] = useState<string | null>(null);
  const [pendingDelete, setPendingDelete] = useState(false);

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
  const [crash, setCrash] = useState<CrashReport | null>(null);

  useEffect(() => {
    setMemory(instance?.memoryMiB ? String(instance.memoryMiB) : "");
    setJvmArgs(instance?.jvmArguments ?? "");
  }, [instance?.memoryMiB, instance?.jvmArguments]);

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
      await api.updateInstance(instanceId, { memoryMiB: parsed, jvmArguments: jvmArgs });
      await refreshInstances(true);
      toast("success", "实例设置已保存", "启动实例时生效");
    } catch (cause) {
      setManageError(errorMessage(cause));
    } finally {
      setSaving(false);
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

  useEffect(() => {
    if (tab === "diagnostics") void diagnose();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tab, instanceId]);

  return (
    <>
      <Modal
        title="实例工具"
        eyebrow={instance?.name ?? "实例"}
        subtitle={instance ? `${instance.versionId || "未设置版本"} · ${instance.loader ? `${instance.loader} ${instance.loaderVersion ?? ""}` : "原版"}` : undefined}
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
                <Button size="sm" variant="secondary" icon="activity" loading={diagnosing} onClick={() => void diagnose()}>
                  重新诊断
                </Button>
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
