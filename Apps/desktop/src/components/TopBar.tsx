import { Button, IconButton } from "./Button";
import { Badge } from "./Badge";
import { useApp } from "../stores/app";

export function TopBar() {
  const {
    isGameRunning,
    gamePid,
    section,
    resolvedTheme,
    toggleTheme,
    openModal,
    backendOnline,
  } = useApp();

  const sectionNames: Record<typeof section, string> = {
    home: "总览",
    instances: "游戏实例",
    downloads: "版本下载",
    accounts: "账户管理",
    logs: "运行日志",
    settings: "设置",
  };

  return (
    <header className="topbar" data-tauri-drag-region>
      <div className="topbar__left" data-tauri-drag-region>
        <span className="topbar__crumb">
          <span className="topbar__crumb-root">LINGXI</span>
          <span className="topbar__crumb-sep">/</span>
          <span>{sectionNames[section]}</span>
        </span>
        <span
          className={["status-chip", isGameRunning ? "is-running" : "is-idle"].join(" ")}
          title={isGameRunning && gamePid ? `PID ${gamePid}` : backendOnline ? "启动核心已连接" : "启动核心未连接"}
        >
          <span className="status-chip__dot" aria-hidden="true" />
          {isGameRunning ? "游戏运行中" : "就绪"}
          {isGameRunning && gamePid ? <span className="status-chip__pid">PID {gamePid}</span> : null}
        </span>
        {!backendOnline ? (
          <Badge tone="warning" className="topbar__offline">
            核心离线
          </Badge>
        ) : null}
      </div>
      <div className="topbar__actions">
        <IconButton
          icon={resolvedTheme === "dark" ? "sun" : "moon"}
          label={resolvedTheme === "dark" ? "切换到浅色主题" : "切换到深色主题"}
          onClick={toggleTheme}
        />
        <Button variant="primary" icon="plus" onClick={() => openModal({ type: "install" })}>
          安装游戏
        </Button>
      </div>
    </header>
  );
}
