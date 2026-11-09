import { useEffect, useMemo, useState } from "react";
import { Badge } from "../components/Badge";
import { Button, IconButton } from "../components/Button";
import { Card } from "../components/Card";
import { EmptyState } from "../components/EmptyState";
import { Icon } from "../components/Icons";
import { SearchInput } from "../components/Input";
import { PageHeader } from "../components/PageHeader";
import { ProgressBar } from "../components/ProgressBar";
import { api, type GameVersion, type InstallProgress } from "../services/api";
import { useApp } from "../stores/app";
import { formatBytes, formatDate, formatNumber, versionTypeLabel } from "../lib/format";

type FilterKey = "release" | "snapshot" | "all";

const filters: Array<{ key: FilterKey; label: string }> = [
  { key: "release", label: "正式版" },
  { key: "snapshot", label: "快照" },
  { key: "all", label: "全部" },
];

const phaseLabels: Record<string, string> = {
  prepare: "准备中",
  manifest: "读取版本清单",
  download: "下载文件",
  libraries: "下载依赖库",
  assets: "下载资源文件",
  natives: "解压本地库",
  verify: "校验文件",
  finish: "安装完成",
};

function phaseLabel(phase: string) {
  return phaseLabels[phase] ?? "正在安装";
}

function progressValue(progress: InstallProgress) {
  if (progress.totalBytes > 0) {
    return Math.min(100, (progress.downloadedBytes / progress.totalBytes) * 100);
  }
  if (progress.totalFiles > 0) {
    return Math.min(100, (progress.completedFiles / progress.totalFiles) * 100);
  }
  return 0;
}

