import { useEffect, useRef, type ReactNode } from "react";

export interface TerminalLine {
  text: string;
  number?: number;
  tone?: "default" | "error" | "warn" | "info" | "success" | "dim";
  key?: string | number;
}

function detectTone(text: string): TerminalLine["tone"] {
  if (/\b(ERROR|FATAL|SEVERE)\b|Exception|Caused by:/i.test(text)) return "error";
  if (/\bWARN(ING)?\b/i.test(text)) return "warn";
  if (/\b(INFO)\b/i.test(text)) return "info";
  return "default";
}

interface TerminalProps {
  lines: TerminalLine[];
  title?: string;
  subtitle?: string;
  emptyText?: string;
  autoScroll?: boolean;
  actions?: ReactNode;
  height?: number | string;
  showChrome?: boolean;
  className?: string;
}

export function Terminal({
  lines,
  title,
  subtitle,
  emptyText = "暂无日志输出",
  autoScroll = true,
  actions,
  height = 420,
  showChrome = true,
  className,
}: TerminalProps) {
  const bodyRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!autoScroll) return;
    const body = bodyRef.current;
    if (body) body.scrollTop = body.scrollHeight;
  }, [lines, autoScroll]);

  return (
    <section className={["terminal", className ?? ""].filter(Boolean).join(" ")} aria-label={title ?? "终端日志"}>
      {title || actions || showChrome ? (
        <header className="terminal__header">
          <div className="terminal__heading">
            {showChrome ? (
              <span className="terminal__dots" aria-hidden="true">
                <i />
                <i />
                <i />
              </span>
            ) : null}
            <div className="terminal__title-group">
              {title ? <span className="terminal__title">{title}</span> : null}
              {subtitle ? <span className="terminal__subtitle">{subtitle}</span> : null}
            </div>
          </div>
          {actions ? <div className="terminal__actions">{actions}</div> : null}
        </header>
      ) : null}
      <div
        ref={bodyRef}
        className={["terminal__body", lines.length === 0 ? "is-empty" : ""].filter(Boolean).join(" ")}
        style={{ height: typeof height === "number" ? `${height}px` : height }}
        tabIndex={0}
        role="log"
        aria-live="off"
      >
        {lines.length === 0 ? (
          <p className="terminal__empty">{emptyText}</p>
        ) : (
          lines.map((line, index) => {
            const tone = line.tone ?? detectTone(line.text);
            return (
              <div key={line.key ?? index} className={`terminal__line terminal__line--${tone}`}>
                <span className="terminal__gutter" aria-hidden="true">
                  {line.number ?? index + 1}
                </span>
                <span className="terminal__text">{line.text || " "}</span>
              </div>
            );
          })
        )}
      </div>
    </section>
  );
}
