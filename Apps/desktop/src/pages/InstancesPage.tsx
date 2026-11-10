import { useMemo, useState } from "react";
import { Badge } from "../components/Badge";
import { Button, IconButton } from "../components/Button";
import { Card, SectionHeader } from "../components/Card";
import { ConfirmDialog } from "../components/Modal";
import { EmptyState } from "../components/EmptyState";
import { Icon } from "../components/Icons";
import { SearchInput } from "../components/Input";
import { PageHeader } from "../components/PageHeader";
import type { GameInstance } from "../services/api";
import { useApp } from "../stores/app";
import {
  formatDate,
  formatMemory,
  formatRelative,
  loaderLabel,
  minecraftVersion,
} from "../lib/format";

type SortKey = "recent" | "name" | "version";
type ViewMode = "grid" | "list";

export function InstancesPage() {
  const {
    instances,
    activeProfile,
    javaRuntimes,
    isGameRunning,
    deleteInstance,
    copyInstance,
    launchInstance,
    stopGame,
    openModal,
    setSection,
  } = useApp();

  const [query, setQuery] = useState("");
  const [sort, setSort] = useState<SortKey>("recent");
  const [view, setView] = useState<ViewMode>("grid");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<GameInstance | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [deleting, setDeleting] = useState(false);

  const filtered = useMemo(() => {
    const term = query.trim().toLowerCase();
    const rows = term
      ? instances.filter(
          (instance) =>
            instance.name.toLowerCase().includes(term) ||
            instance.versionId.toLowerCase().includes(term) ||
            minecraftVersion(instance).toLowerCase().includes(term) ||
            (instance.loader ?? "").toLowerCase().includes(term),
        )
      : [...instances];
    return rows.sort((a, b) => {
      if (sort === "name") return a.name.localeCompare(b.name, "zh-CN");
      if (sort === "version") return minecraftVersion(b).localeCompare(minecraftVersion(a), "zh-CN", { numeric: true });
      const left = a.lastLaunchedAt ? Date.parse(a.lastLaunchedAt) : 0;
      const right = b.lastLaunchedAt ? Date.parse(b.lastLaunchedAt) : 0;
      return right - left;
    });
  }, [instances, query, sort]);

  const selected = instances.find((instance) => instance.id === selectedId) ?? null;

  function launchBlocker(instance: GameInstance): string | null {
    if (isGameRunning) return null;
    if (activeProfile?.kind !== "microsoft") return "先在账户管理登录 Microsoft 账户";
    if (javaRuntimes.length === 0) return "先在设置中选择 Java 运行时";
    if (!instance.versionId) return "该实例还没有绑定 Minecraft 版本";
    return null;
  }

  async function handleLaunch(instance: GameInstance) {
    if (isGameRunning) {
      await stopGame();
      return;
    }
    setBusyId(instance.id);
    try {
      await launchInstance(instance.id);
    } finally {
      setBusyId(null);
    }
  }

  async function handleCopy(instance: GameInstance) {
    setBusyId(instance.id);
    try {
      await copyInstance(instance.id);
    } finally {
      setBusyId(null);
    }
  }

  async function handleDelete() {
    if (!deleteTarget) return;
    setDeleting(true);
    try {
      await deleteInstance(deleteTarget.id);
      if (selectedId === deleteTarget.id) setSelectedId(null);
      setDeleteTarget(null);
    } catch {
      // Error surface is handled by the store toast.
    } finally {
      setDeleting(false);
    }
  }

  return (
    <>
      <PageHeader
        eyebrow="Library / 实例库"
        title="游戏实例"
        subtitle="每个实例拥有独立的模组、资源包与世界。选择实例查看详情，或创建新的冒险。"
        actions={
          <>
            <Button variant="secondary" icon="archive" onClick={() => openModal({ type: "mrpack" })}>
              导入整合包
            </Button>
            <Button variant="primary" icon="plus" onClick={() => openModal({ type: "install" })}>
              新建实例
            </Button>
          </>
        }
      />

      <div className="page-stack">
        <div className="toolbar instances-toolbar">
          <SearchInput
            value={query}
            onChange={setQuery}
            placeholder="搜索实例名称、版本或加载器…"
            label="搜索实例"
            className="instances-toolbar__search"
          />
          <div className="instances-toolbar__right">
            <label className="sort-select">
              <span className="sr-only">排序方式</span>
              <select
                className="select"
                value={sort}
                onChange={(event) => setSort(event.target.value as SortKey)}
              >
                <option value="recent">最近启动</option>
                <option value="name">名称</option>
                <option value="version">游戏版本</option>
              </select>
              <Icon name="chevronDown" size={13} className="select-shell__icon" />
            </label>
            <div className="segmented" role="group" aria-label="视图模式">
              <button
                type="button"
                className={`segmented__item ${view === "grid" ? "is-active" : ""}`}
                aria-pressed={view === "grid"}
                onClick={() => setView("grid")}
              >
                <Icon name="grid" size={14} />
                <span className="sr-only">网格视图</span>
              </button>
              <button
                type="button"
                className={`segmented__item ${view === "list" ? "is-active" : ""}`}
                aria-pressed={view === "list"}
                onClick={() => setView("list")}
              >
                <Icon name="list" size={14} />
                <span className="sr-only">列表视图</span>
              </button>
            </div>
          </div>
        </div>

        {instances.length === 0 ? (
          <EmptyState
            icon="layers"
            title="暂无游戏实例"
            description="安装一个版本会自动创建实例，也可以导入 .mrpack 整合包。"
            action={
              <div className="row">
                <Button variant="secondary" icon="archive" onClick={() => openModal({ type: "mrpack" })}>
                  导入整合包
                </Button>
                <Button variant="primary" icon="plus" onClick={() => openModal({ type: "install" })}>
                  安装游戏
                </Button>
              </div>
            }
          />
        ) : (
          <div className={`instances-layout ${selected ? "has-detail" : ""}`}>
            <div className={`instance-grid ${view === "list" ? "is-list" : ""}`}>
              {filtered.map((instance) => {
                const running = isGameRunning;
                return (
                  <article
                    key={instance.id}
                    className={`card instance-card ${selectedId === instance.id ? "is-selected" : ""}`}
                  >
                    <button
                      type="button"
                      className="instance-card__main"
                      aria-pressed={selectedId === instance.id}
                      onClick={() => setSelectedId(instance.id)}
                    >
                      <span className="instance-card__top">
                        <span className="instance-mark" aria-hidden="true">
                          <Icon name={instance.loader ? "box" : "layers"} size={20} />
                        </span>
                        <span className="instance-card__badges">
                          {instance.loader ? <Badge tone="accent">{loaderLabel(instance.loader)}</Badge> : <Badge tone="outline">原版</Badge>}
                        </span>
                      </span>
                      <span className="instance-card__name">{instance.name}</span>
                      <span className="instance-card__version">
                        Minecraft {minecraftVersion(instance)}
                        {instance.loaderVersion ? ` · ${instance.loaderVersion}` : ""}
                      </span>
                      <span className="instance-card__meta">
                        <span><Icon name="memory" size={12} />{formatMemory(instance.memoryMiB)}</span>
                        <span><Icon name="box" size={12} />{instance.modCount ?? 0} 模组</span>
                        <span><Icon name="clock" size={12} />{formatRelative(instance.lastLaunchedAt)}</span>
                      </span>
                    </button>
                    <div className="instance-card__actions">
                      <Button
                        variant="primary"
                        size="sm"
                        icon={running ? "stop" : "play"}
                        loading={busyId === instance.id}
                        onClick={() => void handleLaunch(instance)}
                      >
                        {running ? "停止" : "启动"}
                      </Button>
                      <IconButton
                        icon="wrench"
                        label={`管理 ${instance.name}`}
                        onClick={() => openModal({ type: "tools", instanceId: instance.id, initialTab: "manage" })}
                      />
                      <IconButton
                        icon="copy"
                        label={`复制 ${instance.name}`}
                        onClick={() => void handleCopy(instance)}
                      />
                      <IconButton
                        icon="trash"
                        label={`删除 ${instance.name}`}
                        variant="danger"
                        onClick={() => setDeleteTarget(instance)}
                      />
                    </div>
                  </article>
                );
              })}
              {filtered.length === 0 ? (
                <Card className="instances-no-result">
                  <EmptyState
                    icon="search"
                    title="没有匹配的实例"
                    description={`没有找到与「${query}」相关的实例，换个关键词试试。`}
                    action={<Button variant="secondary" size="sm" onClick={() => setQuery("")}>清除搜索</Button>}
                    compact
                  />
                </Card>
              ) : null}
            </div>

            {selected ? (
              <aside className="instance-detail" aria-label="实例详情">
                <Card className="instance-detail__card">
                  <SectionHeader
                    title="实例详情"
                    caption={selected.id}
                    action={<IconButton icon="close" label="关闭详情" onClick={() => setSelectedId(null)} />}
                  />
                  <div className="instance-detail__hero">
                    <span className="instance-mark instance-mark--lg" aria-hidden="true">
                      <Icon name={selected.loader ? "box" : "layers"} size={24} />
                    </span>
                    <div>
                      <h3>{selected.name}</h3>
                      <p className="caption">Minecraft {minecraftVersion(selected)}</p>
                    </div>
                  </div>

                  <dl className="kv-list">
                    <div className="kv-row"><dt>加载器</dt><dd>{selected.loader ? `${loaderLabel(selected.loader)} ${selected.loaderVersion ?? ""}` : "原版"}</dd></div>
                    <div className="kv-row"><dt>内存分配</dt><dd>{formatMemory(selected.memoryMiB)}</dd></div>
                    <div className="kv-row"><dt>上次启动</dt><dd>{formatDate(selected.lastLaunchedAt, true)}</dd></div>
                    <div className="kv-row"><dt>JVM 参数</dt><dd className="instance-detail__jvm">{selected.jvmArguments || "使用默认参数"}</dd></div>
                    <div className="kv-row"><dt>实例路径</dt><dd className="truncate" title={selected.path ?? undefined}>{selected.path || "—"}</dd></div>
                    {selected.modpack ? (
                      <div className="kv-row"><dt>整合包</dt><dd>{selected.modpack.name} · {selected.modpack.version}</dd></div>
                    ) : null}
                  </dl>

                  <div className="instance-detail__counts">
                    <div><strong>{selected.modCount ?? 0}</strong><span>模组</span></div>
                    <div><strong>{selected.resourcePackCount ?? 0}</strong><span>资源包</span></div>
                    <div><strong>{selected.shaderCount ?? 0}</strong><span>光影</span></div>
                  </div>

                  <div className="instance-detail__actions">
                    <Button
                      variant="primary"
                      icon={isGameRunning ? "stop" : "play"}
                      block
                      onClick={() => void handleLaunch(selected)}
                    >
                      {isGameRunning ? "停止游戏" : "启动实例"}
                    </Button>
                    <div className="instance-detail__tools">
                      <Button variant="secondary" size="sm" icon="box" onClick={() => openModal({ type: "mods", instanceId: selected.id })}>模组</Button>
                      <Button variant="secondary" size="sm" icon="image" onClick={() => openModal({ type: "resourcepacks", instanceId: selected.id })}>资源包</Button>
                      <Button variant="secondary" size="sm" icon="sparkles" onClick={() => openModal({ type: "shaders", instanceId: selected.id })}>光影</Button>
                      <Button variant="secondary" size="sm" icon="sliders" onClick={() => openModal({ type: "graphics", instanceId: selected.id })}>图形</Button>
                      <Button variant="secondary" size="sm" icon="zap" onClick={() => openModal({ type: "performance", instanceId: selected.id })}>性能</Button>
                      <Button variant="secondary" size="sm" icon="wrench" onClick={() => openModal({ type: "tools", instanceId: selected.id, initialTab: "manage" })}>工具</Button>
                      {selected.modpack ? (
                        <Button variant="secondary" size="sm" icon="archive" onClick={() => openModal({ type: "modpackUpdate", instanceId: selected.id })}>整合包更新</Button>
                      ) : null}
                    </div>
                  </div>
                  {!isGameRunning && launchBlocker(selected) ? (
                    <button
                      type="button"
                      className="text-link instance-detail__account"
                      onClick={() => setSection(activeProfile?.kind === "microsoft" ? "settings" : "accounts")}
                    >
                      <Icon name="alert" size={12} />
                      {launchBlocker(selected)}
                    </button>
                  ) : null}
                </Card>
              </aside>
            ) : null}
          </div>
        )}
      </div>

      {deleteTarget ? (
        <ConfirmDialog
          title="删除实例"
          description={`确定删除「${deleteTarget.name}」吗？实例目录、模组与世界将被移除，此操作不可撤销。`}
          confirmLabel="删除实例"
          busy={deleting}
          onConfirm={() => void handleDelete()}
          onCancel={() => setDeleteTarget(null)}
        >
          <p className="caption">{minecraftVersion(deleteTarget)} · {formatMemory(deleteTarget.memoryMiB)}</p>
        </ConfirmDialog>
      ) : null}
    </>
  );
}
