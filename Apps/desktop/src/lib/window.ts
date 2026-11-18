const LOG_WINDOW_LABEL = "logs";

/**
 * True when the current webview is the detached log window. The window is
 * created by the Rust side with the label "logs" and reuses the same bundle,
 * so the router picks the view from the label instead of a second entry point.
 */
export function isLogWindow(): boolean {
  try {
    // Lazy import keeps the plain browser (vite dev without Tauri) working.
    const internals = (window as { __TAURI_INTERNALS__?: { metadata?: { currentWindow?: { label?: string } } } })
      .__TAURI_INTERNALS__;
    return internals?.metadata?.currentWindow?.label === LOG_WINDOW_LABEL;
  } catch {
    return false;
  }
}
