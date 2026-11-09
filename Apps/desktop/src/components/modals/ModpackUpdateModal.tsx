import { useEffect, useState } from "react";
import { api, type ModpackUpdateInfo } from "../../services/api";
import { useApp } from "../../stores/app";
import { Badge } from "../Badge";
import { Button } from "../Button";
import { EmptyState } from "../EmptyState";
import { Modal } from "../Modal";
import { InstallProgressPanel, ModalError, errorMessage, formatDateTime, useInstance } from "./shared";

interface ModpackUpdateModalProps {
  instanceId: string;
}

export function ModpackUpdateModal({ instanceId }: ModpackUpdateModalProps) {
  const { closeModal, refreshInstances, toast, installedProgress, resetInstallProgress } = useApp();
  const instance = useInstance(instanceId);
  const [update, setUpdate] = useState<ModpackUpdateInfo | null>(null);
  const [loading, setLoading] = useState(true);
  const [applying, setApplying] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [checkedAt, setCheckedAt] = useState<Date | null>(null);

  async function check() {
    setLoading(true);
    setError(null);
    try {
      const result = await api.checkModpackUpdate(instanceId);
      setUpdate(result);
      setCheckedAt(new Date());
    } catch (cause) {
      setError(errorMessage(cause));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void check();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [instanceId]);

  async function apply() {
    setApplying(true);
    setError(null);
    resetInstallProgress();
    try {
      await api.applyModpackUpdate(instanceId);
      await refreshInstances();
      resetInstallProgress();
      closeModal();
      toast("success", "整合包已更新", `${instance?.name ?? "实例"} 已更新到 ${update?.latestVersion ?? "新版本"}`);
    } catch (cause) {
      setError(errorMessage(cause));
    } finally {
      setApplying(false);
    }
  }

  return (
    <Modal
      title="整合包更新"
      eyebrow={instance?.name ?? "实例"}
      subtitle="从 Modrinth 查询该整合包发布的新版本，并同步更新清单中的文件。"
      onClose={closeModal}
      size="lg"
      dismissible={!applying}
      footer={
        <div className="modal-footer__row">
          <span className="modal-footer__note">
            {checkedAt ? `上次检查：${checkedAt.toLocaleTimeString("zh-CN")}` : "正在检查更新"}
          </span>
          <div className="modal-footer__actions">
            <Button variant="ghost" icon="refresh" loading={loading} onClick={() => void check()} disabled={applying}>
              重新检查
            </Button>
            <Button variant="primary" icon="download" loading={applying} disabled={!update || loading} onClick={() => void apply()}>
              应用更新
            </Button>
          </div>
        </div>
      }
    >
      {loading ? (
        <div className="modal-loading"><span className="spinner" aria-hidden="true" />正在向 Modrinth 查询版本</div>
      ) : error ? (
        <ModalError error={error} onRetry={() => void check()} />
      ) : update ? (
        <div className="update-card">
          <div className="update-card__head">
            <div>
              <p className="update-card__eyebrow">发现新版本</p>
              <h3 className="update-card__title">{update.latestVersion}</h3>
              <p className="update-card__meta">
                当前版本 {update.currentVersion}
                {update.publishedAt ? ` · 发布于 ${formatDateTime(update.publishedAt)}` : ""}
              </p>
            </div>
            <Badge tone="accent" dot>可更新</Badge>
          </div>
          <div className="update-card__changelog">
            <p className="update-card__label">更新日志</p>
            <p className="update-card__body">{update.changelog?.trim() || "该版本没有提供更新日志。"}</p>
          </div>
          {applying ? <InstallProgressPanel progress={installedProgress} label="正在应用整合包更新" /> : null}
        </div>
      ) : (
        <EmptyState
          icon="checkCircle"
          title="已经是最新版本"
          description={`${instance?.name ?? "该整合包"} 当前没有可用的 Modrinth 更新。`}
          action={<Button variant="secondary" icon="refresh" onClick={() => void check()}>再检查一次</Button>}
        />
      )}
    </Modal>
  );
}
