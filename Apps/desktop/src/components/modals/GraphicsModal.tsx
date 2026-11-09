import { useEffect, useMemo, useState } from "react";
import {
  api,
  type GraphicsPreset,
  type GraphicsSettings,
  type GraphicsSnapshot,
  type ParticleMode,
} from "../../services/api";
import { useApp } from "../../stores/app";
import { Badge } from "../Badge";
import { Button } from "../Button";
import { Icon } from "../Icons";
import { Modal } from "../Modal";
import { ModalError, errorMessage, useInstance } from "./shared";

interface GraphicsModalProps {
  instanceId: string;
}

const DEFAULT_GRAPHICS: GraphicsSettings = {
  preset: "fancy",
  renderDistance: 12,
  simulationDistance: 12,
  maxFps: 120,
  guiScale: 0,
  particles: "all",
  clouds: true,
  entityShadows: true,
  ambientOcclusion: true,
  vsync: true,
  fullscreen: false,
};

const PRESETS: { value: GraphicsPreset; title: string; description: string; icon: "zap" | "sparkles" | "monitor" }[] = [
  {
    value: "fast",
    title: "流畅",
    description: "最低画质开销，适合核显与远程串流。",
    icon: "zap",
  },
  {
    value: "fancy",
    title: "精致",
    description: "原版完整画面效果，性能与观感平衡。",
    icon: "sparkles",
  },
  {
    value: "fabulous",
    title: "华丽",
    description: "启用半透明与高级光影，需要较强显卡。",
    icon: "monitor",
  },
];

const PARTICLES: { value: ParticleMode; label: string }[] = [
  { value: "all", label: "全部" },
  { value: "decreased", label: "减少" },
  { value: "minimal", label: "最少" },
];

const GUI_SCALES = [
  { value: 0, label: "自动" },
  { value: 1, label: "1x" },
  { value: 2, label: "2x" },
  { value: 3, label: "3x" },
  { value: 4, label: "4x" },
];

type ToggleKey = "clouds" | "entityShadows" | "ambientOcclusion" | "vsync" | "fullscreen";

const TOGGLES: { key: ToggleKey; title: string; description: string }[] = [
  { key: "clouds", title: "云层", description: "渲染天空中的体积云。" },
  { key: "entityShadows", title: "实体阴影", description: "为生物与掉落物投射阴影。" },
  { key: "ambientOcclusion", title: "环境光遮蔽", description: "增强方块接缝处的明暗层次。" },
  { key: "vsync", title: "垂直同步", description: "消除画面撕裂，但可能限制帧率。" },
  { key: "fullscreen", title: "全屏启动", description: "启动游戏时直接进入全屏模式。" },
];

