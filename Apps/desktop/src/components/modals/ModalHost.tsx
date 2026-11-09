import { useApp } from "../../stores/app";
import { CrashModal } from "./CrashModal";
import { GraphicsModal } from "./GraphicsModal";
import { InstallWizardModal } from "./InstallWizardModal";
import { ModpackUpdateModal } from "./ModpackUpdateModal";
import { ModsModal } from "./ModsModal";
import { MrpackModal } from "./MrpackModal";
import { PerformanceModal } from "./PerformanceModal";
import { ResourcePacksModal } from "./ResourcePacksModal";
import { ShadersModal } from "./ShadersModal";
import { ToolsModal } from "./ToolsModal";

export function ModalHost() {
  const { modal } = useApp();
  if (!modal) return null;

  switch (modal.type) {
    case "install":
      return <InstallWizardModal presetVersionId={modal.versionId} />;
    case "mods":
      return <ModsModal instanceId={modal.instanceId} />;
    case "mrpack":
      return <MrpackModal />;
    case "modpackUpdate":
      return <ModpackUpdateModal instanceId={modal.instanceId} />;
    case "graphics":
      return <GraphicsModal instanceId={modal.instanceId} />;
    case "performance":
      return <PerformanceModal instanceId={modal.instanceId} />;
    case "resourcepacks":
      return <ResourcePacksModal instanceId={modal.instanceId} />;
    case "shaders":
      return <ShadersModal instanceId={modal.instanceId} />;
    case "tools":
      return <ToolsModal instanceId={modal.instanceId} initialTab={modal.initialTab} />;
    case "crash":
      return <CrashModal instanceId={modal.instanceId} />;
  }
}
