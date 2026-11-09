import { Icon } from "./Icons";

interface ErrorBannerProps {
  message: string;
  onRetry?: () => void;
  onDismiss?: () => void;
  title?: string;
  compact?: boolean;
}

export function ErrorBanner({
  message,
  onRetry,
  onDismiss,
  title = "操作未完成",
  compact = false,
}: ErrorBannerProps) {
  return (
    <div className={["error-banner", compact ? "error-banner--compact" : ""].filter(Boolean).join(" ")} role="alert">
      <span className="error-banner__icon" aria-hidden="true">
        <Icon name="alert" size={17} />
      </span>
      <div className="error-banner__copy">
        <p className="error-banner__title">{title}</p>
        <p className="error-banner__message">{message}</p>
      </div>
      <div className="error-banner__actions">
        {onRetry ? (
          <button type="button" className="btn btn--sm btn--secondary" onClick={onRetry}>
            重试
          </button>
        ) : null}
        {onDismiss ? (
          <button type="button" className="icon-btn icon-btn--sm" onClick={onDismiss} aria-label="关闭提示">
            <Icon name="close" size={13} />
          </button>
        ) : null}
      </div>
    </div>
  );
}