export function GraphicsModal({ instanceId }: GraphicsModalProps) {
  const { closeModal, refreshInstances, toast } = useApp();
  const instance = useInstance(instanceId);
  const [snapshot, setSnapshot] = useState<GraphicsSnapshot | null>(null);
  const [draft, setDraft] = useState<GraphicsSettings>(DEFAULT_GRAPHICS);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [reloadToken, setReloadToken] = useState(0);

  async function load() {
    setLoading(true);
    setError(null);
    try {
      const next = await api.readInstanceGraphics(instanceId);
      setSnapshot(next);
      setDraft(next.settings);
    } catch (cause) {
      setError(errorMessage(cause));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [instanceId, reloadToken]);

  const dirty = useMemo(() => {
    if (!snapshot) return false;
    return JSON.stringify(snapshot.settings) !== JSON.stringify(draft);
  }, [snapshot, draft]);

  function update<K extends keyof GraphicsSettings>(key: K, value: GraphicsSettings[K]) {
    setDraft((current) => ({ ...current, [key]: value }));
  }

  async function save() {
    setSaving(true);
    setError(null);
    try {
      const next = await api.saveInstanceGraphics(instanceId, draft);
      setSnapshot(next);
      setDraft(next.settings);
      await refreshInstances(true);
      toast("success", "图形设置已保存", "将在下一次启动游戏时生效");
    } catch (cause) {
      setError(errorMessage(cause));
    } finally {
      setSaving(false);
    }
  }

  async function openDirectory() {
    const target = snapshot?.exists ? snapshot.path : instance?.path;
    if (!target) return;
    try {
      await api.revealPath(target);
    } catch (cause) {
      toast("error", "无法打开目录", errorMessage(cause));
    }
  }

  return (
    <Modal
      title="图形设置"
      eyebrow={instance?.name ?? "实例"}
      subtitle="直接编辑实例的 options.txt，未知选项会原样保留，保存前自动生成一份备份。"
      onClose={closeModal}
      size="lg"
      footer={
        <div className="modal-footer__row">
          <span className="modal-footer__note">保存后请在下次启动游戏时生效。</span>
          <div className="modal-footer__actions">
            <Button variant="ghost" onClick={closeModal}>取消</Button>
            <Button variant="primary" icon="save" loading={saving} disabled={!dirty || loading || !snapshot} onClick={() => void save()}>
              保存设置
            </Button>
          </div>
        </div>
      }
    >
      {loading ? (
        <div className="modal-loading"><span className="spinner" aria-hidden="true" />正在读取 options.txt</div>
      ) : error && !snapshot ? (
        <ModalError error={error} onRetry={() => setReloadToken((value) => value + 1)} />
      ) : (
        <div className="graphics-layout">
          {error ? <ModalError error={error} onRetry={() => void load()} /> : null}

          <div className="graphics-head">
            <div>
              <p className="graphics-head__label">配置文件</p>
              <p className="graphics-head__path" title={snapshot?.path}>{snapshot?.path || "尚未生成"}</p>
            </div>
            <div className="graphics-head__actions">
              <Badge tone={snapshot?.exists ? "success" : "neutral"}>{snapshot?.exists ? "已存在" : "待生成"}</Badge>
              <Button variant="secondary" size="sm" icon="folder" onClick={() => void openDirectory()} disabled={!snapshot?.exists && !instance?.path}>
                打开目录
              </Button>
            </div>
          </div>

          <section className="graphics-section">
            <div className="graphics-section__head">
              <h3>画质预设</h3>
              <Button variant="ghost" size="sm" icon="refresh" onClick={() => setDraft(DEFAULT_GRAPHICS)}>恢复默认值</Button>
            </div>
            <div className="graphics-presets">
              {PRESETS.map((preset) => (
                <button
                  key={preset.value}
                  type="button"
                  className={`graphics-preset ${draft.preset === preset.value ? "is-active" : ""}`}
                  aria-pressed={draft.preset === preset.value}
                  onClick={() => update("preset", preset.value)}
                >
                  <span className="graphics-preset__icon"><Icon name={preset.icon} size={18} /></span>
                  <span className="graphics-preset__body">
                    <span className="graphics-preset__title">{preset.title}</span>
                    <span className="graphics-preset__description">{preset.description}</span>
                  </span>
                </button>
              ))}
            </div>
          </section>

          <section className="graphics-section">
            <div className="graphics-section__head"><h3>视距与帧率</h3></div>
            <div className="graphics-sliders">
              <label className="graphics-slider">
                <span className="graphics-slider__head">
                  <span>渲染距离</span>
                  <span className="graphics-slider__value">{draft.renderDistance} 区块</span>
                </span>
                <input
                  type="range"
                  min={2}
                  max={32}
                  step={1}
                  value={draft.renderDistance}
                  onChange={(event) => update("renderDistance", Number(event.target.value))}
                />
                <span className="graphics-slider__hint">决定远景与区块加载范围，最影响帧率。</span>
              </label>
              <label className="graphics-slider">
                <span className="graphics-slider__head">
                  <span>模拟距离</span>
                  <span className="graphics-slider__value">{draft.simulationDistance} 区块</span>
                </span>
                <input
                  type="range"
                  min={2}
                  max={32}
                  step={1}
                  value={draft.simulationDistance}
                  onChange={(event) => update("simulationDistance", Number(event.target.value))}
                />
                <span className="graphics-slider__hint">影响实体与红石更新的范围，通常不高于渲染距离。</span>
              </label>
              <label className="graphics-slider">
                <span className="graphics-slider__head">
                  <span>最大帧率</span>
                  <span className="graphics-slider__value">{draft.maxFps} FPS</span>
                </span>
                <input
                  type="range"
                  min={1}
                  max={260}
                  step={5}
                  value={Math.min(draft.maxFps, 260)}
                  onChange={(event) => update("maxFps", Number(event.target.value))}
                />
                <span className="graphics-slider__hint">上限受显示器刷新率与垂直同步影响。</span>
              </label>
            </div>
          </section>

          <section className="graphics-section">
            <div className="graphics-section__head"><h3>界面与粒子</h3></div>
            <div className="graphics-choice-row">
              <div className="graphics-choice">
                <span className="graphics-choice__label">界面缩放</span>
                <div className="segmented" role="group" aria-label="界面缩放">
                  {GUI_SCALES.map((scale) => (
                    <button
                      key={scale.value}
                      type="button"
                      className={`segmented__item ${draft.guiScale === scale.value ? "is-active" : ""}`}
                      aria-pressed={draft.guiScale === scale.value}
                      onClick={() => update("guiScale", scale.value)}
                    >
                      {scale.label}
                    </button>
                  ))}
                </div>
              </div>
              <div className="graphics-choice">
                <span className="graphics-choice__label">粒子效果</span>
                <div className="segmented" role="group" aria-label="粒子效果">
                  {PARTICLES.map((particle) => (
                    <button
                      key={particle.value}
                      type="button"
                      className={`segmented__item ${draft.particles === particle.value ? "is-active" : ""}`}
                      aria-pressed={draft.particles === particle.value}
                      onClick={() => update("particles", particle.value)}
                    >
                      {particle.label}
                    </button>
                  ))}
                </div>
              </div>
            </div>
          </section>

          <section className="graphics-section">
            <div className="graphics-section__head"><h3>画面开关</h3></div>
            <div className="graphics-toggles">
              {TOGGLES.map((toggle) => (
                <button
                  key={toggle.key}
                  type="button"
                  role="switch"
                  aria-checked={draft[toggle.key]}
                  className={`graphics-toggle ${draft[toggle.key] ? "is-on" : ""}`}
                  onClick={() => update(toggle.key, !draft[toggle.key])}
                >
                  <span className="graphics-toggle__body">
                    <span className="graphics-toggle__title">{toggle.title}</span>
                    <span className="graphics-toggle__description">{toggle.description}</span>
                  </span>
                  <span className={`switch ${draft[toggle.key] ? "is-on" : ""}`} aria-hidden="true">
                    <span className="switch__thumb" />
                  </span>
                </button>
              ))}
            </div>
          </section>

          <p className="graphics-note">
            <Icon name="info" size={14} />
            图形设置只影响当前实例；整合包自带的光影与资源包请在对应面板中管理。
          </p>
        </div>
      )}
    </Modal>
  );
}