export function DownloadsPage() {
  const {
    versions,
    versionsLoading,
    refreshVersions,
    refreshInstances,
    installedProgress,
    resetInstallProgress,
    toast,
  } = useApp();

  const [filter, setFilter] = useState<FilterKey>("release");
  const [query, setQuery] = useState("");
  const [refreshing, setRefreshing] = useState(false);
  const [installingId, setInstallingId] = useState<string | null>(null);

  useEffect(() => {
    if (versions.length === 0) void refreshVersions("all", true);
    // Only hydrate when the page is first opened; refreshes are explicit afterwards.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const filtered = useMemo(() => {
    const term = query.trim().toLowerCase();
    return versions
      .filter((version) => {
        if (filter === "release") return version.type === "release";
        if (filter === "snapshot") return version.type !== "release";
        return true;
      })
      .filter((version) => !term || version.id.toLowerCase().includes(term))
      .sort((a, b) => {
        const left = a.releaseTime ? Date.parse(a.releaseTime) : 0;
        const right = b.releaseTime ? Date.parse(b.releaseTime) : 0;
        return right - left;
      });
  }, [versions, filter, query]);

  async function handleRefresh() {
    setRefreshing(true);
    try {
      await api.refreshVersions();
      await refreshVersions("all", true);
      toast("success", "版本列表已刷新");
    } catch (error) {
      toast("error", "刷新版本列表失败", error instanceof Error ? error.message : String(error));
    } finally {
      setRefreshing(false);
    }
  }

  async function handleInstall(version: GameVersion) {
    setInstallingId(version.id);
    resetInstallProgress();
    try {
      await api.installVersion(version.id);
      toast("success", `Minecraft ${version.id} 已安装`);
      await Promise.all([refreshVersions("all", true), refreshInstances(true)]);
    } catch (error) {
      toast("error", `安装 ${version.id} 失败`, error instanceof Error ? error.message : String(error));
    } finally {
      setInstallingId(null);
    }
  }

  const counts = useMemo(
    () => ({
      release: versions.filter((version) => version.type === "release").length,
      snapshot: versions.filter((version) => version.type !== "release").length,
      all: versions.length,
    }),
    [versions],
  );

  return (
    <>
      <PageHeader
        eyebrow="Downloads / 版本仓库"
        title="版本下载"
        subtitle="浏览 Mojang 版本清单，安装原版游戏或为实例准备新的版本。安装进度会实时显示。"
        actions={
          <>
            <Button
              variant="secondary"
              icon="refresh"
              loading={refreshing}
              onClick={() => void handleRefresh()}
            >
              刷新列表
            </Button>
            <Button variant="primary" icon="download" onClick={() => void handleRefresh()}>
              检查更新
            </Button>
          </>
        }
      />

      <div className="page-stack">
        <div className="toolbar downloads-toolbar">
          <div className="tabs" role="tablist" aria-label="版本类型">
            {filters.map((item) => (
              <button
                key={item.key}
                type="button"
                role="tab"
                aria-selected={filter === item.key}
                className={`tab ${filter === item.key ? "is-active" : ""}`}
                onClick={() => setFilter(item.key)}
              >
                {item.label}
                <span className="tab__count">{counts[item.key]}</span>
              </button>
            ))}
          </div>
          <SearchInput
            value={query}
            onChange={setQuery}
            placeholder="搜索版本号，例如 1.21.4…"
            label="搜索版本"
            className="downloads-toolbar__search"
          />
        </div>

        {installedProgress ? (
          <Card className="install-progress-card" elevated>
            <div className="install-progress-card__head">
              <span className="install-progress-card__icon" aria-hidden="true">
                <Icon name="download" size={18} />
              </span>
              <div className="install-progress-card__copy">
                <div className="row row--between">
                  <h3>{phaseLabel(installedProgress.phase)}</h3>
                  <span className="mono">{Math.round(progressValue(installedProgress))}%</span>
                </div>
                <p className="caption">
                  {installedProgress.message || installedProgress.currentFile || "正在准备安装文件"}
                </p>
              </div>
              <IconButton icon="close" label="关闭安装进度" onClick={resetInstallProgress} />
            </div>
            <ProgressBar
              value={installedProgress.completedFiles}
              max={Math.max(installedProgress.totalFiles, 1)}
              label={`${installedProgress.completedFiles} / ${installedProgress.totalFiles} 个文件`}
            />
            <div className="install-progress-card__stats">
              <span>{installedProgress.completedFiles} / {installedProgress.totalFiles} 个文件</span>
              <span>
                {formatBytes(installedProgress.downloadedBytes)} / {formatBytes(installedProgress.totalBytes)}
              </span>
              <span className="mono truncate" title={installedProgress.currentFile ?? undefined}>
                {installedProgress.currentFile || "等待文件清单"}
              </span>
            </div>
          </Card>
        ) : null}

        <Card className="version-table">
          <div className="version-table__head" aria-hidden="true">
            <span>版本</span>
            <span>类型</span>
            <span>发布时间</span>
            <span>状态</span>
            <span className="version-table__action">操作</span>
          </div>
          {versionsLoading && versions.length === 0 ? (
            <div className="version-skeletons" aria-label="正在加载版本">
              {Array.from({ length: 6 }).map((_, index) => (
                <div className="version-skeleton" key={index} />
              ))}
            </div>
          ) : filtered.length === 0 ? (
            <EmptyState
              icon="download"
              title={query ? "没有匹配的版本" : "暂无版本数据"}
              description={
                query
                  ? `没有找到与「${query}」匹配的版本，换个关键词或切换类型。`
                  : "版本清单尚未加载。检查网络后刷新列表，或确认后端命令 list_versions 已实现。"
              }
              action={
                query ? (
                  <Button variant="secondary" size="sm" onClick={() => setQuery("")}>清除搜索</Button>
                ) : (
                  <Button variant="primary" icon="refresh" loading={refreshing} onClick={() => void handleRefresh()}>
                    刷新版本列表
                  </Button>
                )
              }
            />
          ) : (
            <div className="version-table__body">
              {filtered.map((version) => (
                <div className="version-row" key={version.id}>
                  <div className="version-row__id">
                    <span className="version-row__mark" aria-hidden="true">
                      <Icon name="package" size={15} />
                    </span>
                    <div>
                      <strong>{version.id}</strong>
                      {version.installed ? <span className="caption">已安装到本地</span> : <span className="caption">Minecraft Java Edition</span>}
                    </div>
                  </div>
                  <div>
                    <Badge tone={version.type === "release" ? "success" : version.type === "snapshot" ? "warning" : "neutral"}>
                      {versionTypeLabel(version.type)}
                    </Badge>
                  </div>
                  <span className="version-row__date">{formatDate(version.releaseTime)}</span>
                  <div>
                    {version.installed ? (
                      <Badge tone="accent" dot>已安装</Badge>
                    ) : (
                      <span className="tertiary caption">未安装</span>
                    )}
                  </div>
                  <div className="version-row__action">
                    {version.installed ? (
                      <Button variant="ghost" size="sm" icon="check" disabled>
                        已安装
                      </Button>
                    ) : (
                      <Button
                        variant="secondary"
                        size="sm"
                        icon="download"
                        loading={installingId === version.id}
                        disabled={installingId !== null && installingId !== version.id}
                        onClick={() => void handleInstall(version)}
                      >
                        安装
                      </Button>
                    )}
                  </div>
                </div>
              ))}
            </div>
          )}
        </Card>

        <p className="caption version-table__footnote">
          共 {formatNumber(filtered.length)} 个版本 · 安装会写入默认数据目录，可在设置中查看数据路径。
        </p>
      </div>
    </>
  );
}
