import { useEffect, useState } from "react";
import { api, type CrashReport, type DiagnosticsReport } from "../../services/api";
import { useApp } from "../../stores/app";
import { Badge } from "../Badge";
import { Button } from "../Button";
import { EmptyState } from "../EmptyState";
import { Icon } from "../Icons";
import { Modal } from "../Modal";
import { formatDateTime, ModalError, errorMessage } from "./shared";

interface CrashModalProps {
  instanceId: string;
}

export function CrashModal({ instanceId }: CrashModalProps) {
  const { closeModal, toast, openModal } = useApp();
  const [report, setReport] = useState<CrashReport | null>(null);
  const [diagnostics, setDiagnostics] = useState<DiagnosticsReport | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);

  async function load() {
    setLoading(true);
    setError(null);
    try {
      const [latest, diagnosis] = await Promise.all([
        api.latestCrashReport(instanceId),
        api.diagnose(instanceId).catch(() => null),
      ]);
      setReport(latest);
      setDiagnostics(diagnosis);
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

  async function copyReport() {
    if (!report) return;
    const text = [
      report.reason ?? "崩溃报告",
      report.description ?? "",
      report.filePath ? `文件：${report.filePath}` : "",
      report.stackTrace ?? "",
    ].filter(Boolean).join("\n\n");
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      toast("success", "崩溃报告已复制");
      window.setTimeout(() => setCopied(false), 2000);
    } catch (cause) {
      toast("error", "复制失败", errorMessage(cause));
    }
  }

  const problems = diagnostics?.checks.filter((check) => check.status !== "pass") ?? [];

  return (
    <Modal
      title="崩溃报告"
      eyebrow="诊断"
      subtitle={report ? `记录于 ${formatDateTime(report.occurredAt)}` : "最近一次游戏崩溃"}
      onClose={closeModal}
      size="lg"
      footer={
        <div className="modal-footer__row">
          <p className="modal-footer__note">报告仅包含本实例的日志与诊断信息。</p>
          <div className="modal-footer__actions">
            <Button variant="ghost" icon="logs" onClick={() => void api.openLogsFolder()}>
              打开日志目录
            </Button>
            <Button variant="secondary" icon={copied ? "check" : "copy"} onClick={() => void copyReport()} disabled={!report}>
              {copied ? "已复制" : "复制报告"}
            </Button>
          </div>
        </div>
      }
    >
      {loading ? (
        <div className="modal-loading"><span className="spinner" aria-hidden="true" />正在读取崩溃信息</div>
      ) : error ? (
        <ModalError error={error} onRetry={() => void load()} />
      ) : !report ? (
        <EmptyState
          icon="checkCircle"
          title="没有找到崩溃报告"
          description="最近一次启动没有留下崩溃记录，或者实例还没有运行过。可以运行一次诊断，检查 Java、游戏文件与日志。"
          action={
            <Button
              variant="secondary"
              icon="activity"
              onClick={() => {
                closeModal();
                openModal({ type: "tools", instanceId, initialTab: "diagnostics" });
              }}
            >
              运行实例诊断
            </Button>
          }
        />
      ) : (
        <div className="crash-report">
          <div className="crash-report__meta">
            <Badge tone="danger" dot>崩溃</Badge>
            {report.instanceId ? <span>实例 {report.instanceId}</span> : null}
            {report.id ? <span className="mono">#{report.id}</span> : null}
          </div>
          <h3 className="crash-report__reason">{report.reason || "游戏异常退出"}</h3>
          {report.description ? <p className="crash-report__description">{report.description}</p> : null}

          {problems.length > 0 ? (
            <div>
              <p className="crash-report__label">诊断线索</p>
              <ul className="check-list">
                {problems.map((check) => (
                  <li key={check.id} className={`check-row check-row--${check.status}`}>
                    <span className="check-row__icon">
                      <Icon name={check.status === "fail" ? "xCircle" : "warning"} size={16} />
                    </span>
                    <div className="check-row__body">
                      <div className="check-row__title">{check.label}</div>
                      {check.detail ? <p className="check-row__detail">{check.detail}</p> : null}
                    </div>
                  </li>
                ))}
              </ul>
            </div>
          ) : null}

          {report.stackTrace ? (
            <div>
              <p className="crash-report__label">堆栈信息</p>
              <pre className="crash-report__stack">{report.stackTrace}</pre>
            </div>
          ) : (
            <p className="crash-report__description">这份报告没有附堆栈信息，请查看游戏日志获取更多上下文。</p>
          )}

          {report.filePath ? (
            <div>
              <p className="crash-report__label">报告文件</p>
              <p className="crash-report__path">{report.filePath}</p>
              <Button size="sm" variant="ghost" icon="external" onClick={() => void api.revealPath(report.filePath!)}>
                在访达中显示
              </Button>
            </div>
          ) : null}
        </div>
      )}
    </Modal>
  );
}
