import { useEffect, useMemo, useState } from "react";
import { api, type DownloadSource, type GameVersion, type LoaderVersion, type VersionFilter } from "../../services/api";
import { useApp } from "../../stores/app";
import { Button } from "../Button";
import { Badge } from "../Badge";
import { EmptyState } from "../EmptyState";
import { Icon, type IconName } from "../Icons";
import { Select } from "../Select";
import { TextInput } from "../Input";
import { Modal } from "../Modal";
import { InstallProgressPanel, ModalError, errorMessage, formatDateTime } from "./shared";

type LoaderChoice = "vanilla" | "fabric" | "neoforge";

interface InstallWizardModalProps {
  presetVersionId?: string;
}

const FILTERS: { value: VersionFilter; label: string }[] = [
  { value: "release", label: "正式版" },
  { value: "snapshot", label: "快照" },
  { value: "all", label: "全部" },
];

const LOADERS: { value: LoaderChoice; title: string; description: string; icon: IconName }[] = [
  {
    value: "vanilla",
    title: "原版",
    description: "不加载任何模组加载器，获得最纯净的 Minecraft 体验。",
    icon: "box",
  },
  {
    value: "fabric",
    title: "Fabric",
    description: "轻量、更新迅速，适合绝大多数现代模组与整合包。",
    icon: "package",
  },
  {
    value: "neoforge",
    title: "NeoForge",
    description: "Forge 社区分支，适合大型科技与冒险整合包。",
    icon: "layers",
  },
];

