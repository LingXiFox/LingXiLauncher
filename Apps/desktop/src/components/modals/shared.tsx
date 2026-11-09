import { open } from "@tauri-apps/plugin-dialog";
import type { ReactNode } from "react";
import type { GameInstance, InstallProgress } from "../../services/api";
import { useApp } from "../../stores/app";
import { ProgressBar } from "../ProgressBar";
import { ErrorBanner } from "../ErrorBanner";

export function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  return String(error);
}

export function formatBytes(value?: number | null): string {
  if (value === null || value === undefined || Number.isNaN(value)) return "—";
  if (value < 1024) return `${value} B`;
  const units = ["KiB", "MiB", "GiB", "TiB"];
  let amount = value / 1024;
  let index = 0;
  while (amount >= 1024 && index < units.length - 1) {
    amount /= 1024;
    index += 1;
  }
  return `${amount >= 100 ? amount.toFixed(0) : amount.toFixed(1)} ${units[index]}`;
}

export function formatDateTime(value?: string | null): string {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat("zh-CN", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  }).format(date);
}

export function formatRelative(value?: string | null): string {
  if (!value) return "从未";
  const date = new Date(value).getTime();
  if (Number.isNaN(date)) return value;
  const delta = Date.now() - date;
  if (delta < 60_000) return "刚刚";
  if (delta < 3_600_000) return `${Math.floor(delta / 60_000)} 分钟前`;
  if (delta < 86_400_000) return `${Math.floor(delta / 3_600_000)} 小时前`;
  return formatDateTime(value);
}

export function useInstance(instanceId: string): GameInstance | undefined {
  const { instances } = useApp();
  return instances.find((instance) => instance.id === instanceId);
}

export async function pickFile(options: {
  title: string;
  extensions?: string[];
}): Promise<string | null> {
  const selected = await open({
    title: options.title,
    multiple: false,
    directory: false,
    filters: options.extensions
      ? [{ name: options.title, extensions: options.extensions }]
      : undefined,
  });
  if (Array.isArray(selected)) return selected[0] ?? null;
  return selected;
}

interface InstallProgressPanelProps {
  progress: InstallProgress | null;
  label?: string;
}

export function InstallProgressPanel({ progress, label = "正在准备下载" }: InstallProgressPanelProps) {
  const percent =
    progress && progress.totalBytes > 0
      ? Math.min(100, Math.round((progress.downloadedBytes / progress.totalBytes) * 100))
      : null;
  return (
    <div className="modal-progress">
      <div className="modal-progress__head">
        <span className="modal-progress__label">{progress?.message || label}</span>
        <span className="modal-progress__value">
          {progress ? (percent !== null ? `${percent}%` : `${progress.completedFiles}/${progress.totalFiles}`) : "准备中"}
        </span>
      </div>
      <ProgressBar
        value={percent ?? progress?.completedFiles ?? 0}
        max={percent !== null ? 100 : Math.max(progress?.totalFiles ?? 1, 1)}
        tone="accent"
        indeterminate={!progress || progress.totalBytes === 0}
        label={progress?.message || label}
      />
      <p className="modal-progress__meta">
        {progress
          ? `${formatBytes(progress.downloadedBytes)} / ${formatBytes(progress.totalBytes)} · ${progress.completedFiles}/${progress.totalFiles} 个文件`
          : "等待核心返回下载计划"}
      </p>
      {progress?.currentFile ? <p className="modal-progress__file">{progress.currentFile}</p> : null}
    </div>
  );
}

export function ModalError({ error, onRetry }: { error: string | null; onRetry?: () => void }) {
  if (!error) return null;
  return <ErrorBanner message={error} onRetry={onRetry} compact />;
}

export function MetaRow({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="meta-row">
      <span className="meta-row__label">{label}</span>
      <span className="meta-row__value">{children}</span>
    </div>
  );
}
