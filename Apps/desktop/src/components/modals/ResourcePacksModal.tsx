import { useEffect, useState } from "react";
import { api, type ContentPack } from "../../services/api";
import { useApp } from "../../stores/app";
import { Badge } from "../Badge";
import { Button } from "../Button";
import { EmptyState } from "../EmptyState";
import { Icon } from "../Icons";
import { Modal, ConfirmDialog } from "../Modal";
import { ModalError, errorMessage, formatBytes, pickFile, useInstance } from "./shared";

interface ResourcePacksModalProps {
  instanceId: string;
}

export function ResourcePacksModal({ instanceId }: ResourcePacksModalProps) {
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
      setPacks(await api.listResourcePacks(instanceId));
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

  async function importPack() {
    try {
      const path = await pickFile({ title: "选择资源包", extensions: ["zip"] });
      if (!path) return;
      setImporting(true);
      setError(null);
      const pack = await api.importResourcePack(instanceId, path);
      setPacks((current) => [pack, ...current.filter((item) => item.fileName !== pack.fileName)]);
      await refreshInstances(true);
      toast("success", "资源包已导入", pack.name || pack.fileName);
    } catch (cause) {
      setError(errorMessage(cause));
    } finally {
      setImporting(false);
    }
  }

  async function toggle(pack: ContentPack) {
    setBusyId(pack.fileName);
    try {
      await api.toggleResourcePack(instanceId, pack.fileName, !pack.enabled);
      setPacks((current) =>
        current.map((item) => (item.fileName === pack.fileName ? { ...item, enabled: !item.enabled } : item)),
      );
    } catch (cause) {
      toast("error", "切换资源包失败", errorMessage(cause));
    } finally {
      setBusyId(null);
    }
  }

  async function remove(pack: ContentPack) {
    setBusyId(pack.fileName);
    try {
      await api.deleteResourcePack(instanceId, pack.fileName);
      setPacks((current) => current.filter((item) => item.fileName !== pack.fileName));
      await refreshInstances(true);
      toast("success", "资源包已删除", pack.name || pack.fileName);
      setPendingDelete(null);
    } catch (cause) {
      toast("error", "删除资源包失败", errorMessage(cause));
    } finally {
      setBusyId(null);
    }
  }

  const enabled = packs.filter((pack) => pack.enabled).length;

  return (
    <>
      <Modal
        title="资源包"
        eyebrow={instance?.name ?? "实例"}
        subtitle={`${packs.length} 个资源包 · ${enabled} 个已启用 · 游戏会按顺序加载启用的资源包`}
        onClose={closeModal}
        size="lg"
        footer={
          <div className="modal-footer__row">
            <span className="modal-footer__note">导入 .zip 资源包后会立即复制到实例的 resourcepacks 目录。</span>
            <div className="modal-footer__actions">
              <Button variant="ghost" onClick={closeModal}>关闭</Button>
              <Button variant="primary" icon="upload" loading={importing} onClick={() => void importPack()}>
                导入资源包
              </Button>
            </div>
          </div>
        }
      >
        {loading ? (
          <div className="modal-loading"><span className="spinner" aria-hidden="true" />正在读取资源包</div>
        ) : error && packs.length === 0 ? (
          <ModalError error={error} onRetry={() => void load()} />
        ) : packs.length === 0 ? (
          <EmptyState
            icon="image"
            title="还没有资源包"
            description="导入一个 .zip 资源包，或从整合包中一并安装。"
            action={<Button variant="primary" icon="upload" loading={importing} onClick={() => void importPack()}>导入资源包</Button>}
          />
        ) : (
          <ul className="entry-list">
            {packs.map((pack) => (
              <li key={pack.fileName} className="entry-row">
                <span className="entry-row__icon entry-row__icon--image">
                  {pack.iconUrl ? <img src={pack.iconUrl} alt="" loading="lazy" /> : <Icon name="image" size={18} />}
                </span>
                <div className="entry-row__body">
                  <div className="entry-row__title">
                    <span>{pack.name || pack.fileName}</span>
                    {pack.enabled ? <Badge tone="success">已启用</Badge> : <Badge tone="outline">已停用</Badge>}
                  </div>
                  <p className="entry-row__description">{pack.description || "这个资源包没有提供简介。"}</p>
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
          title="删除资源包"
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
