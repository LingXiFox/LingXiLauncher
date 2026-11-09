import type { HTMLAttributes, ReactNode } from "react";

interface CardProps extends HTMLAttributes<HTMLDivElement> {
  selected?: boolean;
  elevated?: boolean;
  interactive?: boolean;
  children: ReactNode;
}

export function Card({ selected, elevated, interactive, className, children, ...rest }: CardProps) {
  return (
    <div
      className={[
        "card",
        selected ? "is-selected" : "",
        elevated ? "card--elevated" : "",
        interactive ? "card--interactive" : "",
        className ?? "",
      ]
        .filter(Boolean)
        .join(" ")}
      {...rest}
    >
      {children}
    </div>
  );
}

interface SectionHeaderProps {
  title: string;
  caption?: string;
  action?: ReactNode;
}

export function SectionHeader({ title, caption, action }: SectionHeaderProps) {
  return (
    <div className="section-header">
      <div>
        <h2 className="section-title">{title}</h2>
        {caption ? <p className="section-header__caption">{caption}</p> : null}
      </div>
      {action ? <div className="section-header__action">{action}</div> : null}
    </div>
  );
}
