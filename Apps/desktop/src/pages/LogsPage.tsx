import { useEffect, useMemo, useState } from "react";
import { Button } from "../components/Button";
import { Card } from "../components/Card";
import { EmptyState } from "../components/EmptyState";
import { ErrorBanner } from "../components/ErrorBanner";
import { Icon } from "../components/Icons";
import { SearchInput, Switch } from "../components/Input";
import { PageHeader } from "../components/PageHeader";
import { Select } from "../components/Select";
import { Terminal, type TerminalLine } from "../components/Terminal";
import {
  api,
  onGameLog,
  type GameLogEvent,
  type LogKind,
} from "../services/api";
import { useApp } from "../stores/app";
import { formatBytes } from "../lib/format";

const logTabs: Array<{ kind: LogKind; label: string; hint: string }> = [
  { kind: "launcher", label: "启动器", hint: "launcher.log" },
  { kind: "game", label: "游戏", hint: "game.log" },
  { kind: "latest", label: "最新", hint: "latest.log" },
];

function toneForLine(line: string): TerminalLine["tone"] {
  if (/\b(ERROR|FATAL|SEVERE)\b/i.test(line)) return "error";
  if (/\b(WARN|WARNING)\b/i.test(line)) return "warn";
  if (/\[INFO\]/i.test(line)) return "default";
  return undefined;
}

