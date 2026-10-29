import LauncherCore
import SwiftUI
import UniformTypeIdentifiers

struct MrpackImportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.lxTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var selectedURL: URL?
    @State private var package: MrpackPackage?
    @State private var displayName = ""
    @State private var javaRequirement: JavaVersionRequirement?
    @State private var selectedJavaPath = ""
    @State private var parsedFiles: [MrpackFile] = []
    @State private var selectedOptionalPaths = Set<String>()
    @State private var overrideCount = 0
    @State private var isParsing = false
    @State private var isInstalling = false
    @State private var progress: MrpackInstallProgress?
    @State private var errorText: String?
    @State private var warningText: String?
    @State private var installFailed = false
    @State private var report: MrpackInstallReport?
    @State private var installTask: Task<Void, Never>?
    @State private var parseTask: Task<Void, Never>?
    @State private var showFileImporter = false
    @State private var dropTargeted = false
    @State private var didLoadInitialURL = false
    @State private var debugTokens: [UUID] = []
    @State private var showJavaDownload = false
    @State private var isInstallingJava = false
    @State private var javaInstallMessage: String?

    private var compatibleRuntimes: [JavaRuntime] {
        guard let javaRequirement else { return model.javaRuntimes }
        let manager = model.makeJavaManager()
        return model.javaRuntimes.filter { manager.isCompatible($0, requirement: javaRequirement) }
    }

    private var selectedRuntime: JavaRuntime? {
        compatibleRuntimes.first { $0.executable.path == selectedJavaPath }
    }

    private var canInstall: Bool {
        package != nil && !isInstalling && !isParsing && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedRuntime != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LXSpace.lg) {
            header
            if let errorText {
                LXErrorBanner(message: errorText) { self.errorText = nil }
            }
            if let report {
                completionCard(report)
            } else if isParsing || package == nil {
                pickerArea
            } else {
                packageContent
            }
            footer
        }
        .padding(LXSpace.xl)
        .frame(width: 760, height: 780)
        .background(theme.canvas)
        .environment(\.lxTheme, theme)
        .interactiveDismissDisabled(isInstalling)
        .task {
            registerDebugActions()
            guard !didLoadInitialURL else { return }
            didLoadInitialURL = true
            if let initial = model.mrpackImportURL {
                parse(initial)
            }
        }
        .onDisappear {
            for token in debugTokens { DebugAutomationCenter.shared.unregister(token) }
            debugTokens.removeAll()
            parseTask?.cancel()
            if isInstalling {
                // The sheet can be dismissed by the app/window while a task is still running.
                // Cancel it and only remove the extraction tree after the installer has stopped.
                installTask?.cancel()
                let task = installTask
                Task { @MainActor in
                    _ = await task?.result
                    self.cleanupPackage()
                }
            } else {
                cleanupPackage()
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [UTType(filenameExtension: "mrpack") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first { parse(url) }
            case let .failure(error):
                errorText = "无法选择整合包：\(error.localizedDescription)"
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                guard let url, url.pathExtension.lowercased() == "mrpack" else {
                    Task { @MainActor in self.errorText = "请选择有效的 .mrpack 整合包文件" }
                    return
                }
                Task { @MainActor in self.parse(url) }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: LXRadius.lg, style: .continuous)
                    .strokeBorder(theme.orange, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .padding(8)
                    .allowsHitTesting(false)
                    .overlay {
                        Text("松开以导入 .mrpack")
                            .font(LXFont.bodyStrong)
                            .foregroundStyle(theme.orange)
                    }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                LXOverline(text: "IMPORT / MODPACK", color: theme.orange)
                Text("导入整合包")
                    .font(LXFont.display(25))
                    .foregroundStyle(theme.text)
                Text("从 Modrinth .mrpack 创建独立实例；下载、校验、解压都在提交前完成。")
                    .font(LXFont.body)
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            LXIconButton(systemImage: "xmark", label: "关闭") {
                closeImporter()
            }
            .disabled(isInstalling)
        }
    }

    private var pickerArea: some View {
        VStack(spacing: LXSpace.md) {
            Spacer()
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(theme.orange)
            VStack(spacing: 5) {
                Text(isParsing ? "正在解析整合包…" : "拖入 .mrpack 文件")
                    .font(LXFont.title())
                    .foregroundStyle(theme.text)
                Text("或从 Finder 选择文件。解析只读取本地归档，不会自行下载。")
                    .font(LXFont.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            LXButton("选择 .mrpack", systemImage: "doc.badge.plus", kind: .primary) {
                showFileImporter = true
            }
            .disabled(isParsing)
            if isParsing { ProgressView().controlSize(.small).tint(theme.orange) }
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 390)
        .background(theme.surfaceRaised.opacity(theme.isDark ? 0.35 : 0.65), in: RoundedRectangle(cornerRadius: LXRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LXRadius.lg, style: .continuous)
                .strokeBorder(theme.border, style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
        )
    }

    private var packageContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LXSpace.md) {
                if let package {
                    LXCard(elevated: true) {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(package.name)
                                    .font(LXFont.title())
                                    .foregroundStyle(theme.text)
                                Spacer()
                                LXBadge(text: "format 1", tone: .success, icon: "checkmark.seal")
                            }
                            Text("版本 \(package.versionID) · Minecraft \(package.minecraftVersion)")
                                .font(LXFont.caption)
                                .foregroundStyle(theme.textSecondary)
                            if let summary = package.summary, !summary.isEmpty {
                                Text(summary)
                                    .font(LXFont.caption)
                                    .foregroundStyle(theme.textTertiary)
                                    .lineLimit(3)
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        LXBadge(text: package.minecraftVersion, tone: .info, icon: "cube")
                        LXBadge(text: loaderLabel(package.loader), tone: .accent, icon: "square.stack.3d.up")
                        LXBadge(text: "\(parsedFiles.count) 文件", tone: .neutral, icon: "doc")
                        if !(package.optionalFiles.isEmpty) {
                            LXBadge(text: "\(package.optionalFiles.count) 可选", tone: .warning, icon: "switch.2")
                        }
                        LXBadge(text: "\(overrideCount) overrides", tone: .neutral, icon: "folder")
                        Spacer()
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        infoTile("下载大小", ByteCountFormatter.string(fromByteCount: Int64(package.totalDownloadBytes), countStyle: .file))
                        infoTile("客户端跳过", "\(package.skippedClientUnsupported) 个 server-only 文件")
                    }

                    optionalSection(package)
                    javaSection(package)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("实例名称").font(LXFont.captionStrong).foregroundStyle(theme.textSecondary)
                        TextField("整合包实例名称", text: $displayName)
                            .lxInput()
                        Text("将创建全新实例；不会覆盖已有世界、配置或模组。")
                            .font(LXFont.caption).foregroundStyle(theme.textTertiary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("文件清单").font(LXFont.captionStrong).foregroundStyle(theme.textSecondary)
                        ForEach(Array(parsedFiles.prefix(7)), id: \.relativePath) { file in
                            HStack(spacing: 7) {
                                Image(systemName: file.relativePath.hasPrefix("mods/") ? "puzzlepiece.extension" : "doc")
                                    .font(.system(size: 10))
                                    .foregroundStyle(theme.orange)
                                Text(file.relativePath).font(LXFont.monoSmall).foregroundStyle(theme.text)
                                if file.isOptional {
                                    Text("可选").font(LXFont.caption).foregroundStyle(theme.warning)
                                }
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: Int64(file.fileSize), countStyle: .file))
                                    .font(LXFont.monoSmall).foregroundStyle(theme.textTertiary)
                            }
                        }
                        if parsedFiles.count > 7 {
                            Text("… 还有 \(parsedFiles.count - 7) 个文件").font(LXFont.caption).foregroundStyle(theme.textTertiary)
                        }
                    }
                    .padding(10)
                    .background(theme.surfaceRaised.opacity(0.55), in: RoundedRectangle(cornerRadius: LXRadius.md, style: .continuous))

                    if let warningText {
                        Text(warningText)
                            .font(LXFont.caption)
                            .foregroundStyle(theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
    }

    private func optionalSection(_ package: MrpackPackage) -> some View {
        Group {
            if !package.optionalFiles.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("可选客户端模组").font(LXFont.captionStrong).foregroundStyle(theme.textSecondary)
                        Spacer()
                        Text("默认不安装；仅勾选的文件会下载")
                            .font(LXFont.caption).foregroundStyle(theme.textTertiary)
                    }
                    ForEach(package.optionalFiles, id: \.relativePath) { file in
                        Toggle(isOn: Binding(
                            get: { selectedOptionalPaths.contains(file.relativePath) },
                            set: { enabled in
                                if enabled { selectedOptionalPaths.insert(file.relativePath) }
                                else { selectedOptionalPaths.remove(file.relativePath) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.relativePath).font(LXFont.monoSmall).foregroundStyle(theme.text)
                                Text("由整合包作者标记为 optional；不需要时请保持关闭。")
                                    .font(LXFont.caption).foregroundStyle(theme.textTertiary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .tint(theme.orange)
                    }
                }
                .padding(10)
                .background(theme.surfaceRaised.opacity(0.55), in: RoundedRectangle(cornerRadius: LXRadius.md, style: .continuous))
            }
        }
    }

    private func javaSection(_ package: MrpackPackage) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Java").font(LXFont.captionStrong).foregroundStyle(theme.textSecondary)
                Spacer()
                if let javaRequirement {
                    Text("需要 Java \(javaRequirement.majorVersion.map(String.init) ?? "?")+\(javaRequirement.component.map { " · \($0)" } ?? "")")
                        .font(LXFont.caption).foregroundStyle(theme.textTertiary)
                }
            }
            if compatibleRuntimes.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.warning)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("没有找到兼容的 Java 运行时").font(LXFont.bodyStrong).foregroundStyle(theme.text)
                        Text("请先在设置页选择 Java，或到安装向导安装匹配的 Java。安装不会修改系统 Java。")
                            .font(LXFont.caption).foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    VStack(spacing: 6) {
                        LXButton("刷新", systemImage: "arrow.clockwise", kind: .ghost) {
                            Task { await model.refreshJavaRuntimes() }
                        }
                        if javaRequirement != nil {
                            LXButton("安装 Java", systemImage: "arrow.down.circle", kind: .primary) {
                                showJavaDownload = true
                            }
                            .disabled(isInstallingJava)
                        }
                    }
                }
                .padding(10)
                .background(theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: LXRadius.md, style: .continuous))
                if showJavaDownload, let javaRequirement {
                    javaDownloadCard(javaRequirement)
                }
                if let javaInstallMessage {
                    Text(javaInstallMessage).font(LXFont.caption).foregroundStyle(theme.textSecondary)
                }
            } else {
                Menu {
                    ForEach(compatibleRuntimes, id: \.executable.path) { runtime in
                        Button {
                            selectedJavaPath = runtime.executable.path
                        } label: {
                            if selectedJavaPath == runtime.executable.path {
                                Label(runtime.displayDescription, systemImage: "checkmark")
                            } else {
                                Text(runtime.displayDescription)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "cup.and.saucer").foregroundStyle(theme.orange)
                        Text(selectedRuntime?.displayDescription ?? "选择 Java")
                            .font(LXFont.body).foregroundStyle(theme.text)
                        Spacer()
                        Text(model.javaSourceLabel(for: selectedRuntime ?? compatibleRuntimes[0]))
                            .font(LXFont.caption).foregroundStyle(theme.textTertiary)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundStyle(theme.textTertiary)
                    }
                    .padding(9)
                    .background(theme.surfaceRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous).strokeBorder(theme.border, lineWidth: 0.8))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                if let selectedRuntime {
                    Text(selectedRuntime.executable.path)
                        .font(LXFont.monoSmall).foregroundStyle(theme.textTertiary).lineLimit(1)
                }
            }
        }
    }

    private func javaDownloadCard(_ requirement: JavaVersionRequirement) -> some View {
        LXCard(padding: 10, accent: theme.orange) {
            VStack(alignment: .leading, spacing: 7) {
                Text("安装 Java \(requirement.majorVersion.map(String.init) ?? "")")
                    .font(LXFont.bodyStrong).foregroundStyle(theme.text)
                Text("优先 Mojang 官方 java-runtime（\(requirement.component ?? "按版本元数据")）；不可用时回退 Eclipse Temurin。只写入启动器私有目录，不修改系统 Java。")
                    .font(LXFont.caption).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if isInstallingJava { ProgressView().controlSize(.small).tint(theme.orange) }
                    Spacer()
                    LXButton("取消", kind: .ghost) { showJavaDownload = false }
                        .disabled(isInstallingJava)
                    LXButton("下载并安装", systemImage: "arrow.down.circle", kind: .primary) {
                        installJava(requirement)
                    }
                    .disabled(isInstallingJava || package == nil)
                }
            }
        }
    }

    private func installJava(_ requirement: JavaVersionRequirement) {
        guard let package else { return }
        isInstallingJava = true
        showJavaDownload = false
        javaInstallMessage = "正在获取 Java…"
        Task {
            do {
                let managed = try await model.makeJavaManager().installManagedJava(
                    requirement: requirement,
                    minecraftVersionID: package.minecraftVersion
                ) { event in
                    Task { @MainActor in
                        switch event {
                        case let .metadata(message): self.javaInstallMessage = message
                        case let .downloading(total): self.javaInstallMessage = total.map { "下载 Java（\(Downloader.format(bytes: $0))）…" } ?? "下载 Java…"
                        case let .verifying(message): self.javaInstallMessage = "校验 Java… \(message)"
                        case let .extracting(message): self.javaInstallMessage = "解压 Java… \(message)"
                        case let .ready(url): self.javaInstallMessage = "Java 已就绪：\(url.lastPathComponent)"
                        }
                    }
                }
                await model.refreshJavaRuntimes()
                self.selectedJavaPath = managed.runtime.executable.path
                self.warningText = nil
                self.javaInstallMessage = "已安装 \(managed.source) \(managed.versionName)"
                self.isInstallingJava = false
            } catch {
                self.isInstallingJava = false
                self.javaInstallMessage = nil
                self.errorText = Self.describe(error)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress, isInstalling {
                HStack {
                    Text(phaseLabel(progress.phase)).font(LXFont.captionStrong).foregroundStyle(theme.orange)
                    Spacer()
                    Text(progress.message).font(LXFont.caption).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
                LXProgressBar(fraction: progress.total > 0 ? Double(progress.completed) / Double(progress.total) : 0, height: 7)
            }
            HStack {
                if package != nil {
                    LXButton("重新选择", systemImage: "arrow.left", kind: .ghost) {
                        cleanupPackage()
                        self.package = nil
                        selectedURL = nil
                        report = nil
                        errorText = nil
                    }
                    .disabled(isInstalling)
                }
                Spacer()
                if isInstalling {
                    LXButton("取消安装", kind: .ghost) {
                        installTask?.cancel()
                    }
                } else if report != nil {
                    LXButton("完成", kind: .primary) { closeImporter() }
                    LXButton("启动游戏", systemImage: "play.fill", kind: .primary) {
                        model.selectedInstanceID = report?.instanceID
                        model.launchSelectedInstance()
                        dismiss()
                    }
                } else {
                    LXButton("取消", kind: .ghost) { closeImporter() }
                    LXButton(installFailed ? "重试安装" : "安装整合包",
                             systemImage: installFailed ? "arrow.clockwise" : "arrow.down.circle",
                             kind: .primary) {
                        install()
                    }
                    .disabled(!canInstall)
                }
            }
        }
    }

    private func completionCard(_ report: MrpackInstallReport) -> some View {
        VStack(spacing: LXSpace.md) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 42))
                .foregroundStyle(theme.success)
            Text("整合包安装完成")
                .font(LXFont.display(24)).foregroundStyle(theme.text)
            Text("\(report.displayName) · Minecraft \(report.minecraftVersionID) · \(loaderLabel(report.loader))")
                .font(LXFont.body).foregroundStyle(theme.textSecondary)
            Text("\(report.installedFiles) 个整合包文件已提交；实例 \(report.instanceID)")
                .font(LXFont.caption).foregroundStyle(theme.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 390)
        .background(theme.surfaceRaised.opacity(0.4), in: RoundedRectangle(cornerRadius: LXRadius.lg, style: .continuous))
    }

    private func infoTile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(LXFont.caption).foregroundStyle(theme.textTertiary)
            Text(value).font(LXFont.bodyStrong).foregroundStyle(theme.text)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: LXRadius.md, style: .continuous))
    }

    private func parse(_ url: URL) {
        guard url.pathExtension.lowercased() == "mrpack" else {
            errorText = "请选择扩展名为 .mrpack 的 Modrinth 整合包"
            return
        }
        parseTask?.cancel()
        cleanupPackage()
        errorText = nil
        warningText = nil
        report = nil
        package = nil
        parsedFiles = []
        selectedOptionalPaths = []
        overrideCount = 0
        javaRequirement = nil
        selectedJavaPath = ""
        selectedURL = url
        displayName = ""
        isParsing = true
        installFailed = false
        let extractionRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingxi-mrpack-\(UUID().uuidString)", isDirectory: true)
        parseTask = Task {
            do {
                let parsed = try await Task.detached(priority: .userInitiated) {
                    try MrpackParser.parse(archive: url, extractionRoot: extractionRoot)
                }.value
                try Task.checkCancellation()
                self.package = parsed
                self.parsedFiles = parsed.files
                self.overrideCount = parsed.overrides.count
                self.displayName = parsed.name
                self.selectedURL = parsed.archiveURL
                do {
                    let requirement = try await model.makeMrpackInstaller().requiredJava(for: parsed)
                    self.javaRequirement = requirement
                    let manager = model.makeJavaManager()
                    let compatible = model.javaRuntimes.filter { manager.isCompatible($0, requirement: requirement) }
                    let best = compatible.min { lhs, rhs in
                        if lhs.architecture == .arm64 && rhs.architecture != .arm64 { return true }
                        if lhs.architecture != .arm64 && rhs.architecture == .arm64 { return false }
                        return lhs.majorVersion < rhs.majorVersion
                    }
                    self.selectedJavaPath = best?.executable.path ?? ""
                    if best == nil {
                        self.warningText = "没有找到兼容的 Java \(requirement.majorVersion.map(String.init) ?? "")；安装前需要选择或安装 Java。"
                    }
                } catch {
                    self.javaRequirement = nil
                    let best = model.javaRuntimes.min { lhs, rhs in
                        if lhs.architecture == .arm64 && rhs.architecture != .arm64 { return true }
                        if lhs.architecture != .arm64 && rhs.architecture == .arm64 { return false }
                        return lhs.majorVersion < rhs.majorVersion
                    }
                    self.selectedJavaPath = best?.executable.path ?? ""
                    self.warningText = "无法从 Mojang/Fabric/NeoForge 元数据确认 Java 要求：\(Self.describe(error))。仍可选择 Java，但请确认版本匹配。"
                }
                self.isParsing = false
            } catch is CancellationError {
                self.isParsing = false
            } catch {
                self.isParsing = false
                self.errorText = Self.describe(error)
                self.package = nil
            }
        }
    }

    private func install() {
        guard let package, let selectedRuntime, canInstall else { return }
        errorText = nil
        isInstalling = true
        progress = MrpackInstallProgress(phase: .downloading, message: "准备安装", completed: 0, total: 1)
        installTask = Task {
            do {
                let installer = try model.makeMrpackInstaller()
                let result = try await installer.install(
                    MrpackInstallRequest(
                        package: package,
                        displayName: displayName,
                        javaExecutable: selectedRuntime.executable,
                        sourcePolicy: model.settings.source,
                        concurrency: 4,
                        selectedOptionalPaths: selectedOptionalPaths,
                        traceModrinthSources: true
                    ),
                    progress: { event in
                        Task { @MainActor in self.progress = event }
                    }
                )
                self.isInstalling = false
                self.installFailed = false
                self.report = result
                model.reloadInstances()
                model.selectedInstanceID = result.instanceID
                model.appendLine("Imported modpack \(result.displayName) as \(result.instanceID)", source: "modpack")
            } catch is CancellationError {
                self.isInstalling = false
                self.installFailed = true
                self.errorText = "安装已取消；已验证缓存会保留，可直接重试，未提交新的整合包实例。"
            } catch {
                self.isInstalling = false
                self.installFailed = true
                self.errorText = Self.describe(error)
            }
        }
    }

    private func registerDebugActions() {
        let center = DebugAutomationCenter.shared
        guard center.isEnabled, debugTokens.isEmpty else { return }
        debugTokens.append(center.register("mrpack.state") { _ in
            self.debugState()
        })
        debugTokens.append(center.register("mrpack.parse") { params in
            guard let path = params["path"], !path.isEmpty else {
                return ["ok": false, "error": "path required"]
            }
            self.parse(URL(fileURLWithPath: path))
            await self.waitUntilParsed()
            var state = self.debugState()
            state["ok"] = self.errorText == nil
            return state
        })
        debugTokens.append(center.register("mrpack.install") { _ in
            guard self.canInstall else {
                return ["ok": false, "error": self.errorText ?? "not ready to install", "state": self.debugState()]
            }
            self.install()
            await self.waitUntilInstalled()
            var state = self.debugState()
            state["ok"] = self.report != nil && self.errorText == nil
            return state
        })
        debugTokens.append(center.register("mrpack.retry") { _ in
            guard self.package != nil, self.selectedRuntime != nil else {
                return ["ok": false, "error": self.errorText ?? "not ready to retry", "state": self.debugState()]
            }
            self.install()
            await self.waitUntilInstalled()
            var state = self.debugState()
            state["ok"] = self.report != nil && self.errorText == nil
            return state
        })
        debugTokens.append(center.register("mrpack.cancel") { _ in
            self.installTask?.cancel()
            await self.waitUntilInstalled()
            return self.debugState()
        })
        debugTokens.append(center.register("mrpack.optional") { params in
            guard let path = params["path"], let package = self.package,
                  package.optionalFiles.contains(where: { $0.relativePath == path }) else {
                return ["ok": false, "error": "unknown optional path"]
            }
            if params["selected"] == "false" {
                self.selectedOptionalPaths.remove(path)
            } else {
                self.selectedOptionalPaths.insert(path)
            }
            var state = self.debugState()
            state["ok"] = true
            return state
        })
        debugTokens.append(center.register("mrpack.close") { _ in
            self.closeImporter()
            return ["mrpackOpen": self.model.showMrpackImport]
        })
    }

    private func debugState() -> [String: Any] {
        [
            "parsing": isParsing,
            "installing": isInstalling,
            "name": displayName,
            "package": package.map {
                [
                    "name": $0.name,
                    "version": $0.versionID,
                    "minecraft": $0.minecraftVersion,
                    "files": $0.files.count,
                    "overrides": $0.overrides.count,
                ]
            } ?? [:],
            "java": selectedJavaPath,
            "optionalSelected": selectedOptionalPaths.sorted(),
            "installFailed": installFailed,
            "report": report.map {
                [
                    "instance": $0.instanceID,
                    "files": $0.installedFiles,
                    "identifiedMods": $0.identifiedMods,
                    "localMods": $0.localMods,
                ]
            } ?? [:],
            "error": errorText ?? "",
        ]
    }

    private func waitUntilParsed() async {
        while isParsing {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func waitUntilInstalled() async {
        while isInstalling || (report == nil && errorText == nil) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func closeImporter() {
        parseTask?.cancel()
        // Never delete the package tree while the installer still owns it. The footer's
        // cancel action is the retry-preserving path; closing again after cancellation is safe.
        guard !isInstalling else {
            installTask?.cancel()
            return
        }
        cleanupPackage()
        dismiss()
    }

    private func cleanupPackage() {
        guard let package else { return }
        try? FileManager.default.removeItem(at: package.extractionRoot)
    }

    private func loaderLabel(_ loader: InstallLoaderChoice) -> String {
        switch loader {
        case .vanilla: return "Vanilla"
        case let .fabric(version): return version.map { "Fabric \($0)" } ?? "Fabric"
        case let .neoforge(version): return version.map { "NeoForge \($0)" } ?? "NeoForge"
        }
    }

    private func phaseLabel(_ phase: MrpackInstallPhase) -> String {
        switch phase {
        case .downloading: return "下载"
        case .verifying: return "校验"
        case .installing: return "安装游戏"
        case .committing: return "提交"
        case .done: return "完成"
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? LauncherError {
            return error.suggestion.map { "\(error.message)\n\($0)" } ?? error.message
        }
        return error.localizedDescription
    }
}
