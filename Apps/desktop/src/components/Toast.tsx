import { Icon } from "./Icons";

export type ToastTone = "success" | "error" | "info";

export interface ToastItem {
  id: number;
  tone: ToastTone;
  message: string;
  detail?: string;
}

interface ToastViewportProps {
  items: ToastItem[];
  onDismiss: (id: number) => void;
}

export function ToastViewport({ items, onDismiss }: ToastViewportProps) {
  return (
    <div className="toast-viewport" aria-live="polite" aria-atomic="false">
      {items.map((item) => (
        <div key={item.id} className={`toast toast--${item.tone}`} role="status">
          <span className="toast__icon" aria-hidden="true">
            <Icon
              name={item.tone === "success" ? "checkCircle" : item.tone === "error" ? "xCircle" : "info"}
              size={16}
            />
          </span>
          <div className="toast__copy">
            <p className="toast__message">{item.message}</p>
            {item.detail ? <p className="toast__detail">{item.detail}</p> : null}
          </div>
          <button type="button" className="toast__close" onClick={() => onDismiss(item.id)} aria-label="关闭通知">
            <Icon name="close" size={12} />
          </button>
        </div>
      ))}
    </div>
  );
}
