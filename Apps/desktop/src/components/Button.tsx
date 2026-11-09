import type { ButtonHTMLAttributes } from "react";
import { Icon, type IconName } from "./Icons";

type Variant = "primary" | "secondary" | "ghost" | "danger" | "soft";
type Size = "sm" | "md" | "lg";

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant;
  size?: Size;
  icon?: IconName;
  trailingIcon?: IconName;
  loading?: boolean;
  block?: boolean;
}

export function Button({
  variant = "secondary",
  size = "md",
  icon,
  trailingIcon,
  loading = false,
  block = false,
  className,
  children,
  disabled,
  type = "button",
  ...rest
}: ButtonProps) {
  return (
    <button
      type={type}
      className={[
        "btn",
        `btn--${variant}`,
        `btn--${size}`,
        block ? "btn--block" : "",
        loading ? "is-loading" : "",
        className ?? "",
      ]
        .filter(Boolean)
        .join(" ")}
      disabled={disabled || loading}
      {...rest}
    >
      {loading ? <span className="btn__spinner" aria-hidden="true" /> : icon ? <Icon name={icon} size={size === "sm" ? 14 : 16} /> : null}
      {children ? <span className="btn__label">{children}</span> : null}
      {trailingIcon ? <Icon name={trailingIcon} size={size === "sm" ? 13 : 15} /> : null}
    </button>
  );
}

interface IconButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  icon: IconName;
  label: string;
  size?: Size;
  variant?: "ghost" | "secondary" | "danger";
  active?: boolean;
}

export function IconButton({
  icon,
  label,
  size = "md",
  variant = "ghost",
  active = false,
  className,
  type = "button",
  ...rest
}: IconButtonProps) {
  return (
    <button
      type={type}
      className={[
        "icon-btn",
        `icon-btn--${size}`,
        `icon-btn--${variant}`,
        active ? "is-active" : "",
        className ?? "",
      ]
        .filter(Boolean)
        .join(" ")}
      aria-label={label}
      title={label}
      {...rest}
    >
      <Icon name={icon} size={size === "sm" ? 14 : size === "lg" ? 20 : 16} />
    </button>
  );
}
