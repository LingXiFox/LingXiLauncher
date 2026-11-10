import { useEffect, useState, type CSSProperties } from "react";
import { api, type BenchmarkResult, type PerformanceReport } from "../../services/api";
import { useApp } from "../../stores/app";
import { Badge } from "../Badge";
import { Button } from "../Button";
import { EmptyState } from "../EmptyState";
import { Icon } from "../Icons";
import { Modal } from "../Modal";
import { ModalError, errorMessage, formatBytes, formatDateTime, useInstance } from "./shared";

interface PerformanceModalProps {
  instanceId: string;
}

function normalizeBenchmark(result: BenchmarkResult | number): BenchmarkResult {
  return typeof result === "number" ? { score: result } : result;
}

export function PerformanceModal({ instanceId }: PerformanceModalProps) {
  const { closeModal, refreshInstances, toast } = useApp();
  const instance = useInstance(instanceId);
  const [report, setReport] = useState<PerformanceReport | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [benchmarking, setBenchmarking] = useState(false);
  const [benchmark, setBenchmark] = useState<BenchmarkResult | null>(null);
  const [applying, setApplying] = useState(false);

  async function load() {
    setLoading(true);
    setError(null);
    try {
      setReport(await api.performanceReport(instanceId));
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

  async function runBenchmark() {
    setBenchmarking(true);
    setError(null);
    try {
      const result = normalizeBenchmark(await api.runBenchmark(instanceId));
      setBenchmark(result);
      await load();
      toast("success", "性能基准完成", `综合得分 ${result.score}`);
    } catch (cause) {
      setError(errorMessage(cause));
    } finally {
      setBenchmarking(false);
    }
  }

  async function applyRecommendation() {
    setApplying(true);
    setError(null);
    try {
      await api.applyPerformance(instanceId);
      await refreshInstances(true);
      await load();
      toast("success", "性能设置已应用", "内存与图形选项已写入实例");
    } catch (cause) {
      setError(errorMessage(cause));
    } finally {
      setApplying(false);
    }
  }

  const score = report?.benchmarkScore ?? report?.score ?? benchmark?.score ?? null;
  const system = report?.system;

  return (
    <Modal
      title="性能与基准"
      eyebrow={instance?.name ?? "实例"}
      subtitle="分析本机硬件、给出实例级优化建议，并用合成基准测试评估 CPU 与内存表现。"
      onClose={closeModal}
      size="lg"
      footer={
        <div className="modal-footer__row">
          <span className="modal-footer__note">基准结果为相对分数，仅用于本机前后对比。</span>
          <div className="modal-footer__actions">
            <Button variant="ghost" icon="activity" loading={benchmarking} onClick={() => void runBenchmark()}>
              运行基准
            </Button>
            <Button variant="primary" icon="zap" loading={applying} onClick={() => void applyRecommendation()}>
              应用推荐设置
            </Button>
          </div>
        </div>
      }
    >
      {loading ? (
        <div className="modal-loading"><span className="spinner" aria-hidden="true" />正在采集系统信息</div>
      ) : error && !report ? (
        <ModalError error={error} onRetry={() => void load()} />
      ) : (
        <div className="performance-layout">
          <div className="performance-score">
            <div className="performance-score__ring" style={{ "--score": score ?? 0 } as CSSProperties}>
              <span className="performance-score__value">{score ?? "—"}</span>
              <span className="performance-score__unit">分</span>
            </div>
            <div>
              <p className="performance-score__eyebrow">当前性能评分</p>
              <h3 className="performance-score__title">{report?.profile || "均衡配置"}</h3>
              <p className="performance-score__summary">{report?.summary || "尚未生成性能报告，运行基准后可获得更完整的评估。"}</p>
            </div>
          </div>

          <div className="performance-system">
            <div className="performance-system__item">
              <Icon name="cpu" size={16} />
              <div><span>处理器</span><strong>{system?.cpu || "未检测"}</strong></div>
            </div>
            <div className="performance-system__item">
              <Icon name="memory" size={16} />
              <div><span>系统内存</span><strong>{system?.memoryMiB ? formatBytes(system.memoryMiB * 1024 * 1024) : "未检测"}</strong></div>
            </div>
            <div className="performance-system__item">
              <Icon name="monitor" size={16} />
              <div><span>图形设备</span><strong>{system?.gpu || "由系统自动选择"}</strong></div>
            </div>
            <div className="performance-system__item">
              <Icon name="layers" size={16} />
              <div><span>操作系统</span><strong>{system?.os || "未检测"}</strong></div>
            </div>
          </div>

          <div className="performance-recommendations">
            <div className="performance-recommendations__head">
              <h4>优化建议</h4>
              <Badge tone="info">{report?.recommendations?.length ?? 0} 项</Badge>
            </div>
            {report?.recommendations && report.recommendations.length > 0 ? (
              <ul>
                {report.recommendations.map((item, index) => (
                  <li key={`${index}-${item}`}>
                    <span className="performance-recommendations__mark"><Icon name="check" size={12} /></span>
                    <span>{item}</span>
                  </li>
                ))}
              </ul>
            ) : (
              <EmptyState icon="zap" title="暂无优化建议" description="运行基准或应用推荐后，这里会展示针对该实例的调整项。" compact />
            )}
          </div>

          {report?.legacyReports && report.legacyReports.length > 0 ? (
            <div className="performance-legacy">
              <div className="performance-recommendations__head">
                <h4>旧版基准记录</h4>
                <Badge tone="neutral">{report.legacyReports.length} 次 · 只读保留</Badge>
              </div>
              <p className="caption">来自 Swift 版本的历史记录，文件未修改，也不参与当前相对评分。</p>
              <div className="performance-legacy__list">
                {report.legacyReports.slice(0, 6).map((item) => (
                  <div className="performance-legacy__row" key={item.id}>
                    <div>
                      <strong>{formatDateTime(item.createdAt)}</strong>
                      <span>{item.minecraftVersion} · {item.loader || "原版"}</span>
                    </div>
                    <div className="performance-legacy__metrics">
                      <span>{item.samples} 次采样</span>
                      {item.startupAverageMs != null ? <span>启动均值 {Math.round(item.startupAverageMs)} ms</span> : null}
                      {item.residentPeakBytes ? <span>峰值内存 {formatBytes(item.residentPeakBytes)}</span> : null}
                    </div>
                  </div>
                ))}
              </div>
            </div>
          ) : null}

          {benchmark ? (
            <div className="benchmark-card">
              <div className="benchmark-card__head">
                <div>
                  <p className="benchmark-card__eyebrow">最近一次基准</p>
                  <h4>{benchmark.score} 分</h4>
                </div>
                {benchmark.durationMs ? <span className="benchmark-card__duration">{benchmark.durationMs} ms</span> : null}
              </div>
              <p className="benchmark-card__summary">{benchmark.summary || "基准完成。"}</p>
              {benchmark.sample && benchmark.sample.length > 0 ? (
                <div className="benchmark-spark" aria-hidden="true">
                  {benchmark.sample.map((value, index) => {
                    const max = Math.max(...benchmark.sample!, 1);
                    return <span key={index} style={{ height: `${Math.max(8, (value / max) * 100)}%` }} />;
                  })}
                </div>
              ) : null}
            </div>
          ) : null}

          <ModalError error={error} />
        </div>
      )}
    </Modal>
  );
}
