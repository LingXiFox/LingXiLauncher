interface AvatarProps {
  name?: string | null;
  size?: number;
  skinUrl?: string | null;
  className?: string;
  ring?: boolean;
}

function initialsOf(name: string): string {
  const trimmed = name.trim();
  if (!trimmed) return "?";
  const chars = Array.from(trimmed);
  if (chars.length === 1) return chars[0].toUpperCase();
  return chars.slice(0, 2).join("").toUpperCase();
}

export function Avatar({ name, size = 32, skinUrl, className, ring = false }: AvatarProps) {
  const label = name?.trim() || "未登录";
  return (
    <span
      className={["avatar", skinUrl ? "avatar--skin" : "", ring ? "avatar--ring" : "", className ?? ""]
        .filter(Boolean)
        .join(" ")}
      style={{ width: size, height: size, fontSize: Math.max(10, Math.round(size * 0.34)) }}
      title={label}
      aria-label={label}
      role="img"
    >
      {skinUrl ? (
        <span className="avatar__skin-crop" aria-hidden="true">
          <img src={skinUrl} alt="" draggable={false} />
        </span>
      ) : (
        <span aria-hidden="true">{initialsOf(label)}</span>
      )}
    </span>
  );
}
