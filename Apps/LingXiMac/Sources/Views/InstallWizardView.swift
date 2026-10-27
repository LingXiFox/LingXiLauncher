import AppKit
import LauncherCore
import SwiftUI

struct InstallWizardView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.lxTheme) private var theme

    private enum Step: Int, CaseIterable {
        case version, loader, java, target, confirm, progress, done
    }

    private enum LoaderKind: String, CaseIterable, Identifiable {
        case vanilla, fabric
        var id: String { rawValue }
        var title: String { self == .vanilla ? "Vanilla" : "Fabric" }
    }

    private enum TargetMode: String, CaseIterable, Identifiable {
        case newInstance, existingInstance
        var id: String { rawValue }
        var title: String { self == .newInstance ? "创建新实例" : "更新现有实例" }
    }

    private struct ProgressState {
        var phase = "准备中"
        var completed = 0
        var total = 0
        var bytes = 0
        var totalBytes = 0
        var bytesPerSecond: Double = 0
        var currentFile: String?
        var error: String?
        var suggestion: String?
        var cancelled = false
        var started = Date()
    }

    @State private var step: Step = .version
    @State private var versions: [VersionManifest.Entry] = []
    @State private var versionSearch = ""
    @State private var selectedVersion = ""
    @State private var loader: LoaderKind = .vanilla
    @State private var fabricLoaders: [FabricLoaderVersion] = []
    @State private var selectedLoaderVersion: String?
    @State private var javaRequirement: JavaVersionRequirement?
    @State private var javaRuntimes: [JavaRuntime] = []
    @State private var managedJava: [ManagedJava] = []
    @State private var selectedJavaPath = ""
    @State private var targetMode: TargetMode = .newInstance
    @State private var newInstanceName = ""
    @State private var newInstanceID = ""
    @State private var existingInstanceID: String?
    @State private var updateConfirmed = false
    @State private var showJavaConfirmation = false
    @State private var isWorking = false
    @State private var javaDownloading = false
    @State private var loadingJava = false
    @State private var errorMessage: String?
    @State private var errorSuggestion: String?
    @State private var progress = ProgressState()
    @State private var report: OneStopInstallReport?
    @State private var installTask: Task<Void, Never>?
    @State private var javaTask: Task<Void, Never>?

    private var selectedEntry: VersionManifest.Entry? {
        versions.first { $0.id == selectedVersion }
    }

    private var compatibleRuntimes: [JavaRuntime] {
        let required = javaRequirement?.majorVersion ?? 0
        return javaRuntimes.filter { $0.majorVersion >= required }
    }

    private var chosenRuntime: JavaRuntime? {
        javaRuntimes.first { $0.executable.path == selectedJavaPath }
    }

    private var loaderChoice: InstallLoaderChoice {
        switch loader {
        case .vanilla: return .vanilla
        case .fabric: return .fabric(loaderVersion: selectedLoaderVersion)
        }
    }

    private var installSource: String {
        model.settings.source.displayName
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            stepStrip
            if let errorMessage {
                LXErrorBanner(
                    message: errorSuggestion.map { "\(errorMessage)\n\($0)" } ?? errorMessage,
                    dismiss: {
                        self.errorMessage = nil
                        self.errorSuggestion = nil
                    }
                )
            }
            LXDivider()
            ScrollView {
                stepContent
                    .padding(LXSpace.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            if step != .progress && step != .done {
                LXDivider()
                navigation
            }
        }
        .frame(width: 780, height: 760)
        .background(theme.canvas)
        .interactiveDismissDisabled(isWorking || javaDownloading)
        .task {
            if step == .version {
                if let initial = model.installWizardInitialVersion {
                    selectedVersion = initial
                    model.installWizardInitialVersion = nil
                }
                await loadVersions()
            }
        }
        .onDisappear {
            installTask?.cancel()
            javaTask?.cancel()
        }
    }

    // MARK: - Header / navigation

    private var header: some View {
        HStack(alignment: .top, spacing: LXSpace.md) {
            VStack(alignment: .leading, spacing: 4) {
                LXOverline(text: "INSTALL WIZARD", color: theme.orange)
                Text(step == .done ? "安装完成" : "安装 Minecraft")
                    .font(LXFont.display(27))
                    .foregroundStyle(theme.text)
                Text(step == .done ? "实例已准备就绪。" : "Minecraft → Loader → Java → 实例 → 安装")
                    .font(LXFont.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            LXIconButton(systemImage: "xmark", label: "关闭安装向导") {
                if !isWorking && !javaDownloading { closeWizard() }
            }
        }
        .padding(.horizontal, LXSpace.xl)
        .padding(.vertical, LXSpace.lg)
        .background(theme.surface)
    }

    private var stepStrip: some View {
        HStack(spacing: 6) {
            ForEach(Array(["版本", "Loader", "Java", "实例", "确认"].enumerated()), id: \.offset) { index, title in
                let current = max(0, min(6, step.rawValue + 1))
                let done = index < current - 1
                HStack(spacing: 5) {
                    ZStack {
                        Circle().fill(done ? theme.success : (index == current - 1 ? theme.orange : theme.surfaceRaised))
                        if done {
                            Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)).foregroundStyle(theme.onOrange)
                        } else {
                            Text("\(index + 1)").font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundStyle(index == current - 1 ? theme.onOrange : theme.textTertiary)
                        }
                    }
                    .frame(width: 17, height: 17)
                    Text(title)
                        .font(LXFont.captionStrong)
                        .foregroundStyle(index == current - 1 ? theme.text : theme.textTertiary)
                }
                if index < 4 {
                    Rectangle().fill(theme.border).frame(height: 1).frame(maxWidth: 28)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, LXSpace.xl)
        .padding(.vertical, 10)
        .background(theme.canvas)
    }

    private var navigation: some View {
        HStack(spacing: 8) {
            LXButton("取消", kind: .ghost, isDisabled: javaDownloading) { closeWizard() }
            Spacer()
            if step != .version {
                LXButton("上一步", systemImage: "chevron.left", kind: .secondary, isDisabled: javaDownloading) { goBack() }
            }
            LXButton(nextTitle, systemImage: step == .confirm ? "arrow.down.circle" : "chevron.right", kind: .primary, isDisabled: !canContinue) {
                advance()
            }
        }
        .padding(.horizontal, LXSpace.xl)
        .padding(.vertical, LXSpace.md)
        .background(theme.surface)
    }

    private var nextTitle: String {
        switch step {
        case .version: return "选择 Loader"
        case .loader: return "检测 Java"
        case .java: return "选择实例"
        case .target: return "确认安装"
        case .confirm: return "开始安装"
        default: return "下一步"
        }
    }

    private var canContinue: Bool {
        switch step {
        case .version: return !selectedVersion.isEmpty
        case .loader: return loader == .vanilla || selectedLoaderVersion != nil
        case .java: return chosenRuntime != nil
        case .target:
            if targetMode == .newInstance {
                return !newInstanceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !newInstanceID.isEmpty
            }
            return existingInstanceID != nil && updateConfirmed
        case .confirm: return true
        default: return false
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .version: versionStep
        case .loader: loaderStep
        case .java: javaStep
        case .target: targetStep
        case .confirm: confirmStep
        case .progress: progressStep
        case .done: doneStep
        }
    }

    private var versionStep: some View {
        VStack(alignment: .leading, spacing: LXSpace.md) {
            stepIntro(
                number: 1,
                title: "选择 Minecraft 版本",
                detail: "官方清单中的版本会下载到共享游戏目录；不会自动覆盖已有实例。"
            )
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.textTertiary)
                TextField("搜索版本", text: $versionSearch)
                    .textFieldStyle(.plain)
                    .font(LXFont.body)
                    .foregroundStyle(theme.text)
                if !versionSearch.isEmpty {
                    LXIconButton(systemImage: "xmark.circle.fill", label: "清除搜索") { versionSearch = "" }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous).strokeBorder(theme.border, lineWidth: 0.8))

            if !selectedVersion.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.orange)
                    Text("已选择 Minecraft \(selectedVersion)").font(LXFont.bodyStrong).foregroundStyle(theme.text)
                    if let entry = selectedEntry {
                        LXBadge(text: entry.type.rawValue, tone: .accent)
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(theme.orangeSoft, in: RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous))
            }
            LXCard(padding: 0) {
                if versions.isEmpty {
                    LXEmptyState(icon: "arrow.down.circle", title: "正在获取版本…", message: "官方 manifest 会缓存到启动器数据目录。")
                        .frame(height: 330)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredVersions, id: \.id) { entry in
                                Button { selectedVersion = entry.id } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.id).font(LXFont.bodyStrong).foregroundStyle(theme.text)
                                            Text(entry.releaseTime?.prefix(10) ?? "").font(LXFont.monoSmall).foregroundStyle(theme.textTertiary)
                                        }
                                        Spacer()
                                        LXBadge(text: entry.type.rawValue, tone: entry.type == .release ? .accent : .neutral)
                                        if selectedVersion == entry.id {
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.orange)
                                        }
                                    }
                                    .padding(.horizontal, LXSpace.md)
                                    .padding(.vertical, 8)
                                    .background(selectedVersion == entry.id ? theme.orangeSoft : Color.clear)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if entry.id != filteredVersions.last?.id { LXDivider().padding(.leading, LXSpace.md) }
                            }
                        }
                    }
                    .frame(height: 330)
                    .scrollIndicators(.never)
                }
            }
            if versions.isEmpty {
                LXButton("重新获取版本", systemImage: "arrow.clockwise", kind: .secondary) {
                    Task { await loadVersions() }
                }
            }
        }
    }

    private var filteredVersions: [VersionManifest.Entry] {
        guard !versionSearch.isEmpty else { return versions }
        return versions.filter { $0.id.localizedCaseInsensitiveContains(versionSearch) }
    }

    private var loaderStep: some View {
        VStack(alignment: .leading, spacing: LXSpace.md) {
            stepIntro(number: 2, title: "选择 Mod Loader", detail: "首期支持 Vanilla 与 Fabric；Forge / NeoForge / Quilt 暂不提供。")
            HStack(spacing: LXSpace.sm) {
                ForEach(LoaderKind.allCases) { kind in
                    Button {
                        loader = kind
                        if kind == .fabric { Task { await loadFabricLoaders() } }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Image(systemName: kind == .vanilla ? "cube.fill" : "square.stack.3d.up.fill")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(loader == kind ? theme.orange : theme.textSecondary)
                            Text(kind.title).font(LXFont.headline).foregroundStyle(theme.text)
                            Text(kind == .vanilla ? "官方原版，最少依赖" : "Fabric Loader + 兼容库")
                                .font(LXFont.caption).foregroundStyle(theme.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(LXSpace.md)
                        .background(
                            RoundedRectangle(cornerRadius: LXRadius.lg, style: .continuous)
                                .fill(loader == kind ? theme.orangeSoft : theme.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: LXRadius.lg, style: .continuous)
                                .strokeBorder(loader == kind ? theme.orange.opacity(0.55) : theme.border, lineWidth: loader == kind ? 1.4 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            if loader == .fabric {
                LXCard(padding: LXSpace.md) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            LXOverline(text: "FABRIC LOADER")
                            Spacer()
                            if fabricLoaders.isEmpty { ProgressView().controlSize(.small) }
                        }
                        if fabricLoaders.isEmpty {
                            Text("正在查询与 Minecraft \(selectedVersion) 兼容的 Loader…")
                                .font(LXFont.caption).foregroundStyle(theme.textSecondary)
                        } else {
                            Menu {
                                ForEach(fabricLoaders) { loader in
                                    Button {
                                        selectedLoaderVersion = loader.version
                                    } label: {
                                        if selectedLoaderVersion == loader.version {
                                            Label("\(loader.version)\(loader.stable ? " · stable" : "")", systemImage: "checkmark")
                                        } else {
                                            Text("\(loader.version)\(loader.stable ? " · stable" : "")")
                                        }
                                    }
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(selectedLoaderVersion ?? "选择 Loader 版本")
                                            .font(LXFont.bodyStrong).foregroundStyle(theme.text)
                                        Text("仅列出 Fabric 官方声明兼容的版本")
                                            .font(LXFont.caption).foregroundStyle(theme.textTertiary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down").foregroundStyle(theme.textTertiary)
                                }
                                .padding(10)
                                .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous).strokeBorder(theme.border, lineWidth: 0.8))
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            LXBadge(text: "\(fabricLoaders.count) compatible", tone: .success, dot: true)
                        }
                    }
                }
            }
        }
    }

    private var javaStep: some View {
        VStack(alignment: .leading, spacing: LXSpace.md) {
            stepIntro(
                number: 3,
                title: "Java 环境",
                detail: javaRequirement.flatMap(\.majorVersion).map { "此版本要求 Java \($0)+。必须选择兼容运行时；不会修改系统 Java。" } ?? "正在读取版本元数据中的 Java 要求…"
            )
            if loadingJava {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在检测兼容 Java…").font(LXFont.body).foregroundStyle(theme.textSecondary)
                }
                .padding(LXSpace.md)
            } else if compatibleRuntimes.isEmpty {
                LXCard(padding: LXSpace.md) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.warning)
                            Text("没有找到兼容的 Java").font(LXFont.headline).foregroundStyle(theme.text)
                        }
                        Text("本机未安装满足 Java \(javaRequirement?.majorVersion ?? 0)+ 的运行时。下载托管 Temurin JDK，或手动选择已有 java。")
                            .font(LXFont.body).foregroundStyle(theme.textSecondary)
                        HStack(spacing: 7) {
                            LXButton("下载 \(JavaManager.managedSourceName) \(javaRequirement?.majorVersion.map(String.init) ?? "所需版本")", systemImage: "arrow.down.circle", kind: .primary) {
                                showJavaConfirmation = true
                            }
                            LXButton("选择 java…", systemImage: "folder", kind: .secondary) { chooseJavaFile() }
                        }
                    }
                }
            } else {
                VStack(spacing: 7) {
                    ForEach(compatibleRuntimes, id: \.executable.path) { runtime in
                        let managed = managedJava.first { $0.runtime.executable == runtime.executable }
                        Button { selectedJavaPath = runtime.executable.path } label: {
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8).fill(selectedJavaPath == runtime.executable.path ? theme.orangeSoft : theme.surfaceRaised)
                                    Image(systemName: "cup.and.saucer.fill").font(.system(size: 13)).foregroundStyle(theme.orange)
                                }.frame(width: 30, height: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(runtime.displayDescription).font(LXFont.bodyStrong).foregroundStyle(theme.text)
                                    Text(managed?.source ?? "系统 / 本地 JDK · \(runtime.executable.path)")
                                        .font(LXFont.monoSmall).foregroundStyle(theme.textTertiary).lineLimit(1)
                                }
                                Spacer()
                                if let source = managed?.source {
                                    LXBadge(text: source, tone: .accent)
                                }
                                if selectedJavaPath == runtime.executable.path {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.orange)
                                }
                            }
                            .padding(10)
                            .background(theme.surface, in: RoundedRectangle(cornerRadius: LXRadius.md, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: LXRadius.md, style: .continuous).strokeBorder(selectedJavaPath == runtime.executable.path ? theme.orange.opacity(0.6) : theme.border, lineWidth: selectedJavaPath == runtime.executable.path ? 1.3 : 0.8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 7) {
                    LXButton("重新检测", systemImage: "arrow.clockwise", kind: .secondary) { Task { await loadJavaRuntimes() } }
                    LXButton("选择 java…", systemImage: "folder", kind: .ghost) { chooseJavaFile() }
                }
            }
            if showJavaConfirmation {
                javaConfirmationCard
            }
            if javaDownloading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在下载并校验托管 Java…").font(LXFont.caption).foregroundStyle(theme.textSecondary)
                }
            }
        }
    }

    private var javaConfirmationCard: some View {
        LXCard(padding: LXSpace.md, elevated: true, accent: theme.orange) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(theme.orange)
                    Text("下载托管 Java？").font(LXFont.headline).foregroundStyle(theme.text)
                    Spacer()
                }
                Text("\(JavaManager.managedSourceName) \(javaRequirement?.majorVersion.map(String.init) ?? "所需版本") · macOS arm64")
                    .font(LXFont.bodyStrong).foregroundStyle(theme.text)
                Text("来源：Adoptium Temurin · 许可：\(JavaManager.managedLicense)")
                    .font(LXFont.caption).foregroundStyle(theme.textSecondary)
                Text("下载约 180 MB，会校验发布方 SHA-256，并安装到启动器私有目录；不会修改系统 Java。")
                    .font(LXFont.caption).foregroundStyle(theme.textTertiary)
                HStack(spacing: 7) {
                    LXButton("取消", kind: .secondary) { showJavaConfirmation = false }
                    LXButton("下载并安装", systemImage: "arrow.down.circle", kind: .primary) {
                        showJavaConfirmation = false
                        downloadJava()
                    }
                }
            }
        }
    }

    private var targetStep: some View {
        VStack(alignment: .leading, spacing: LXSpace.md) {
            stepIntro(number: 4, title: "安装目标", detail: "默认创建新实例；更新现有实例必须显式选择并确认备份。")
            HStack(spacing: 6) {
                ForEach(TargetMode.allCases) { mode in
                    LXChip(title: mode.title, isSelected: targetMode == mode) {
                        targetMode = mode
                        if mode == .newInstance { prepareNewTarget() }
                    }
                }
                Spacer()
            }
            if targetMode == .newInstance {
                LXCard(padding: LXSpace.md) {
                    VStack(alignment: .leading, spacing: 10) {
                        fieldLabel("实例名称")
                        TextField("例如：Minecraft 1.20.1 Fabric", text: $newInstanceName)
                            .lxInput()
                            .onChange(of: newInstanceName) { _, _ in
                                if newInstanceID.isEmpty { newInstanceID = suggestedInstanceID() }
                            }
                        fieldLabel("实例 ID（目录名）")
                        TextField("fabric-1-20-1", text: $newInstanceID)
                            .lxInput()
                        Text("游戏目录：\(directoryPreview)")
                            .font(LXFont.monoSmall)
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            } else {
                LXCard(padding: LXSpace.md) {
                    VStack(alignment: .leading, spacing: 10) {
                        fieldLabel("选择现有实例")
                        Menu {
                            ForEach(model.instances) { instance in
                                Button("\(instance.manifest.displayName) · \(instance.id)") {
                                    existingInstanceID = instance.id
                                    updateConfirmed = false
                                }
                            }
                        } label: {
                            HStack {
                                Text(existingInstanceID ?? "选择实例…").font(LXFont.body).foregroundStyle(theme.text)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down").foregroundStyle(theme.textTertiary)
                            }
                            .padding(9)
                            .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous).strokeBorder(theme.border, lineWidth: 0.8))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        if let id = existingInstanceID, let instance = model.instances.first(where: { $0.id == id }) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("更新会只改变版本指针，并先备份 instance.json；不会自动删除世界、模组或配置。")
                                    .font(LXFont.caption).foregroundStyle(theme.warning)
                                Text("当前版本：\(instance.manifest.versionID ?? "未绑定") · 游戏目录：\(instance.gameDirectory.path)")
                                    .font(LXFont.monoSmall).foregroundStyle(theme.textTertiary).lineLimit(2)
                                Toggle("我已了解风险，并确认更新此实例", isOn: $updateConfirmed)
                                    .font(LXFont.bodyStrong)
                                    .tint(theme.orange)
                            }
                            .padding(9)
                            .background(theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous))
                        }
                    }
                }
            }
        }
    }

    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: LXSpace.md) {
            stepIntro(number: 5, title: "确认安装", detail: "下载前最后检查一次目标、Java 和来源。")
            LXCard(padding: LXSpace.md) {
                VStack(alignment: .leading, spacing: 10) {
                    summaryRow("Minecraft", selectedVersion)
                    summaryRow("Loader", loader == .vanilla ? "Vanilla" : "Fabric \(selectedLoaderVersion ?? "")")
                    summaryRow("Java", chosenRuntime?.displayDescription ?? "未选择")
                    summaryRow("安装源", installSource)
                    summaryRow("目标", targetDescription)
                    if let backup = updateBackupDescription {
                        Text(backup).font(LXFont.caption).foregroundStyle(theme.warning)
                    }
                }
            }
            LXCard(padding: LXSpace.md) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "info.circle").foregroundStyle(theme.info)
                    Text("安装会先下载并校验共享文件，最后才创建/更新目标实例。取消或失败不会删除已有世界、模组和配置。")
                        .font(LXFont.caption).foregroundStyle(theme.textSecondary)
                }
            }
        }
    }

    private var progressStep: some View {
        VStack(alignment: .leading, spacing: LXSpace.md) {
            stepIntro(number: 6, title: report == nil && progress.error == nil ? "正在安装" : "安装结果", detail: progress.phase)
            LXCard(padding: LXSpace.md, elevated: true) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(progress.phase).font(LXFont.headline).foregroundStyle(theme.text)
                        Spacer()
                        if isWorking { ProgressView().controlSize(.small) }
                    }
                    LXProgressBar(fraction: progress.total > 0 ? Double(progress.completed) / Double(progress.total) : 0, height: 7)
                    HStack(spacing: 18) {
                        metric("文件", progress.total > 0 ? "\(progress.completed) / \(progress.total)" : "—")
                        metric("已下载", "\(compactBytes(progress.bytes)) / \(compactBytes(progress.totalBytes))")
                        metric("速度", progress.bytesPerSecond > 0 ? "\(compactBytes(Int(progress.bytesPerSecond)))/s" : "—")
                    }
                    if let file = progress.currentFile {
                        Text(file).font(LXFont.monoSmall).foregroundStyle(theme.textTertiary).lineLimit(1).truncationMode(.middle)
                    }
                    if let error = progress.error {
                        Divider()
                        Text(error).font(LXFont.bodyStrong).foregroundStyle(theme.danger)
                        if let suggestion = progress.suggestion {
                            Text(suggestion).font(LXFont.caption).foregroundStyle(theme.textSecondary)
                        }
                    }
                    if progress.cancelled {
                        Text("安装已取消；目标实例未被修改。已下载的共享文件保留在缓存中。")
                            .font(LXFont.caption).foregroundStyle(theme.warning)
                    }
                }
            }
            HStack(spacing: 8) {
                if isWorking {
                    LXButton("取消安装", systemImage: "stop.fill", kind: .destructive) { cancelInstall() }
                } else if progress.error != nil || progress.cancelled {
                    LXButton("重试", systemImage: "arrow.clockwise", kind: .primary) { startInstall() }
                    LXButton("返回修改", kind: .secondary) { step = .confirm }
                }
                Spacer()
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: LXSpace.md) {
            stepIntro(number: 7, title: "安装完成", detail: "实例已创建，启动前仍会执行 Java 与文件校验。")
            if let report {
                LXCard(padding: LXSpace.md, elevated: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(theme.success)
                            Text(report.installedVersionID).font(LXFont.title(20)).foregroundStyle(theme.text)
                        }
                        summaryRow("实例", report.instanceID)
                        summaryRow("游戏目录", report.gameDirectory.path)
                        summaryRow("Loader", loader == .vanilla ? "Vanilla" : "Fabric \(selectedLoaderVersion ?? "")")
                        if let backup = report.backupManifest {
                            summaryRow("备份", backup.path)
                        }
                    }
                }
            }
            HStack(spacing: 7) {
                LXButton("完成", kind: .primary) { closeWizard() }
                LXButton("查看日志", systemImage: "text.alignleft", kind: .secondary) {
                    model.section = .logs
                    closeWizard()
                }
            }
        }
    }

    // MARK: - Actions

    private func advance() {
        switch step {
        case .version:
            step = .loader
        case .loader:
            step = .java
            Task { await loadJavaRequirements() }
        case .java:
            prepareNewTargetIfNeeded()
            step = .target
        case .target:
            step = .confirm
        case .confirm:
            step = .progress
            startInstall()
        default:
            break
        }
    }

    private func goBack() {
        switch step {
        case .loader: step = .version
        case .java: step = .loader
        case .target: step = .java
        case .confirm: step = .target
        default: break
        }
    }

    private func loadVersions() async {
        if model.versionEntries.isEmpty { await model.loadVersions() }
        versions = model.versionEntries.filter { $0.type == .release }
        if selectedVersion.isEmpty {
            if let preferred = versions.first(where: { $0.id == "1.20.1" }) {
                selectedVersion = preferred.id
            } else {
                selectedVersion = versions.first?.id ?? ""
            }
        }
    }

    private func loadFabricLoaders() async {
        do {
            let installer = try model.makeOneStopInstaller()
            fabricLoaders = try await installer.listFabricLoaders(for: selectedVersion)
            selectedLoaderVersion = fabricLoaders.first(where: \.stable)?.version ?? fabricLoaders.first?.version
        } catch {
            setError(error)
        }
    }

    private func loadJavaRequirements() async {
        loadingJava = true
        defer { loadingJava = false }
        do {
            let installer = try model.makeOneStopInstaller()
            javaRequirement = try await installer.requiredJava(for: selectedVersion, loader: loaderChoice)
            await loadJavaRuntimes()
        } catch {
            setError(error)
        }
    }

    @MainActor
    private func loadJavaRuntimes() async {
        let manager = model.makeJavaManager()
        javaRuntimes = manager.detectRuntimes()
        managedJava = manager.managedRuntimes()
        if selectedJavaPath.isEmpty || !javaRuntimes.contains(where: { $0.executable.path == selectedJavaPath }) {
            selectedJavaPath = manager.selectCompatible(requirement: javaRequirement ?? JavaVersionRequirement(majorVersion: 8))?.executable.path ?? ""
        }
    }

    private func chooseJavaFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "选择 Java 可执行文件（…/bin/java）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let runtime = try model.makeJavaManager().inspectCustom(url)
            if !javaRuntimes.contains(where: { $0.executable.path == runtime.executable.path }) {
                javaRuntimes.append(runtime)
            }
            selectedJavaPath = runtime.executable.path
            model.selectJava(path: runtime.executable.path)
        } catch {
            setError(error)
        }
    }

    private func downloadJava() {
        guard let major = javaRequirement?.majorVersion else {
            setError(LauncherError(.javaVersionMismatch, "尚未确定所需的 Java 主版本，无法安全选择 JDK"))
            return
        }
        javaDownloading = true
        errorMessage = nil
        javaTask = Task {
            do {
                let manager = model.makeJavaManager()
                let managed = try await manager.installManagedJava(majorVersion: major) { event in
                    Task { @MainActor in
                        if case let .downloading(total) = event {
                            progress.phase = "下载托管 Java\(total.map { " · \(compactBytes($0))" } ?? "")"
                        }
                    }
                }
                await loadJavaRuntimes()
                selectedJavaPath = managed.runtime.executable.path
                model.selectJava(path: managed.runtime.executable.path)
                await model.refreshJavaRuntimes()
            } catch {
                setError(error)
            }
            javaDownloading = false
        }
    }

    private func startInstall() {
        guard let runtime = chosenRuntime else { return }
        isWorking = true
        progress = ProgressState()
        report = nil
        errorMessage = nil
        errorSuggestion = nil
        let request: OneStopInstallRequest
        do {
            let target: InstallTargetChoice
            switch targetMode {
            case .newInstance:
                target = .newInstance(id: newInstanceID, displayName: newInstanceName)
            case .existingInstance:
                guard let existingInstanceID, updateConfirmed else { return }
                target = .existingInstance(id: existingInstanceID)
            }
            request = OneStopInstallRequest(
                minecraftVersionID: selectedVersion,
                loader: loaderChoice,
                target: target,
                javaExecutable: runtime.executable,
                sourcePolicy: model.settings.source
            )
        }
        installTask = Task {
            do {
                let installer = try model.makeOneStopInstaller()
                let result = try await installer.install(request) { event in
                    Task { @MainActor in applyProgress(event) }
                }
                report = result
                model.reloadInstances()
                model.selectedInstanceID = result.instanceID
                model.section = .home
                step = .done
            } catch is CancellationError {
                progress.cancelled = true
                progress.phase = "已取消"
            } catch let error as LauncherError {
                progress.error = error.message
                progress.suggestion = error.suggestion
                progress.phase = "安装失败"
            } catch {
                progress.error = error.localizedDescription
                progress.phase = "安装失败"
            }
            isWorking = false
        }
    }

    private func cancelInstall() {
        progress.phase = "正在取消…"
        installTask?.cancel()
    }

    @MainActor
    private func applyProgress(_ event: InstallProgressEvent) {
        switch event {
        case let .phase(_, message):
            progress.phase = message
        case let .plan(totalFiles, totalBytes, cacheHits):
            progress.total = max(0, totalFiles - cacheHits)
            progress.totalBytes = totalBytes
        case let .fileStarted(path, _):
            progress.currentFile = (path as NSString).lastPathComponent
        case let .fileFinished(_, bytes, _):
            progress.completed += 1
            progress.bytes += bytes
            let elapsed = Date().timeIntervalSince(progress.started)
            if elapsed > 0.1 { progress.bytesPerSecond = Double(progress.bytes) / elapsed }
        case let .fileFailed(path, message):
            progress.error = "\(path): \(message)"
        }
    }

    // MARK: - Target helpers

    private func prepareNewTargetIfNeeded() {
        if newInstanceName.isEmpty {
            newInstanceName = "Minecraft \(selectedVersion)\(loader == .vanilla ? "" : " Fabric")"
        }
        if newInstanceID.isEmpty { newInstanceID = suggestedInstanceID() }
    }

    private func prepareNewTarget() {
        prepareNewTargetIfNeeded()
    }

    private func suggestedInstanceID() -> String {
        let base = "\(loader.rawValue)-\(selectedVersion)"
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, character in
                if character == "-", result.last == "-" { return }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        var candidate = base.isEmpty ? "minecraft" : base
        var suffix = 2
        let existing = Set(model.instances.map(\.id))
        while existing.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private var directoryPreview: String {
        (try? model.layout.instanceGameDirectory(newInstanceID.isEmpty ? "new-instance" : newInstanceID).path) ?? "—"
    }

    private var targetDescription: String {
        switch targetMode {
        case .newInstance: return "新建 \(newInstanceName)（\(newInstanceID)）"
        case .existingInstance: return "更新现有实例 \(existingInstanceID ?? "—")"
        }
    }

    private var updateBackupDescription: String? {
        targetMode == .existingInstance ? "更新前会备份 instance.json；世界、模组和配置不会被删除。" : nil
    }

    // MARK: - Small UI helpers

    private func stepIntro(number: Int, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text("\(number)").font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.onOrange)
                    .frame(width: 19, height: 19)
                    .background(theme.orange, in: Circle())
                Text(title).font(LXFont.title(21)).foregroundStyle(theme.text)
            }
            Text(detail).font(LXFont.body).foregroundStyle(theme.textSecondary)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(LXFont.captionStrong).foregroundStyle(theme.textSecondary)
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).font(LXFont.caption).foregroundStyle(theme.textTertiary).frame(width: 80, alignment: .leading)
            Text(value).font(LXFont.bodyStrong).foregroundStyle(theme.text).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(LXFont.caption).foregroundStyle(theme.textTertiary)
            Text(value).font(LXFont.monoSmall).foregroundStyle(theme.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactBytes(_ bytes: Int) -> String {
        let value = max(0, bytes)
        if value < 1024 { return "\(value) B" }
        let units = ["KB", "MB", "GB"]
        var amount = Double(value)
        var unit = 0
        while amount >= 1024 && unit < units.count - 1 { amount /= 1024; unit += 1 }
        return String(format: amount >= 100 ? "%.0f %@" : "%.1f %@", amount, units[unit])
    }

    private func closeWizard() {
        model.installWizardInitialVersion = nil
        model.showInstallWizard = false
    }

    private func setError(_ error: Error) {
        if let launcher = error as? LauncherError {
            errorMessage = launcher.message
            errorSuggestion = launcher.suggestion
        } else {
            errorMessage = error.localizedDescription
            errorSuggestion = nil
        }
    }
}
