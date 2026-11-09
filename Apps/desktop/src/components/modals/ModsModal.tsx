import { useEffect, useMemo, useState } from "react";
import { api, type InstalledMod, type ModSearchHit } from "../../services/api";
import { useApp } from "../../stores/app";
import { Badge } from "../Badge";
import { Button } from "../Button";
import { EmptyState } from "../EmptyState";
import { Icon } from "../Icons";
import { SearchInput } from "../Input";
import { Modal, ConfirmDialog } from "../Modal";
import { Select } from "../Select";
import { InstallProgressPanel, ModalError, errorMessage, useInstance } from "./shared";

interface ModsModalProps {
  instanceId: string;
}

type Tab = "installed" | "search";

export function ModsModal({ instanceId }: ModsModalProps) {
  const { closeModal, toast, refreshInstances, installedProgress } = useApp();
  const instance = useInstance(instanceId);
  const [tab, setTab] = useState<Tab>("installed");
  const [mods, setMods] = useState<InstalledMod[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [hits, setHits] = useState<ModSearchHit[]>([]);
  const [searching, setSearching] = useState(false);
  const [searchError, setSearchError] = useState<string | null>(null);
  const [gameVersion, setGameVersion] = useState(instance?.versionId ?? "");
  const [loader, setLoader] = useState(instance?.loader ?? "fabric");
  const [busyId, setBusyId] = useState<string | null>(null);
  const [updating, setUpdating] = useState(false);
  const [pendingDelete, setPendingDelete] = useState<InstalledMod | null>(null);

  async function loadMods() {
    setLoading(true);
    setError(null);
    try {
      setMods(await api.listMods(instanceId));
    } catch (cause) {
      setError(errorMessage(cause));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void loadMods();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [instanceId]);

  useEffect(() => {
    if (instance?.versionId) setGameVersion(instance.versionId);
    if (instance?.loader) setLoader(instance.loader);
  }, [instance?.versionId, instance?.loader]);

  const enabledCount = useMemo(() => mods.filter((item) => item.enabled).length, [mods]);

  async function runSearch() {
    setSearching(true);
    setSearchError(null);
    try {
      const response = await api.searchModrinth({
        query: query.trim(),
        gameVersion: gameVersion || undefined,
        loader: loader || undefined,
        limit: 24,
      });
      setHits(response.hits);
    } catch (cause) {
      setSearchError(errorMessage(cause));
    } finally {
      setSearching(false);
    }
  }

  async function installHit(hit: ModSearchHit) {
    const versionId = hit.latestVersionId;
    if (!versionId) {
      setSearchError(`「${hit.title}」没有返回可安装的版本，请换一个搜索结果。`);
      return;
    }
    setBusyId(hit.projectId);
    setSearchError(null);
    try {
      await api.installMod(instanceId, versionId);
      await loadMods();
      await refreshInstances(true);
      toast("success", "模组已安装", hit.title);
    } catch (cause) {
      setSearchError(errorMessage(cause));
    } finally {
      setBusyId(null);
    }
  }

  async function toggle(mod: InstalledMod) {
    setBusyId(mod.projectId);
    try {
      await api.toggleMod(instanceId, mod.projectId, !mod.enabled);
      setMods((current) =>
        current.map((item) => (item.projectId === mod.projectId ? { ...item, enabled: !item.enabled } : item)),
      );
    } catch (cause) {
      toast("error", "切换模组失败", errorMessage(cause));
    } finally {
      setBusyId(null);
    }
  }

  async function checkUpdates() {
    setUpdating(true);
    try {
      const next = await api.checkModUpdates(instanceId);
      setMods(next);
      const count = next.filter((item) => item.updateAvailable).length;
      toast(count > 0 ? "info" : "success", count > 0 ? `发现 ${count} 个模组更新` : "所有模组都是最新版本");
    } catch (cause) {
      toast("error", "检查更新失败", errorMessage(cause));
    } finally {
      setUpdating(false);
    }
  }

  async function applyUpdate(mod: InstalledMod) {
    setBusyId(mod.projectId);
    try {
      await api.updateMod(instanceId, mod.projectId);
      await loadMods();
      toast("success", "模组已更新", mod.name);
    } catch (cause) {
      toast("error", "更新模组失败", errorMessage(cause));
    } finally {
      setBusyId(null);
    }
  }

  async function removeMod(mod: InstalledMod) {
    setBusyId(mod.projectId);
    try {
      await api.deleteMod(instanceId, mod.projectId);
      setMods((current) => current.filter((item) => item.projectId !== mod.projectId));
      await refreshInstances(true);
      toast("success", "模组已移除", mod.name);
      setPendingDelete(null);
    } catch (cause) {
      toast("error", "移除模组失败", errorMessage(cause));
    } finally {
      setBusyId(null);
    }
  }

  return (
    <>
      <Modal
        title="模组管理"
        eyebrow={instance?.name ?? "实例"}
        subtitle={`${mods.length} 个模组 · ${enabledCount} 个已启用 · 从 Modrinth 搜索和安装`}
        onClose={closeModal}
        size="wide"
        bodyClassName="modal-panel--flush"
      >
        <div className="modal-tabs">
          <button type="button" className={tab === "installed" ? "is-active" : ""} onClick={() => setTab("installed")}>
            已安装
            <span className="modal-tabs__count">{mods.length}</span>
          </button>
          <button type="button" className={tab === "search" ? "is-active" : ""} onClick={() => setTab("search")}>
            浏览 Modrinth
          </button>
          <div className="modal-tabs__spacer" />
          <Button size="sm" variant="ghost" icon="refresh" loading={updating} onClick={() => void checkUpdates()}>
            检查更新
          </Button>
        </div>

        {tab === "installed" ? (
          <div className="modal-scroll">
            {loading ? (
              <div className="modal-loading"><span className="spinner" aria-hidden="true" />正在读取模组</div>
            ) : error ? (
              <div className="modal-pad"><ModalError error={error} onRetry={() => void loadMods()} /></div>
            ) : mods.length === 0 ? (
              <div className="modal-pad">
                <EmptyState
                  icon="package"
                  title="这个实例还没有模组"
                  description="到 Modrinth 搜索并安装喜欢的模组，或者导入整合包。"
                  action={<Button variant="primary" icon="search" onClick={() => setTab("search")}>浏览 Modrinth</Button>}
                />
              </div>
            ) : (
              <ul className="entry-list">
                {mods.map((mod) => (
                  <li key={mod.projectId} className="entry-row">
                    <span className="entry-row__icon entry-row__icon--image">
                      {mod.iconUrl ? <img src={mod.iconUrl} alt="" loading="lazy" /> : <Icon name="package" size={18} />}
                    </span>
                    <div className="entry-row__body">
                      <div className="entry-row__title">
                        <span>{mod.name}</span>
                        {mod.updateAvailable ? <Badge tone="accent">可更新</Badge> : null}
                        {!mod.enabled ? <Badge tone="outline">已停用</Badge> : null}
                      </div>
                      <p className="entry-row__meta">
                        {mod.versionNumber ? `v${mod.versionNumber}` : "未知版本"}
                        {mod.fileName ? ` · ${mod.fileName}` : ""}
                      </p>
                    </div>
                    <div className="entry-row__actions">
                      {mod.updateAvailable ? (
                        <Button
                          size="sm"
                          variant="soft"
                          loading={busyId === mod.projectId}
                          onClick={() => void applyUpdate(mod)}
                        >
                          更新
                        </Button>
                      ) : null}
                      <button
                        type="button"
                        role="switch"
                        aria-checked={mod.enabled}
                        aria-label={mod.enabled ? `停用 ${mod.name}` : `启用 ${mod.name}`}
                        className={`switch ${mod.enabled ? "is-on" : ""}`}
                        disabled={busyId === mod.projectId}
                        onClick={() => void toggle(mod)}
                      >
                        <span className="switch__thumb" aria-hidden="true" />
                      </button>
                      <Button
                        size="sm"
                        variant="ghost"
                        icon="trash"
                        aria-label={`移除 ${mod.name}`}
                        onClick={() => setPendingDelete(mod)}
                      />
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </div>
        ) : (
          <div className="modal-scroll">
            <div className="mod-search-bar">
              <SearchInput value={query} onChange={setQuery} placeholder="搜索模组、光影或整合包" label="搜索 Modrinth" />
              <Button variant="primary" icon="search" loading={searching} onClick={() => void runSearch()}>
                搜索
              </Button>
            </div>
            <div className="mod-search-filters">
              <Select
                value={gameVersion}
                onChange={setGameVersion}
                ariaLabel="游戏版本"
                options={[
                  { value: "", label: "所有游戏版本" },
                  ...(instance?.versionId ? [{ value: instance.versionId, label: instance.versionId }] : []),
                  ...["1.21.4", "1.21.1", "1.20.6", "1.20.1", "1.19.2", "1.18.2", "1.16.5"]
                    .filter((value) => value !== instance?.versionId)
                    .map((value) => ({ value, label: value })),
                ]}
              />
              <Select
                value={loader}
                onChange={setLoader}
                ariaLabel="模组加载器"
                options={[
                  { value: "", label: "所有加载器" },
                  { value: "fabric", label: "Fabric" },
                  { value: "neoforge", label: "NeoForge" },
                  { value: "forge", label: "Forge" },
                  { value: "quilt", label: "Quilt" },
                ]}
              />
            </div>
            {searchError ? <div className="modal-pad"><ModalError error={searchError} /></div> : null}
            {searching ? (
              <div className="modal-loading"><span className="spinner" aria-hidden="true" />正在搜索 Modrinth</div>
            ) : hits.length === 0 ? (
              <div className="modal-pad">
                <EmptyState
                  icon="globe"
                  title={query ? "没有找到匹配的项目" : "搜索 Modrinth"}
                  description={query ? "换个关键字或放宽版本、加载器筛选。" : "输入模组名称、作者或功能关键词，结果来自 Modrinth 官方 API。"}
                  compact
                />
              </div>
            ) : (
              <ul className="entry-list">
                {hits.map((hit) => (
                  <li key={hit.projectId} className="entry-row">
                    <span className="entry-row__icon entry-row__icon--image">
                      {hit.iconUrl ? <img src={hit.iconUrl} alt="" loading="lazy" /> : <Icon name="globe" size={18} />}
                    </span>
                    <div className="entry-row__body">
                      <div className="entry-row__title">
                        <span>{hit.title}</span>
                        {hit.loader ? <Badge tone="outline">{hit.loader}</Badge> : null}
                      </div>
                      <p className="entry-row__description">{hit.description ?? "暂无简介"}</p>
                      <p className="entry-row__meta">
                        {hit.downloads ? `${hit.downloads.toLocaleString("zh-CN")} 次下载` : "下载量未知"}
                        {hit.follows ? ` · ${hit.follows.toLocaleString("zh-CN")} 关注` : ""}
                        {hit.versions && hit.versions.length > 0 ? ` · ${hit.versions.slice(0, 3).join(", ")}` : ""}
                      </p>
                    </div>
                    <div className="entry-row__actions">
                      <Button
                        size="sm"
                        variant="secondary"
                        icon="plus"
                        loading={busyId === hit.projectId}
                        disabled={!hit.latestVersionId}
                        title={hit.latestVersionId ? "安装最新兼容版本" : "该结果没有可用的兼容版本"}
                        onClick={() => void installHit(hit)}
                      >
                        安装
                      </Button>
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </div>
        )}
        {busyId && tab === "search" ? (
          <div className="modal-sticky-progress"><InstallProgressPanel progress={installedProgress} label="正在下载模组" /></div>
        ) : null}
      </Modal>

      {pendingDelete ? (
        <ConfirmDialog
          title="移除模组"
          description={`确定要从「${instance?.name ?? "实例"}」中移除 ${pendingDelete.name} 吗？模组文件会被删除，存档不会受影响。`}
          confirmLabel="移除"
          busy={busyId === pendingDelete.projectId}
          onConfirm={() => void removeMod(pendingDelete)}
          onCancel={() => setPendingDelete(null)}
        />
      ) : null}
    </>
  );
}
