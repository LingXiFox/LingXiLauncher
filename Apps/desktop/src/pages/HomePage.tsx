import { useEffect, useMemo, useState } from "react";
import { Avatar } from "../components/Avatar";
import { Badge } from "../components/Badge";
import { Button } from "../components/Button";
import { Card, SectionHeader } from "../components/Card";
import { EmptyState } from "../components/EmptyState";
import { Icon } from "../components/Icons";
import { PageHeader } from "../components/PageHeader";
import { Terminal, type TerminalLine } from "../components/Terminal";
import { api } from "../services/api";
import { useApp } from "../stores/app";
import {
  formatMemory,
  formatRelative,
  greeting,
  loaderLabel,
  minecraftVersion,
} from "../lib/format";

export function HomePage() {
  const {
    instances,
    versions,
    javaRuntimes,
    accounts,
    activeProfile,
    isGameRunning,
    refreshVersions,
    launchInstance,
    stopGame,
    setSection,
    openModal,
    toast,
  } = useApp();

  const sortedInstances = useMemo(
    () =>
      [...instances].sort((a, b) => {
        const left = a.lastLaunchedAt ? Date.parse(a.lastLaunchedAt) : 0;
        const right = b.lastLaunchedAt ? Date.parse(b.lastLaunchedAt) : 0;
        return right - left || a.name.localeCompare(b.name, "zh-CN");
      }),
    [instances],
  );

  const [selectedId, setSelectedId] = useState<string | null>(sortedInstances[0]?.id ?? null);
  const [logLines, setLogLines] = useState<TerminalLine[]>([]);
  const [logPath, setLogPath] = useState("");
  const [logError, setLogError] = useState<string | null>(null);
  const [launching, setLaunching] = useState(false);

  useEffect(() => {
    if (!sortedInstances.some((item) => item.id === selectedId)) {
      setSelectedId(sortedInstances[0]?.id ?? null);
    }
  }, [sortedInstances, selectedId]);

  useEffect(() => {
    void refreshVersions("all", true);
  }, [refreshVersions]);

  useEffect(() => {
    let cancelled = false;
    api
      .readLogs("latest")
      .then((log) => {
        if (cancelled) return;
        setLogPath(log.path);
        const lines = log.content
          .split(/\r?\n/)
          .filter((line) => line.trim().length > 0)
          .slice(-10)
          .map((line, index) => ({ text: line, number: index + 1 }));
        setLogLines(lines);
        setLogError(null);
      })
      .catch((error: unknown) => {
        if (cancelled) return;
        setLogError(error instanceof Error ? error.message : String(error));
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const selected = sortedInstances.find((item) => item.id === selectedId) ?? sortedInstances[0] ?? null;
  const installedVersions = versions.filter((version) => version.installed).length;
  const accountCount = accounts.microsoft.length + accounts.local.length;

  async function handleLaunch() {
    if (!selected) return;
    if (isGameRunning) {
      await stopGame();
      return;
    }
    setLaunching(true);
    try {
      await launchInstance(selected.id);
    } finally {
      setLaunching(false);
    }
  }

  function handleOpenInstance(id: string) {
    setSelectedId(id);
    const instance = instances.find((item) => item.id === id);
    if (instance) openModal({ type: "tools", instanceId: instance.id, initialTab: "manage" });
  }

  return (
    <>
      <PageHeader
        eyebrow="Overview / 总览"
        title={`${greeting()}${activeProfile ? `，${activeProfile.name}` : ""}`}
        subtitle={
          activeProfile
            ? "灵曦已就绪。选择一个实例继续冒险，或安装新的游戏版本。"
            : "尚未选择玩家身份。登录账户后即可启动游戏，或者先安装一个版本。"
        }
        actions={
          <>
            <Button variant="secondary" icon="layers" onClick={() => setSection("instances")}>
              管理实例
            </Button>
            <Button variant="primary" icon="plus" onClick={() => openModal({ type: "install" })}>
              安装游戏
            </Button>
          </>
        }
      />

      <div className="page-stack">
        <div className="home-hero-grid">
          <Card className="quick-launch" elevated>
            <div className="quick-launch__head">
              <div>
                <p className="overline">Quick launch</p>
                <h2 className="quick-launch__title">快速启动</h2>
              </div>
              {sortedInstances.length > 1 ? (
                <label className="quick-launch__picker">
                  <span className="sr-only">选择要启动的实例</span>
                  <select
                    className="select"
                    value={selected?.id ?? ""}
                    onChange={(event) => setSelectedId(event.target.value)}
                  >
                    {sortedInstances.map((instance) => (
                      <option key={instance.id} value={instance.id}>
                        {instance.name}
                      </option>
                    ))}
                  </select>
                  <Icon name="chevronDown" size={13} className="select-shell__icon" />
                </label>
              ) : null}
            </div>

            {selected ? (
              <>
                <div className="quick-launch__body">
                  <span className="instance-mark instance-mark--lg" aria-hidden="true">
                    <Icon name="layers" size={26} />
                  </span>
                  <div className="quick-launch__instance">
                    <h3>{selected.name}</h3>
                    <p className="caption">
                      Minecraft {minecraftVersion(selected)}
                      {selected.loader ? ` · ${loaderLabel(selected.loader)} ${selected.loaderVersion ?? ""}` : " · 原版"}
                    </p>
                    <div className="chip-row quick-launch__chips">
                      <Badge tone="outline">{formatMemory(selected.memoryMiB)}</Badge>
                      <Badge tone="outline">{selected.modCount ?? 0} 个模组</Badge>
                      <Badge tone="outline">{selected.resourcePackCount ?? 0} 个资源包</Badge>
                    </div>
                  </div>
                </div>
                <div className="quick-launch__footer">
                  <div className="quick-launch__last">
                    <span className="quick-launch__last-label">上次启动</span>
                    <span>{formatRelative(selected.lastLaunchedAt)}</span>
                  </div>
                  <div className="quick-launch__buttons">
                    <Button variant="ghost" size="sm" icon="wrench" onClick={() => handleOpenInstance(selected.id)}>
                      管理
                    </Button>
                    <Button
                      variant={isGameRunning ? "danger" : "primary"}
                      size="lg"
                      icon={isGameRunning ? "stop" : "play"}
                      loading={launching}
                      onClick={() => void handleLaunch()}
                    >
                      {isGameRunning ? "停止游戏" : "启动"}
                    </Button>
                  </div>
                </div>
              </>
            ) : (
              <EmptyState
                icon="package"
                title="暂无游戏实例"
                description="安装一个 Minecraft 版本，或从整合包导入，然后就可以在这里一键启动。"
                action={
                  <Button variant="primary" icon="download" onClick={() => openModal({ type: "install" })}>
                    安装第一个版本
                  </Button>
                }
              />
            )}
          </Card>

          <Card className="account-snapshot">
            <div className="row row--between">
              <p className="overline">Account</p>
              <button type="button" className="text-link" onClick={() => setSection("accounts")}>
                账户管理
                <Icon name="chevronRight" size={12} />
              </button>
            </div>
            <div className="account-snapshot__identity">
              <Avatar
                name={activeProfile?.name ?? null}
                skinUrl={activeProfile?.skinUrl ?? null}
                size={54}
                ring
              />
              <div className="account-snapshot__copy">
                <h3>{activeProfile?.name ?? "未登录"}</h3>
                <p className="caption">
                  {activeProfile
                    ? activeProfile.kind === "microsoft"
                      ? "Microsoft 账户"
                      : "离线账户"
                    : "登录后同步皮肤与玩家档案"}
                </p>
              </div>
              {activeProfile ? <Badge tone="success" dot>当前</Badge> : null}
            </div>
            <div className="account-snapshot__meta">
              <div>
                <span>账户总数</span>
                <strong>{accountCount}</strong>
              </div>
              <div>
                <span>Java 运行时</span>
                <strong>{javaRuntimes.length}</strong>
              </div>
            </div>
            <Button
              variant={activeProfile ? "secondary" : "primary"}
              icon={activeProfile ? "user" : "login"}
              block
              onClick={() => setSection("accounts")}
            >
              {activeProfile ? "切换账户" : "登录账户"}
            </Button>
          </Card>
        </div>

        <section className="stats-grid" aria-label="启动器统计">
          <div className="stat-cell">
            <span className="stat-cell__icon"><Icon name="layers" size={15} /></span>
            <div>
              <p className="stat-cell__label">实例数</p>
              <p className="stat-cell__value">{instances.length}</p>
            </div>
            <span className="stat-cell__hint">已创建</span>
          </div>
          <div className="stat-cell">
            <span className="stat-cell__icon"><Icon name="download" size={15} /></span>
            <div>
              <p className="stat-cell__label">已安装版本</p>
              <p className="stat-cell__value">{installedVersions}</p>
            </div>
            <span className="stat-cell__hint">{versions.length ? `共发现 ${versions.length} 个` : "去下载"}</span>
          </div>
          <div className="stat-cell">
            <span className="stat-cell__icon"><Icon name="coffee" size={15} /></span>
            <div>
              <p className="stat-cell__label">Java 运行时</p>
              <p className="stat-cell__value">{javaRuntimes.length}</p>
            </div>
            <span className="stat-cell__hint">{javaRuntimes[0]?.version ?? "未检测"}</span>
          </div>
          <div className="stat-cell">
            <span className="stat-cell__icon"><Icon name="user" size={15} /></span>
            <div>
              <p className="stat-cell__label">账户</p>
              <p className="stat-cell__value">{accountCount}</p>
            </div>
            <span className="stat-cell__hint">{activeProfile ? activeProfile.kind === "microsoft" ? "微软" : "离线" : "未登录"}</span>
          </div>
        </section>

        <div className="home-lower-grid">
          <section>
            <SectionHeader
              title="最近实例"
              caption="按最近启动时间排序"
              action={
                <button type="button" className="text-link" onClick={() => setSection("instances")}>
                  查看全部
                  <Icon name="chevronRight" size={12} />
                </button>
              }
            />
            {sortedInstances.length === 0 ? (
              <EmptyState
                icon="layers"
                title="暂无实例"
                description="安装游戏后会自动创建实例，也可以在游戏实例页手动新建。"
                action={
                  <Button variant="secondary" icon="plus" onClick={() => openModal({ type: "install" })}>
                    新建实例
                  </Button>
                }
              />
            ) : (
              <div className="recent-grid">
                {sortedInstances.slice(0, 3).map((instance) => (
                  <Card key={instance.id} className="recent-card" interactive onClick={() => setSelectedId(instance.id)}>
                    <div className="recent-card__top">
                      <span className="instance-mark" aria-hidden="true">
                        <Icon name={instance.loader ? "box" : "layers"} size={18} />
                      </span>
                      {instance.id === selected?.id ? <Badge tone="accent">已选</Badge> : null}
                    </div>
                    <h3 className="recent-card__name">{instance.name}</h3>
                    <p className="recent-card__version">
                      {minecraftVersion(instance)}
                      <span>·</span>
                      {loaderLabel(instance.loader)}
                    </p>
                    <div className="recent-card__meta">
                      <span><Icon name="memory" size={12} />{formatMemory(instance.memoryMiB)}</span>
                      <span><Icon name="clock" size={12} />{formatRelative(instance.lastLaunchedAt)}</span>
                    </div>
                    <button
                      type="button"
                      className="recent-card__open"
                      onClick={(event) => {
                        event.stopPropagation();
                        handleOpenInstance(instance.id);
                      }}
                    >
                      打开实例
                      <Icon name="chevronRight" size={12} />
                    </button>
                  </Card>
                ))}
              </div>
            )}
          </section>

          <section>
            <SectionHeader
              title="运行日志"
              caption={logPath ? logPath : "最近一次启动的日志"}
              action={
                <button type="button" className="text-link" onClick={() => setSection("logs")}>
                  全部日志
                  <Icon name="chevronRight" size={12} />
                </button>
              }
            />
            {logError ? (
              <Card className="log-preview-error">
                <div className="callout">
                  <Icon name="alert" size={15} className="callout__icon" />
                  <div>
                    <p>暂时无法读取日志</p>
                    <p className="mono log-preview-error__detail">{logError}</p>
                  </div>
                </div>
                <Button
                  variant="secondary"
                  size="sm"
                  icon="external"
                  onClick={() => {
                    void api.openLogsFolder().catch((error: unknown) => {
                      toast("error", "打开日志目录失败", error instanceof Error ? error.message : String(error));
                    });
                  }}
                >
                  打开日志目录
                </Button>
              </Card>
            ) : (
              <Terminal
                lines={logLines}
                title="LATEST.LOG"
                subtitle={logPath ? "最后 10 行" : "尚无日志"}
                emptyText="暂无日志内容。启动一次游戏后，这里会显示最新输出。"
                height={218}
                autoScroll={false}
                actions={
                  <Button variant="ghost" size="sm" onClick={() => setSection("logs")}>
                    展开
                  </Button>
                }
              />
            )}
          </section>
        </div>
      </div>
    </>
  );
}
