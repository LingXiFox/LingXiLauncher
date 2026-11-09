import { useState } from "react";
import { api, type MrpackSummary } from "../../services/api";
import { useApp } from "../../stores/app";
import { Badge } from "../Badge";
import { Button } from "../Button";
import { EmptyState } from "../EmptyState";
import { Icon } from "../Icons";
import { TextInput } from "../Input";
import { Modal } from "../Modal";
import { InstallProgressPanel, ModalError, errorMessage, formatBytes, pickFile } from "./shared";

export function MrpackModal() {
  const { closeModal, refreshInstances, toast, installedProgress, resetInstallProgress } = useApp();
  const [path, setPath] = useState<string | null>(null);
  const [summary, setSummary] = useState<MrpackSummary | null>(null);
  const [name, setName] = useState("");
  const [inspecting, setInspecting] = useState(false);
  const [importing, setImporting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function chooseFile() {
    setError(null);
    try {
      const selected = await pickFile({ title: "选择 Modrinth 整合包", extensions: ["mrpack"] });
      if (!selected) return;
      setPath(selected);
      setSummary(null);
      setInspecting(true);
      const inspected = await api.inspectMrpack(selected);
      setSummary(inspected);
      setName((current) => current || inspected.name);
    } catch (cause) {
      setError(errorMessage(cause));
    } finally {
      setInspecting(false);
    }
  }

  async function importPack() {
    if (!path) return;
    setImporting(true);
    setError(null);
    resetInstallProgress();
    try {
      const instance = await api.importMrpack(path, name.trim() || undefined);
      await refreshInstances();
      resetInstallProgress();
      closeModal();
      toast("success", "整合包已导入", `${instance.name} · ${instance.versionId || "未知版本"}`);
    } catch (cause) {
      setError(errorMessage(cause));
    } finally {
      setImporting(false);
    }
  }

  return (
    <Modal
      title="导入 Modrinth 整合包"
      eyebrow=".mrpack"
      subtitle="读取整合包清单并安装其声明的 Minecraft、加载器与模组文件。"
      onClose={closeModal}
      size="lg"
      dismissible={!importing}
      footer={
        <div className="modal-footer__row">
          <span className="modal-footer__note">
            {summary ? `将创建实例「${name.trim() || summary.name}」` : "先选择一个 .mrpack 文件"}
          </span>
          <div className="modal-footer__actions">
            <Button variant="ghost" onClick={closeModal} disabled={importing}>取消</Button>
            <Button
              variant="primary"
              icon="download"
              loading={importing}
              disabled={!summary || inspecting}
              onClick={() => void importPack()}
            >
              导入整合包
            </Button>
          </div>
        </div>
      }
    >
      <div className="mrpack-picker">
        <div className={["file-drop", path ? "has-file" : ""].filter(Boolean).join(" ")}>
          <span className="file-drop__icon"><Icon name={path ? "archive" : "upload"} size={24} /></span>
          <div className="file-drop__copy">
            <p className="file-drop__title">{path ? path.split(/[\\/]/).pop() : "选择 Modrinth 整合包文件"}</p>
            <p className="file-drop__path">{path ?? "支持 .mrpack，包含 modrinth.index.json 的压缩包"}</p>
          </div>
          <Button variant="secondary" icon="folder" onClick={() => void chooseFile()} loading={inspecting} disabled={importing}>
            {path ? "重新选择" : "浏览文件"}
          </Button>
        </div>
      </div>

      <ModalError error={error} />

      {inspecting ? (
        <div className="modal-loading"><span className="spinner" aria-hidden="true" />正在解析整合包清单</div>
      ) : summary ? (
        <div className="mrpack-summary">
          <div className="mrpack-summary__head">
            <div>
              <p className="mrpack-summary__eyebrow">整合包信息</p>
              <h3 className="mrpack-summary__title">{summary.name}</h3>
              <p className="mrpack-summary__description">{summary.description || "该整合包没有提供简介。"}</p>
            </div>
            <Badge tone="accent">{summary.modCount ?? 0} 个文件</Badge>
          </div>
          <dl className="mrpack-facts">
            <div><dt>版本</dt><dd>{summary.version || "—"}</dd></div>
            <div><dt>作者</dt><dd>{summary.author || "—"}</dd></div>
            <div><dt>Minecraft</dt><dd>{summary.minecraftVersion || "未声明"}</dd></div>
            <div><dt>加载器</dt><dd>{summary.loader || "原版 / 未声明"}</dd></div>
          </dl>
          <TextInput
            label="实例名称"
            value={name}
            maxLength={60}
            onChange={(event) => setName(event.target.value)}
            hint="导入后可在实例列表中重命名。"
          />
          {summary.files && summary.files.length > 0 ? (
            <div className="mrpack-files">
              <p className="mrpack-files__title">文件清单（前 {Math.min(summary.files.length, 12)} 项）</p>
              <ul>
                {summary.files.slice(0, 12).map((file) => (
                  <li key={file.path}>
                    <span className="mrpack-files__path">{file.path}</span>
                    <span className="mrpack-files__size">{formatBytes(file.size)}</span>
                  </li>
                ))}
              </ul>
              {summary.files.length > 12 ? <p className="mrpack-files__more">还有 {summary.files.length - 12} 个文件未展示</p> : null}
            </div>
          ) : null}
          {importing ? <InstallProgressPanel progress={installedProgress} label="正在安装整合包" /> : null}
        </div>
      ) : (
        <EmptyState
          icon="archive"
          title="还没有选择整合包"
          description=".mrpack 是 Modrinth 的整合包格式，包含模组下载清单与加载器信息。"
          compact
        />
      )}
    </Modal>
  );
}
