import type { InstallProgress } from "./api";

/**
 * Wire protocol for install-progress events emitted by the Rust backend.
 * Each payload is a tagged event (kind: phase | plan | fileStarted |
 * fileFinished | fileFailed | bytes) with camelCase fields; the reducer
 * below folds them into the snapshot the UI renders. Field names must stay
 * in sync with crates/launcher-core/src/install/models.rs
 * (progress_events_serialize_with_camel_case_fields golden test).
 */
export interface InstallEvent {
  kind: string;
  /** Install task that produced the event (P1-5); distinct tasks never share counters. */
  taskId?: string | null;
  phase?: string;
  message?: string | null;
  totalFiles?: number;
  totalBytes?: number;
  cacheHits?: number;
  path?: string;
  size?: number;
  bytes?: number;
  source?: string;
  downloaded?: number;
  total?: number;
  bytesPerSecond?: number;
  remainingSeconds?: number | null;
  activeFiles?: number;
  attempt?: number;
  maxAttempts?: number;
}

function asNumber(value: unknown, fallback = 0): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

/**
 * Fold one backend event into the cumulative progress snapshot. Events are
 * accumulated (never overwrite the whole snapshot) so that cache hits,
 * per-file finishes and retried downloads all contribute correctly.
 */
export function applyInstallEvent(
  previous: InstallProgress | null,
  event: InstallEvent,
): InstallProgress {
  const base: InstallProgress = previous ?? {
    phase: "prepare",
    totalFiles: 0,
    completedFiles: 0,
    totalBytes: 0,
    downloadedBytes: 0,
    currentFile: null,
    message: null,
  };

  switch (event.kind) {
    case "phase":
      return {
        ...base,
        phase: event.phase ?? base.phase,
        message: event.message ?? base.message,
      };
    case "plan":
      // A fresh plan resets the counters for the next download batch; cache
      // hits count as already-finished files so percentages start above zero
      // when files were served from the local cache.
      return {
        ...base,
        phase: base.phase === "prepare" ? "download" : base.phase,
        totalFiles: asNumber(event.totalFiles),
        completedFiles: asNumber(event.cacheHits),
        totalBytes: asNumber(event.totalBytes),
        // Bytes already cached are not part of totalBytes (the backend only
        // counts files that still need downloading), so start at zero.
        downloadedBytes: 0,
        message: event.message ?? base.message,
      };
    case "extendPlan":
      return {
        ...base,
        totalFiles: base.totalFiles + asNumber(event.totalFiles),
        completedFiles: base.completedFiles + asNumber(event.cacheHits),
        totalBytes: base.totalBytes + asNumber(event.totalBytes),
      };
    case "fileStarted":
      return {
        ...base,
        currentFile: event.path ?? base.currentFile,
        message: event.path ?? base.message,
      };
    case "fileFinished":
      return {
        ...base,
        completedFiles: base.completedFiles + 1,
        message: event.path ?? base.message,
      };
    case "fileFailed":
      return {
        ...base,
        message: event.message ?? base.message,
      };
    case "bytes":
      return {
        ...base,
        downloadedBytes: asNumber(event.downloaded),
        totalBytes: asNumber(event.total, base.totalBytes),
      };
    case "speed":
      return {
        ...base,
        bytesPerSecond: asNumber(event.bytesPerSecond),
        remainingSeconds: typeof event.remainingSeconds === "number" ? event.remainingSeconds : null,
        activeFiles: asNumber(event.activeFiles),
      };
    case "retry":
      return {
        ...base,
        retry: {
          path: event.path ?? "",
          attempt: asNumber(event.attempt),
          maxAttempts: asNumber(event.maxAttempts),
          message: event.message ?? "",
        },
      };
    default:
      return base;
  }
}
