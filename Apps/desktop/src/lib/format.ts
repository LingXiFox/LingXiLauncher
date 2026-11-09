export function cx(...values: Array<string | false | null | undefined>): string {
  return values.filter(Boolean).join(" ");
}

export function parseDate(value?: string | null): Date | null {
  if (!value) return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

export function formatDate(value?: string | null, withTime = false): string {
  const date = parseDate(value);
  if (!date) return "—";
  return new Intl.DateTimeFormat("zh-CN", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    ...(withTime ? { hour: "2-digit", minute: "2-digit" } : {}),
  }).format(date);
}

export function formatRelative(value?: string | null): string {
  const date = parseDate(value);
  if (!date) return "从未启动";
  const diff = Date.now() - date.getTime();
  if (diff < 0) return formatDate(value, true);
  const minutes = Math.floor(diff / 60_000);
  if (minutes < 1) return "刚刚";
  if (minutes < 60) return `${minutes} 分钟前`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} 小时前`;
  const days = Math.floor(hours / 24);
  if (days < 30) return `${days} 天前`;
  return formatDate(value);
}

export function formatBytes(bytes?: number | null): string {
  if (bytes === null || bytes === undefined || !Number.isFinite(bytes) || bytes < 0) return "—";
  if (bytes < 1024) return `${Math.round(bytes)} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1024;
  let index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }
  return `${value >= 100 ? Math.round(value) : value.toFixed(1)} ${units[index]}`;
}

export function formatNumber(value?: number | null): string {
  if (value === null || value === undefined || !Number.isFinite(value)) return "—";
  return new Intl.NumberFormat("zh-CN").format(value);
}

export function formatMemory(mib?: number | null): string {
  if (!mib || mib <= 0) return "跟随默认";
  if (mib >= 1024) {
    const gb = mib / 1024;
    return `${Number.isInteger(gb) ? gb : gb.toFixed(1)} GB`;
  }
  return `${mib} MiB`;
}

export function loaderLabel(loader?: string | null): string {
  if (!loader) return "原版";
  const key = loader.toLowerCase();
  if (key.includes("neo")) return "NeoForge";
  if (key.includes("fabric")) return "Fabric";
  if (key.includes("quilt")) return "Quilt";
  if (key.includes("forge")) return "Forge";
  return loader;
}

export function versionTypeLabel(type?: string | null): string {
  const key = (type ?? "").toLowerCase();
  if (key === "release" || key === "正式版") return "正式版";
  if (key === "snapshot" || key === "快照") return "快照";
  if (key.includes("old_beta")) return "远古 Beta";
  if (key.includes("old_alpha")) return "远古 Alpha";
  return type || "未知";
}

export function percent(value: number, max: number): number {
  if (!max || max <= 0) return 0;
  return Math.min(100, Math.max(0, (value / max) * 100));
}

export function shortUuid(uuid?: string | null): string {
  if (!uuid) return "—";
  return uuid.length > 12 ? `${uuid.slice(0, 8)}…${uuid.slice(-4)}` : uuid;
}

export function platformLabel(platform?: string | null): string {
  const key = (platform ?? "").toLowerCase();
  if (key.includes("mac") || key.includes("darwin")) return "macOS";
  if (key.includes("win")) return "Windows";
  if (key.includes("linux")) return "Linux";
  return platform || "—";
}

export function greeting(): string {
  const hour = new Date().getHours();
  if (hour < 5) return "夜深了";
  if (hour < 11) return "早上好";
  if (hour < 14) return "中午好";
  if (hour < 18) return "下午好";
  return "晚上好";
}