export function LogsPage() {
  const { instances, toast } = useApp();
  const [instanceId, setInstanceId] = useState<string>(instances[0]?.id ?? "");
  const [kind, setKind] = useState<LogKind>("latest");
  const [content, setContent] = useState("");
  const [path, setPath] = useState("");
  const [query, setQuery] = useState("");
  const [autoScroll, setAutoScroll] = useState(true);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [liveLines, setLiveLines] = useState(0);
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    if (instances.length > 0 && !instances.some((instance) => instance.id === instanceId)) {
      setInstanceId(instances[0].id);
    }
  }, [instances, instanceId]);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    api
      .readLogs(kind, kind === "launcher" ? undefined : instanceId || undefined)
      .then((log) => {
        if (cancelled) return;
        setPath(log.path);
        setContent(log.content ?? "");
        setLiveLines(0);
      })
      .catch((reason: unknown) => {
        if (cancelled) return;
        setPath("");
        setContent("");
        setError(reason instanceof Error ? reason.message : String(reason));
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [kind, instanceId, reloadKey]);

  useEffect(() => {
    if (kind === "launcher") return;
    let disposed = false;
    let unlisten: (() => void) | undefined;
    void onGameLog((event: GameLogEvent) => {
      if (disposed) return;
      if (event.instanceId && instanceId && event.instanceId !== instanceId) return;
      const line = event.line ?? "";
      setContent((previous) => {
        const base = previous.length === 0 ? "" : `${previous.replace(/\r?\n$/, "")}\n`;
        return `${base}${line}`;
      });
      setLiveLines((count) => count + 1);
    }).then((fn) => {
      if (disposed) fn();
      else unlisten = fn;
    });
    return () => {
      disposed = true;
      unlisten?.();
    };
  }, [kind, instanceId]);

  const allLines = useMemo(() => content.split(/\r?\n/), [content]);

  const displayed = useMemo(() => {
    const term = query.trim().toLowerCase();
    const lines = allLines
      .map((line, index) => ({ line, index: index + 1 }))
      .filter(({ line }) => !term || line.toLowerCase().includes(term));
    return lines;
  }, [allLines, query]);

  const terminalLines: TerminalLine[] = useMemo(
    () =>
      displayed.map(({ line, index }) => ({
        text: line,
        number: index,
        tone: toneForLine(line),
        key: `log-${index}`,
      })),
    [displayed],
  );

  const visibleBytes = useMemo(() => new Blob([displayed.map((item) => item.line).join("\n")]).size, [displayed]);

  function handleSelectInstance(value: string) {
    setInstanceId(value);
    setQuery("");
  }

  async function handleCopy() {
    if (displayed.length === 0) return;
    try {
      await navigator.clipboard.writeText(displayed.map((item) => item.line).join("\n"));
      toast("success", "日志已复制到剪贴板", `共 ${displayed.length} 行`);
    } catch {
      toast("error", "复制失败", "当前环境不允许写入剪贴板，可尝试选中文本后复制。");
    }
  }

  async function handleOpenFolder() {
    try {
      await api.openLogsFolder();
    } catch (reason) {
      toast("error", "打开日志目录失败", reason instanceof Error ? reason.message : String(reason));
    }
  }

  return (
    <>
      <PageHeader
        eyebrow="Logs / 诊断"
        title="运行日志"
        subtitle="查看启动器与游戏输出，搜索异常堆栈；正在运行的游戏日志会实时追加。"
        actions={
          <>
            <Button variant="secondary" icon="refresh" loading={loading} onClick={() => setReloadKey((value) => value + 1)}>
              重新加载
            </Button>
            <Button variant="primary" icon="external" onClick={() => void handleOpenFolder()}>
              打开日志目录
            </Button>
          </>
        }
      />

      <div className="page-stack logs-page">
        <div className="logs-controls">
          <div className="logs-controls__select">
            <Select
              label="游戏实例"
              value={instanceId}
              onChange={handleSelectInstance}
              disabled={instances.length === 0}
              options={
                instances.length === 0
                  ? [{ value: "", label: "暂无实例" }]
                  : instances.map((instance) => ({
                      value: instance.id,
                      label: `${instance.name} · ${instance.versionId}`,
                    }))
              }
            />
          </div>
          <div className="tabs logs-tabs" role="tablist" aria-label="日志类型">
            {logTabs.map((tab) => (
              <button
                key={tab.kind}
                type="button"
                role="tab"
                aria-selected={kind === tab.kind}
                className={`tab ${kind === tab.kind ? "is-active" : ""}`}
                onClick={() => setKind(tab.kind)}
                title={tab.hint}
              >
                {tab.label}
                {kind === tab.kind && liveLines > 0 ? <span className="tab__live">{liveLines}</span> : null}
              </button>
            ))}
          </div>
          <SearchInput
            value={query}
            onChange={setQuery}
            placeholder="搜索日志内容…"
            label="搜索日志"
            className="logs-controls__search"
          />
          <Switch checked={autoScroll} onChange={setAutoScroll} label="自动滚动" />
        </div>

        {error ? (
          <ErrorBanner
            title="日志读取失败"
            message={`${error}。如果后端尚未实现 read_logs，页面将在命令可用后自动恢复。`}
            onRetry={() => setReloadKey((value) => value + 1)}
          />
        ) : null}

        {instances.length === 0 && kind !== "launcher" ? (
          <Card>
            <EmptyState
              icon="terminal"
              title="暂无实例日志"
              description="先安装一个游戏版本并启动一次，游戏日志会显示在这里。启动器日志仍然可用。"
              action={
                <Button variant="secondary" icon="logs" onClick={() => setKind("launcher")}>
                  查看启动器日志
                </Button>
              }
              compact
            />
          </Card>
        ) : null}

        <Card className="logs-panel" elevated>
          <div className="logs-panel__meta">
            <div className="logs-panel__path">
              <Icon name="file" size={14} />
              <span className="mono truncate" title={path || undefined}>
                {path || "尚未获得日志文件路径"}
              </span>
            </div>
            <div className="logs-panel__meta-right">
              <span className="caption">{displayed.length.toLocaleString("zh-CN")} 行</span>
              <span className="caption">{formatBytes(visibleBytes)}</span>
              {autoScroll ? <span className="logs-panel__live"><span className="dot-live" />实时</span> : null}
            </div>
          </div>

          {displayed.length === 0 && !loading ? (
            <EmptyState
              icon="terminal"
              title={query ? "没有匹配的日志行" : "暂无日志内容"}
              description={
                query
                  ? `没有找到包含「${query}」的日志行，清除搜索以查看全部内容。`
                  : "日志为空。启动一次游戏或触发一次操作后，输出会写入这里。"
              }
              action={
                query ? (
                  <Button variant="secondary" size="sm" onClick={() => setQuery("")}>清除搜索</Button>
                ) : (
                  <Button variant="secondary" size="sm" icon="refresh" onClick={() => setReloadKey((value) => value + 1)}>重新加载</Button>
                )
              }
              compact
            />
          ) : (
            <Terminal
              lines={terminalLines}
              title={logTabs.find((tab) => tab.kind === kind)?.hint.toUpperCase() ?? "LOG"}
              subtitle={query ? `过滤：${query}` : path ? "实时输出" : undefined}
              autoScroll={autoScroll}
              height={520}
              showChrome={false}
              actions={
                <>
                  <Button variant="ghost" size="sm" icon="copy" disabled={displayed.length === 0} onClick={() => void handleCopy()}>
                    复制
                  </Button>
                  <Button variant="ghost" size="sm" icon="external" onClick={() => void handleOpenFolder()}>
                    打开
                  </Button>
                </>
              }
            />
          )}

          <div className="logs-panel__footer">
            <span className="caption">
              {loading ? "正在读取日志…" : error ? "读取失败，显示空状态" : "日志按文件原始顺序显示，行号对应文件行号。"}
            </span>
            <span className="caption mono">{kind.toUpperCase()}</span>
          </div>
        </Card>
      </div>
    </>
  );
}
