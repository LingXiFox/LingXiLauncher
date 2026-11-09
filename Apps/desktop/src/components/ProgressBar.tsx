interface ProgressBarProps {
  value: number;
  max?: number;
  tone?: "accent" | "success" | "info";
  size?: "sm" | "md";
  indeterminate?: boolean;
  label?: string;
}

export function ProgressBar({
  value,
  max = 100,
  tone = "accent",
  size = "md",
  indeterminate = false,
  label,
}: ProgressBarProps) {
  const safeMax = max > 0 ? max : 100;
  const percent = Math.min(100, Math.max(0, (value / safeMax) * 100));
  return (
    <div
      className={["progress", `progress--${size}`, `progress--${tone}`, indeterminate ? "is-indeterminate" : ""]
        .filter(Boolean)
        .join(" ")}
      role="progressbar"
      aria-valuemin={0}
      aria-valuemax={safeMax}
      aria-valuenow={indeterminate ? undefined : Math.round(value)}
      aria-label={label ?? "进度"}
    >
      <div className="progress__track">
        <div className="progress__fill" style={indeterminate ? undefined : { width: `${percent}%` }} />
      </div>
    </div>
  );
}
