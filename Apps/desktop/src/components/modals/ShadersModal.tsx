import { useEffect, useState } from "react";
import { api, type ContentPack } from "../../services/api";
import { useApp } from "../../stores/app";
import { Badge } from "../Badge";
import { Button } from "../Button";
import { EmptyState } from "../EmptyState";
import { Icon } from "../Icons";
import { Modal, ConfirmDialog } from "../Modal";
import { ModalError, errorMessage, formatBytes, pickFile, useInstance } from "./shared";

interface ShadersModalProps {
  instanceId: string;
}

export function ShadersModal({ instanceId }: ShadersModalProps) {
  const { closeModal, refreshInstances, toast } = useApp();
  const instance = useInstance(instanceId);
  const [packs, setPacks] = useState<ContentPack[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [importing, setImporting] = useState(false);
  const [pendingDelete, setPendingDelete] = useState<ContentPack | null>(null);

  async function load() {
    setLoading(true);
    setError(null);
    try {
      setPacks(await api.listShaders(instanceId));
    } catch (cause) {
      setError(errorMessage(cause));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [instanceId]);

  async function importShader() {
    try {
      const path = await pickFile({ title: "选择光影包", extensions: ["zip"] });
      if (!path) return;
      setImporting(true);
      setError(null);
      const pack = await api.importShader(instanceId, path);
      setPacks((current) => [pack, ...current.filter((item) => item.fileName !== pack.fileName)]);
      await refreshInstances(true);
      toast("success", "光影包已导入", pack.name || pack.fileName);
    } catch (cause) {
      setError(errorMessage(cause));
    } finally {
      setImporting(false);
    }
  }

  async function toggle(pack: ContentPack) {
    setBusyId(pack.fileName);
    try {
      await api.toggleShader(instanceId, pack.fileName, !pack.enabled);
      setPacks((current) =>
        current.map((item) => (item.fileName === pack.fileName ? { ...item, enabled: !item.enabled } : item)),
      );
      toast("info", pack.enabled ? "已停用光影" : "已启用光影", "重启游戏后生效");
    } catch (cause) {
      toast("error", "切换光影失败", errorMessage(cause));
    } finally {
      setBusyId(null);
    }
  }

  async function remove(pack: ContentPack) {
    setBusyId(pack.fileName);
    try {
      await api.deleteShader(instanceId, pack.fileName);
      setPacks((current) => current.filter((item) => item.fileName !== pack.fileName));
      await refreshInstances(true);
      toast("success", "光影包已删除", pack.name || pack.fileName);
      setPendingDelete(null);
    } catch (cause) {
      toast("error", "删除光影包失败", errorMessage(cause));
    } finally {
      setBusyId(null);
    }
  }

  const active = packs.find((pack) => pack.enabled) ?? null;

  return (
    <>
      <Modal
        title="光影包"
        eyebrow={instance?.name ?? "实例"}
        subtitle="管理 shaderpacks 目录，并通过 options.txt 的 shaderPack 项切换当前光影。"
        onClose={closeModal}
        size="lg"
        footer={
          <div className="modal-footer__row">
            <span className="modal-footer__note">
              {instance?.loader === "fabric" ? "Fabric 实例需要安装 Iris 才能加载光影。" : "需要 Iris 或 OptiFine 才能加载光影。"}
            </span>
            <div className="modal-footer__actions">
              <Button variant="ghost" onClick={closeModal}>关闭</Button>
              <Button variant="primary" icon="upload" loading={importing} onClick={() => void importShader()}>
                导入光影包
              </Button>
            </div>
          </div>
        }
      >
        <div className="shader-current">
          <span className="shader-current__icon"><Icon name="sparkles" size={18} /></span>
          <div>
            <p className="shader-current__label">当前光影</p>
            <p className="shader-current__name">{active ? active.name || active.fileName : "未启用光影"}</p>
          </div>
          {active ? <Badge tone="success" dot>运行中</Badge> : <Badge tone="outline">原版渲染</Badge>}
        </div>

        {loading ? (
          <div className="modal-loading"><span className="spinner" aria-hidden="true" />正在读取光影包</div>
        ) : error && packs.length === 0 ? (
          <ModalError error={error} onRetry={() => void load()} />
        ) : packs.length === 0 ? (
          <EmptyState
            icon="sparkles"
            title="还没有光影包"
            description="导入一个 .zip 光影包，然后在列表中启用它。"
            action={<Button variant="primary" icon="upload" loading={importing} onClick={() => void importShader()}>导入光影包</Button>}
          />
        ) : (
          <ul className="entry-list">
            {packs.map((pack) => (
              <li key={pack.fileName} className="entry-row">
                <span className="entry-row__icon"><Icon name="sparkles" size={18} /></span>
                <div className="entry-row__body">
                  <div className="entry-row__title">
                    <span>{pack.name || pack.fileName}</span>
                    {pack.enabled ? <Badge tone="success">已启用</Badge> : null}
                  </div>
                  <p className="entry-row__description">{pack.description || "光影包会替换游戏的渲染管线。"}</p>
                  <p className="entry-row__meta">{pack.fileName}{pack.sizeBytes ? ` · ${formatBytes(pack.sizeBytes)}` : ""}</p>
                </div>
                <div className="entry-row__actions">
                  <button
                    type="button"
                    role="switch"
                    aria-checked={pack.enabled}
                    aria-label={pack.enabled ? `停用 ${pack.name || pack.fileName}` : `启用 ${pack.name || pack.fileName}`}
                    className={["switch", pack.enabled ? "is-on" : ""].filter(Boolean).join(" ")}
                    disabled={busyId === pack.fileName}
                    onClick={() => void toggle(pack)}
                  >
                    <span className="switch__thumb" />
                  </button>
                  <Button
                    size="sm"
                    variant="ghost"
                    icon="trash"
                    aria-label={`删除 ${pack.name || pack.fileName}`}
                    onClick={() => setPendingDelete(pack)}
                  />
                </div>
              </li>
            ))}
          </ul>
        )}
        <ModalError error={error} />
      </Modal>

      {pendingDelete ? (
        <ConfirmDialog
          title="删除光影包"
          description={`确定要删除「${pendingDelete.name || pendingDelete.fileName}」吗？文件会从实例中移除。`}
          confirmLabel="删除"
          busy={busyId === pendingDelete.fileName}
          onConfirm={() => void remove(pendingDelete)}
          onCancel={() => setPendingDelete(null)}
        />
      ) : null}
    </>
  );
}
