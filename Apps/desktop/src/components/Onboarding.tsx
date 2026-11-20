import { useEffect, useState } from "react";
import { Badge } from "./Badge";
import { Button } from "./Button";
import { FoxMark, Icon } from "./Icons";
import { Field, TextInput } from "./Input";
import { Modal } from "./Modal";
import { Select } from "./Select";
import { api, type JavaRuntime } from "../services/api";
import { useApp } from "../stores/app";

const STORAGE_KEY = "lingxi.onboarded";

const steps = [
  { index: 1, label: "欢迎" },
  { index: 2, label: "Java" },
  { index: 3, label: "游戏目录" },
  { index: 4, label: "账户" },
  { index: 5, label: "完成" },
];

export function hasCompletedOnboarding(): boolean {
  try {
    return localStorage.getItem(STORAGE_KEY) === "1";
  } catch {
    return true;
  }
}

function rememberOnboarding() {
  try {
    localStorage.setItem(STORAGE_KEY, "1");
  } catch {
    // Private storage is not a reason to block the launcher.
  }
}

/**
 * First-run guide shown once per install. Everything it collects is optional:
 * the launcher falls back to the same defaults the settings page uses.
 */
export function Onboarding() {
  const {
    settings,
    saveSettings,
    javaRuntimes,
    createLocalAccount,
    setActiveAccount,
    dataRoot,
    gameRoot,
    toast,
  } = useApp();

  const [open, setOpen] = useState(() => !hasCompletedOnboarding());
  const [step, setStep] = useState(1);
  const [detected, setDetected] = useState<JavaRuntime[]>(javaRuntimes);
  const [javaPath, setJavaPath] = useState(settings.javaPath ?? "");
  const [detecting, setDetecting] = useState(false);
  const [picking, setPicking] = useState(false);
  const [root, setRoot] = useState(settings.gameRoot ?? "");
  const [playerName, setPlayerName] = useState("");
  const [creating, setCreating] = useState(false);
  const [finishing, setFinishing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (javaRuntimes.length > 0) setDetected(javaRuntimes);
  }, [javaRuntimes]);

  if (!open) return null;

  const javaOptions = [
    { value: "", label: "自动选择（推荐）" },
    ...detected.map((runtime) => ({
      value: runtime.path,
      label: (runtime.version || "Java") + (runtime.majorVersion ? " · Java " + runtime.majorVersion : ""),
    })),
  ];

  const nameLength = Array.from(playerName.trim()).length;
  const canCreateAccount = nameLength >= 3 && nameLength <= 16 && !creating;

  async function handleDetect() {
    setDetecting(true);
    setError(null);
    try {
      const runtimes = await api.detectJava();
      const list = Array.isArray(runtimes) ? runtimes : [];
      setDetected(list);
      toast("success", "Java 检测完成", "发现 " + list.length + " 个可用运行时");
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setDetecting(false);
    }
  }

  async function handlePickRoot() {
    setPicking(true);
    try {
      const picked = await api.browseFolder();
      if (picked) setRoot(picked);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setPicking(false);
    }
  }

  async function handleCreateAccount() {
    const name = playerName.trim();
    if (nameLength < 3 || nameLength > 16) {
      setError("玩家名称需要 3-16 个字符。");
      return;
    }
    setCreating(true);
    setError(null);
    try {
      const account = await createLocalAccount(name);
      if (account) {
        await setActiveAccount("local", account.name);
        setPlayerName("");
      }
    } finally {
      setCreating(false);
    }
  }

  async function finish() {
    setFinishing(true);
    setError(null);
    try {
      const saved = await saveSettings({
        javaPath: javaPath || null,
        gameRoot: root || null,
      });
      if (!saved) {
        setError("设置保存失败，请重试或跳过引导。");
        return;
      }
      rememberOnboarding();
      setOpen(false);
    } finally {
      setFinishing(false);
    }
  }

  function skip() {
    rememberOnboarding();
    setOpen(false);
  }

  const isLast = step === steps.length;
  const footer = (
    <div className="modal-footer__row">
      <Button variant="ghost" onClick={skip} disabled={finishing}>
        跳过引导
      </Button>
      <div className="modal-footer__actions">
        {step > 1 ? (
          <Button variant="secondary" icon="arrowLeft" onClick={() => setStep((value) => value - 1)} disabled={finishing}>
            上一步
          </Button>
        ) : null}
        {isLast ? (
          <Button variant="primary" icon="check" loading={finishing} onClick={() => void finish()}>
            开始使用 LingXi
          </Button>
        ) : (
          <Button variant="primary" trailingIcon="chevronRight" onClick={() => setStep((value) => value + 1)}>
            下一步
          </Button>
        )}
      </div>
    </div>
  );

  return (
    <Modal
      title="欢迎使用泠溪（LingXiFox）启动器"
      eyebrow="首次启动"
      subtitle="三步完成基础配置，之后随时可以在设置里修改。"
      onClose={skip}
      size="lg"
      dismissible={!finishing}
      footer={footer}
    >
      <ol className="onboarding-steps" aria-label="引导步骤">
        {steps.map((item) => (
          <li
            key={item.index}
            className={[
              "onboarding-step",
              step === item.index ? "is-active" : "",
              step > item.index ? "is-done" : "",
            ]
              .filter(Boolean)
              .join(" ")}
          >
            <span className="onboarding-step__index">{step > item.index ? "✓" : item.index}</span>
            <span className="onboarding-step__label">{item.label}</span>
          </li>
        ))}
      </ol>

      <div className="onboarding-panel">
        {step === 1 ? (
          <>
            <div className="onboarding-hero">
              <span className="onboarding-hero__mark">
                <FoxMark size={46} />
              </span>
              <div>
                <p className="onboarding-hero__title">Rust 启动核心 · Tauri 2 桌面壳</p>
                <p className="onboarding-hero__subtitle">
                  每个实例拥有独立的版本、模组、光影与存档目录，下载与校验由 Rust 核心完成。
                </p>
              </div>
            </div>
            <ul className="onboarding-list">
              <li>
                <Icon name="download" size={15} />
                <span>在「版本下载」里挑选游戏版本与加载器，安装过程可以随时取消。</span>
              </li>
              <li>
                <Icon name="layers" size={15} />
                <span>「游戏实例」集中管理内存、窗口、进程优先级与启动前后命令。</span>
              </li>
              <li>
                <Icon name="terminal" size={15} />
                <span>运行日志在独立窗口中查看，不再占用主界面的导航栏。</span>
              </li>
            </ul>
          </>
        ) : null}

        {step === 2 ? (
          <>
            <p className="onboarding-note">
              启动器会按游戏版本自动挑选 Java。只有需要固定某个运行时（例如多个 JDK 共存）时才需要手动指定。
            </p>
            <div className="modal-form">
              <Select
                label="Java 运行时"
                value={javaPath}
                onChange={(value) => setJavaPath(value)}
                options={javaOptions}
                hint="留空表示自动选择与 Minecraft 版本匹配的 Java。"
              />
              <div className="onboarding-actions">
                <Button variant="secondary" size="sm" icon="refresh" loading={detecting} onClick={() => void handleDetect()}>
                  重新检测
                </Button>
                <span className="onboarding-hint">已检测到 {detected.length} 个运行时</span>
              </div>
            </div>
          </>
        ) : null}

        {step === 3 ? (
          <>
            <p className="onboarding-note">
              游戏目录存放 versions、libraries 与 assets。已经装过 Minecraft 的话，指向现有 .minecraft 可以直接复用这些文件。
            </p>
            <div className="modal-form">
              <Field id="onboarding-root" label="Minecraft 目录" hint="留空则使用启动器探测到的默认目录；修改后需要重启启动器生效。">
                <div className="path-picker">
                  <span className="path-picker__value mono truncate">{root || gameRoot || "使用启动器探测到的目录"}</span>
                  <Button size="sm" variant="secondary" icon="folder" loading={picking} onClick={() => void handlePickRoot()}>
                    选择
                  </Button>
                  {root ? (
                    <Button size="sm" variant="ghost" onClick={() => setRoot("")}>
                      恢复默认
                    </Button>
                  ) : null}
                </div>
              </Field>
              <p className="onboarding-hint mono">启动器数据目录：{dataRoot || "—"}</p>
            </div>
          </>
        ) : null}

        {step === 4 ? (
          <>
            <p className="onboarding-note">
              离线账户可以立即进入单机与局域网；想使用正版皮肤与服务器，稍后可在「账户管理」里登录 Microsoft。
            </p>
            <div className="modal-form">
              <div className="onboarding-inline">
                <TextInput
                  label="离线玩家名称"
                  placeholder="3-16 个字符"
                  value={playerName}
                  onChange={(event) => setPlayerName(event.target.value)}
                  hint="仅保存在本机，不会上传到任何服务。"
                />
                <Button
                  variant="primary"
                  icon="plus"
                  loading={creating}
                  disabled={!canCreateAccount}
                  onClick={() => void handleCreateAccount()}
                >
                  创建并启用
                </Button>
              </div>
              <p className="onboarding-hint">也可以直接点「下一步」，稍后再创建账户。</p>
            </div>
          </>
        ) : null}

        {step === 5 ? (
          <>
            <div className="onboarding-summary">
              <div className="onboarding-summary__row">
                <span>Java 运行时</span>
                <span className="mono truncate">{javaPath || "自动选择"}</span>
              </div>
              <div className="onboarding-summary__row">
                <span>Minecraft 目录</span>
                <span className="mono truncate">{root || gameRoot || "启动器默认"}</span>
              </div>
              <div className="onboarding-summary__row">
                <span>主题</span>
                <span>
                  <Badge tone="accent">{settings.appearance === "light" ? "浅色" : settings.appearance === "system" ? "跟随系统" : "深色"}</Badge>
                </span>
              </div>
            </div>
            <p className="onboarding-note">
              下一步会保存这些设置。之后可以在「设置」里随时调整语言、强调色、背景图、代理与自定义 Minecraft 目录。
            </p>
          </>
        ) : null}

        {error ? (
          <p className="onboarding-error" role="alert">
            {error}
          </p>
        ) : null}
      </div>
    </Modal>
  );
}