export function InstallWizardModal({ presetVersionId }: InstallWizardModalProps) {
  const { closeModal, settings, refreshInstances, toast, installedProgress, resetInstallProgress } = useApp();
  const [step, setStep] = useState<1 | 2 | 3>(1);
  const [filter, setFilter] = useState<VersionFilter>("release");
  const [query, setQuery] = useState("");
  const [versions, setVersions] = useState<GameVersion[]>([]);
  const [versionsLoading, setVersionsLoading] = useState(true);
  const [versionsError, setVersionsError] = useState<string | null>(null);
  const [reloadToken, setReloadToken] = useState(0);
  const [selectedId, setSelectedId] = useState<string | null>(presetVersionId ?? null);
  const [loader, setLoader] = useState<LoaderChoice>("vanilla");
  const [loaderVersions, setLoaderVersions] = useState<LoaderVersion[]>([]);
  const [loaderVersion, setLoaderVersion] = useState("");
  const [loaderLoading, setLoaderLoading] = useState(false);
  const [loaderError, setLoaderError] = useState<string | null>(null);
  const [instanceName, setInstanceName] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    setVersionsLoading(true);
    setVersionsError(null);
    async function load() {
      try {
        let list = await api.listVersions(filter);
        if (list.length === 0) {
          await api.refreshVersions();
          list = await api.listVersions(filter);
        }
        if (active) setVersions(list);
      } catch (cause) {
        if (!active) return;
        try {
          const list = await api.listVersions(filter);
          if (active) setVersions(list);
        } catch {
          if (active) setVersionsError(errorMessage(cause));
        }
      } finally {
        if (active) setVersionsLoading(false);
      }
    }
    void load();
    return () => {
      active = false;
    };
  }, [filter, reloadToken]);

  useEffect(() => {
    if (!presetVersionId) return;
    setSelectedId(presetVersionId);
  }, [presetVersionId]);

  const selected = useMemo(
    () => versions.find((version) => version.id === selectedId) ?? null,
    [selectedId, versions],
  );

  useEffect(() => {
    if (!selected || loader === "vanilla") {
      setLoaderVersions([]);
      setLoaderVersion("");
      setLoaderError(null);
      return;
    }
    let active = true;
    setLoaderLoading(true);
    setLoaderError(null);
    api
      .listLoaderVersions(loader, selected.id)
      .then((list) => {
        if (!active) return;
        setLoaderVersions(list);
        const preferred = list.find((item) => item.stable) ?? list[0];
        setLoaderVersion(preferred ? preferred.version : "");
      })
      .catch((cause) => {
        if (active) {
          setLoaderVersions([]);
          setLoaderError(errorMessage(cause));
        }
      })
      .finally(() => {
        if (active) setLoaderLoading(false);
      });
    return () => {
      active = false;
    };
  }, [loader, selected]);

  const filtered = useMemo(() => {
    const needle = query.trim().toLowerCase();
    if (!needle) return versions;
    return versions.filter((version) => version.id.toLowerCase().includes(needle));
  }, [query, versions]);

  const canContinue = selected !== null && (loader === "vanilla" || loaderVersion !== "");

  async function install() {
    if (!selected) return;
    const name = instanceName.trim() || `${selected.id} 实例`;
    setBusy(true);
    setError(null);
    resetInstallProgress();
    let createdId: string | null = null;
    try {
      const instance = await api.createInstance(name, selected.id);
      createdId = instance.id;
      const source = settings.source as DownloadSource;
      await api.installVersion(selected.id, instance.id, source);
      if (loader !== "vanilla") {
        await api.installLoader(loader, instance.id, selected.id, loaderVersion);
      }
      await refreshInstances();
      resetInstallProgress();
      closeModal();
      toast(
        "success",
        "实例已创建",
        `${name} · ${selected.id}${loader === "vanilla" ? "" : ` · ${loader === "fabric" ? "Fabric" : "NeoForge"} ${loaderVersion}`}`,
      );
    } catch (cause) {
      if (createdId) {
        try {
          await api.deleteInstance(createdId);
          await refreshInstances();
        } catch {
          /* keep the original installation error */
        }
      }
      setError(errorMessage(cause));
    } finally {
      setBusy(false);
    }
  }

  const footer = (
    <div className="install-footer">
      <span className="install-footer__step">第 {step} / 3 步</span>
      <div className="install-footer__actions">
        {step > 1 ? (
          <Button variant="ghost" onClick={() => setStep((step - 1) as 1 | 2)} disabled={busy}>
            上一步
          </Button>
        ) : null}
        {step < 3 ? (
          <Button variant="primary" onClick={() => setStep((step + 1) as 2 | 3)} disabled={!canContinue}>
            继续
          </Button>
        ) : (
          <Button variant="primary" icon="download" loading={busy} onClick={() => void install()}>
            {busy ? "正在安装" : "创建并安装"}
          </Button>
        )}
      </div>
    </div>
  );

  return (
    <Modal
      title="安装新的 Minecraft"
      eyebrow="新建实例"
      subtitle="选择游戏版本与加载器，LingXi 会在后台完成下载、校验与配置。"
      onClose={closeModal}
      size="xl"
      dismissible={!busy}
      footer={footer}
    >
      <ol className="wizard-steps" aria-label="安装步骤">
        {[
          { index: 1, label: "游戏版本" },
          { index: 2, label: "模组加载器" },
          { index: 3, label: "确认安装" },
        ].map((item) => (
          <li
            key={item.index}
            className={[
              "wizard-step",
              step === item.index ? "is-current" : "",
              step > item.index ? "is-done" : "",
            ]
              .filter(Boolean)
              .join(" ")}
          >
            <span className="wizard-step__index">{step > item.index ? "✓" : item.index}</span>
            <span className="wizard-step__label">{item.label}</span>
          </li>
        ))}
      </ol>

      {step === 1 ? (
        <div className="wizard-panel">
          <div className="wizard-toolbar">
            <div className="segmented" role="tablist" aria-label="版本类型">
              {FILTERS.map((item) => (
                <button
                  key={item.value}
                  type="button"
                  role="tab"
                  aria-selected={filter === item.value}
                  className={["segmented__item", filter === item.value ? "is-active" : ""].filter(Boolean).join(" ")}
                  onClick={() => setFilter(item.value)}
                >
                  {item.label}
                </button>
              ))}
            </div>
            <div className="wizard-search">
              <TextInput
                aria-label="搜索版本"
                placeholder="搜索版本号，例如 1.21.4"
                value={query}
                onChange={(event) => setQuery(event.target.value)}
              />
            </div>
          </div>
          <ModalError error={versionsError} onRetry={() => setReloadToken((value) => value + 1)} />
          <div className="version-list" role="listbox" aria-label="Minecraft 版本">
            {versionsLoading ? (
              <div className="modal-loading">
                <span className="spinner" aria-hidden="true" />
                正在读取版本清单
              </div>
            ) : filtered.length === 0 ? (
              <EmptyState icon="download" title="没有匹配的版本" description="换一个筛选条件或搜索关键字试试。" compact />
            ) : (
              filtered.slice(0, 160).map((version) => {
                const checked = selectedId === version.id;
                return (
                  <button
                    key={version.id}
                    type="button"
                    role="option"
                    aria-selected={checked}
                    className={["version-row", checked ? "is-selected" : ""].filter(Boolean).join(" ")}
                    onClick={() => setSelectedId(version.id)}
                  >
                    <span className="version-row__radio" aria-hidden="true" />
                    <span className="version-row__main">
                      <span className="version-row__id">{version.id}</span>
                      <span className="version-row__meta">
                        {version.type === "snapshot" ? "快照" : version.type === "old_beta" ? "远古 Beta" : "正式版"}
                        {version.releaseTime ? ` · ${formatDateTime(version.releaseTime)}` : ""}
                      </span>
                    </span>
                    {version.installed ? <Badge tone="success">已下载</Badge> : null}
                  </button>
                );
              })
            )}
          </div>
        </div>
      ) : null}

      {step === 2 ? (
        <div className="wizard-panel">
          <div className="loader-grid">
            {LOADERS.map((item) => (
              <button
                key={item.value}
                type="button"
                className={["loader-card", loader === item.value ? "is-selected" : ""].filter(Boolean).join(" ")}
                aria-pressed={loader === item.value}
                onClick={() => setLoader(item.value)}
              >
                <span className="loader-card__head">
                  <span className="loader-card__icon">
                    <Icon name={item.icon} size={18} />
                  </span>
                  <span className="loader-card__title">{item.title}</span>
                  {loader === item.value ? <Badge tone="accent">已选</Badge> : null}
                </span>
                <span className="loader-card__description">{item.description}</span>
              </button>
            ))}
          </div>
          {loader !== "vanilla" ? (
            <div className="wizard-loader-version">
              <Select
                label={`${loader === "fabric" ? "Fabric" : "NeoForge"} 版本`}
                value={loaderVersion}
                onChange={setLoaderVersion}
                disabled={loaderLoading || loaderVersions.length === 0}
                hint={loaderLoading ? "正在获取加载器版本…" : "推荐选择稳定版本；加载器将安装到新实例中。"}
                options={
                  loaderVersions.length === 0
                    ? [{ value: "", label: loaderLoading ? "加载中…" : "没有可用版本" }]
                    : loaderVersions.map((item) => ({
                        value: item.version,
                        label: `${item.version}${item.stable ? " · 稳定" : ""}`,
                      }))
                }
              />
              {loaderError ? <ModalError error={loaderError} /> : null}
            </div>
          ) : (
            <p className="wizard-note">原版安装无需额外加载器，可直接进入下一步。</p>
          )}
        </div>
      ) : null}

      {step === 3 ? (
        <div className="wizard-panel">
          <div className="install-summary">
            <div className="install-summary__hero">
              <span className="install-summary__mark" aria-hidden="true">◆</span>
              <div>
                <p className="install-summary__eyebrow">即将安装</p>
                <h3 className="install-summary__title">
                  Minecraft {selected?.id}
                  {loader !== "vanilla" ? ` · ${loader === "fabric" ? "Fabric" : "NeoForge"} ${loaderVersion}` : ""}
                </h3>
              </div>
            </div>
            <dl className="install-summary__facts">
              <div>
                <dt>游戏版本</dt>
                <dd>{selected?.id ?? "—"}</dd>
              </div>
              <div>
                <dt>加载器</dt>
                <dd>{loader === "vanilla" ? "原版" : loader === "fabric" ? "Fabric" : "NeoForge"}</dd>
              </div>
              <div>
                <dt>下载源</dt>
                <dd>{settings.source === "auto" ? "自动选择" : settings.source === "official" ? "官方源" : settings.source === "mirror" ? "镜像源" : "本地缓存"}</dd>
              </div>
              <div>
                <dt>预计占用</dt>
                <dd>约 500 MiB – 1.2 GiB</dd>
              </div>
            </dl>
          </div>
          <TextInput
            label="实例名称"
            value={instanceName}
            placeholder={`${selected?.id ?? "Minecraft"} 实例`}
            onChange={(event) => setInstanceName(event.target.value)}
            maxLength={60}
            hint="实例名称仅用于本机识别，可以随时在实例设置中修改。"
          />
          <ModalError error={error} />
          {busy ? <InstallProgressPanel progress={installedProgress} label="正在准备 Minecraft 文件" /> : null}
        </div>
      ) : null}
    </Modal>
  );
}
