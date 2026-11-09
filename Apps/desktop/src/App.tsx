import { AppProvider, useApp } from "./stores/app";
import { Sidebar } from "./components/Sidebar";
import { TopBar } from "./components/TopBar";
import { ToastViewport } from "./components/Toast";
import { FoxMark, Icon } from "./components/Icons";
import { Button } from "./components/Button";
import { ModalHost } from "./components/modals/ModalHost";
import { HomePage } from "./pages/HomePage";
import { InstancesPage } from "./pages/InstancesPage";
import { DownloadsPage } from "./pages/DownloadsPage";
import { AccountsPage } from "./pages/AccountsPage";
import { LogsPage } from "./pages/LogsPage";
import { SettingsPage } from "./pages/SettingsPage";

function CurrentPage() {
  const { section } = useApp();
  switch (section) {
    case "home":
      return <HomePage />;
    case "instances":
      return <InstancesPage />;
    case "downloads":
      return <DownloadsPage />;
    case "accounts":
      return <AccountsPage />;
    case "logs":
      return <LogsPage />;
    case "settings":
      return <SettingsPage />;
  }
}

function BootScreen() {
  const { bootstrapping, bootError, backendOnline, bootstrap, dismissBootError, version, dataRoot } = useApp();

  if (bootstrapping) {
    return (
      <div className="boot-screen" role="status" aria-live="polite">
        <div className="boot-screen__mark">
          <FoxMark size={58} />
        </div>
        <p className="overline overline--accent">LingXi Launcher</p>
        <h1 className="boot-screen__title">正在唤醒启动核心</h1>
        <p className="boot-screen__subtitle">读取账户、实例与游戏版本信息…</p>
        <span className="boot-screen__spinner" aria-hidden="true" />
      </div>
    );
  }

  if (bootError || !backendOnline) {
    return (
      <div className="boot-screen boot-screen--error" role="alert">
        <div className="boot-screen__mark boot-screen__mark--error">
          <Icon name="alert" size={30} />
        </div>
        <p className="overline overline--accent">Core offline</p>
        <h1 className="boot-screen__title">启动核心未能就绪</h1>
        <p className="boot-screen__subtitle">
          {bootError ?? "无法连接本地 Tauri 后端。请确认应用已通过桌面端启动，而不是普通浏览器。"}
        </p>
        {dataRoot ? <p className="boot-screen__path mono">{dataRoot}</p> : null}
        <div className="boot-screen__actions">
          {bootError ? (
            <Button variant="ghost" onClick={dismissBootError}>
              关闭提示
            </Button>
          ) : null}
          <Button variant="primary" icon="refresh" onClick={() => void bootstrap()}>
            重新连接
          </Button>
        </div>
        <p className="boot-screen__version">LINGXI v{version.replace(/^v/i, "")}</p>
      </div>
    );
  }

  return null;
}

function Shell() {
  const { bootstrapping, ready, backendOnline, toasts, dismissToast } = useApp();

  if (bootstrapping || !ready || !backendOnline) {
    return (
      <>
        <BootScreen />
        <ToastViewport items={toasts} onDismiss={dismissToast} />
      </>
    );
  }

  return (
    <div className="app-shell">
      <Sidebar />
      <div className="app-main">
        <TopBar />
        <main className="content" id="main-content">
          <CurrentPage />
        </main>
      </div>
      <ModalHost />
      <ToastViewport items={toasts} onDismiss={dismissToast} />
    </div>
  );
}

export default function App() {
  return (
    <AppProvider>
      <Shell />
    </AppProvider>
  );
}
