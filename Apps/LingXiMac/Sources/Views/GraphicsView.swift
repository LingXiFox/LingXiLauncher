import SwiftUI
import UniformTypeIdentifiers
import LauncherCore

struct GraphicsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lxTheme) private var theme
    @StateObject private var store: GraphicsStore
    @State private var showImporter = false
    @State private var showReplaceConfirmation = false
    @State private var debugTokens: [UUID] = []
    private let model: AppModel

    init(instance: Instance, model: AppModel) {
        self.model = model
        _store = StateObject(wrappedValue: GraphicsStore(
            instance: instance,
            setupManager: model.makeGraphicsSetupManager(),
            shaderManager: model.makeShaderPackManager()
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.border)
            if let error = store.compatibilityError {
                unsupported(error)
            } else {
                HStack(spacing: 0) {
                    sidebar
                    Divider().overlay(theme.border)
                    content
                }
            }
        }
        .frame(minWidth: 940, minHeight: 620)
        .background(theme.canvas)
        .task {
            await store.load()
            registerDebugActions()
        }
        .onDisappear { unregisterDebugActions() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip]) { result in
            if case .success(let url) = result {
                Task { await store.importLocal(url: url) }
            }
        }
        .confirmationDialog(
            "替换现有的 Iris / Sodium？",
            isPresented: $showReplaceConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认替换", role: .destructive) {
                Task { await store.installGraphics(allowReplace: true) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("现有版本会被备份后替换。只有所有下载通过哈希校验后才会提交。")
        }
        .confirmationDialog(
            "删除光影包？",
            isPresented: Binding(
                get: { store.pendingDelete != nil },
                set: { if !$0 { store.pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let pack = store.pendingDelete { store.remove(pack) }
                store.pendingDelete = nil
            }
            Button("取消", role: .cancel) { store.pendingDelete = nil }
        } message: {
            Text("只会删除该光影的 ZIP 与启动器记录，不会修改存档、配置或已启用的 Iris 设置。")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            LXPageHeader(
                eyebrow: "INSTANCE / GRAPHICS",
                title: "图形与光影",
                subtitle: "\(store.instance.manifest.displayName) · Minecraft \(store.gameVersion)"
            )
            Spacer()
            if store.isInstallingGraphics || store.isInstallingShader {
                ProgressView().controlSize(.small)
            }
            LXIconButton(systemImage: "xmark", label: "关闭") { dismiss() }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(theme.surface)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("光影工作台")
                .font(LXFont.captionStrong)
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 12)
                .padding(.top, 4)
            ForEach(GraphicsStore.Tab.allCases) { tab in
                Button {
                    store.tab = tab
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 18)
                        Text(tab.title)
                            .font(LXFont.bodyStrong)
                        Spacer()
                        if tab == .installed, !store.installed.isEmpty {
                            LXBadge(text: "\(store.installed.count)", tone: .neutral)
                        }
                        if tab == .installed, !store.updates.isEmpty {
                            Circle().fill(theme.orange).frame(width: 6, height: 6)
                        }
                    }
                    .foregroundStyle(store.tab == tab ? theme.orange : theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(store.tab == tab ? theme.orangeSoft : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 6) {
                Label("macOS OpenGL", systemImage: "display")
                    .font(LXFont.captionStrong)
                    .foregroundStyle(theme.textSecondary)
                Text(store.capabilities.summary)
                    .font(LXFont.caption)
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.capabilities.isLegacyOpenGL {
                    Text("GL 4.1 上限")
                        .font(LXFont.captionStrong)
                        .foregroundStyle(theme.orange)
                }
            }
            .padding(12)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.border, lineWidth: 0.8))
            .padding(8)
        }
        .padding(.vertical, 12)
        .frame(width: 210)
        .background(theme.sidebar)
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if let error = store.errorMessage {
                LXErrorBanner(message: error) { store.errorMessage = nil }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }
            if let notice = store.notice {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.success)
                    Text(notice).font(LXFont.caption).foregroundStyle(theme.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.top, 10)
            }
            switch store.tab {
            case .installed: installedContent
            case .browse: browseContent
            case .setup: setupContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var installedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("已安装光影").font(LXFont.headline).foregroundStyle(theme.text)
                        Text("光影包是 ZIP 文件；是否启用由 Iris 配置决定，安装本身不会自动启用。")
                            .font(LXFont.caption).foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    LXButton("导入本地 ZIP", systemImage: "square.and.arrow.down", kind: .secondary) { showImporter = true }
                    LXButton("打开目录", systemImage: "folder", kind: .ghost) { store.openFolder() }
                    LXButton("检查更新", systemImage: "arrow.triangle.2.circlepath", kind: .ghost) {
                        Task { await store.refreshEnvironment() }
                    }
                }
                if store.isLoading && store.installed.isEmpty {
                    ProgressView("读取光影目录…").frame(maxWidth: .infinity, minHeight: 160)
                } else if store.installed.isEmpty {
                    LXEmptyState(
                        icon: "sparkles",
                        title: "还没有安装光影",
                        message: "从 Modrinth 浏览并安装光影包，或导入本地 ZIP。安装后可在这里启用。",
                        actionTitle: "浏览 Modrinth"
                    ) { store.tab = .browse }
                } else {
                    if let activation = store.activationState, activation.kind == .enabled, let name = activation.shaderPack {
                        HStack(spacing: 8) {
                            Image(systemName: "sun.max.fill").foregroundStyle(theme.orange)
                            Text("Iris 当前启用：\(name)").font(LXFont.bodyStrong).foregroundStyle(theme.text)
                            Spacer()
                            LXButton("关闭光影", kind: .ghost) { store.deactivate() }
                        }
                        .padding(12)
                        .background(theme.orangeSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    ForEach(store.installed) { pack in
                        installedRow(pack)
                    }
                }
            }
            .padding(20)
        }
    }

    private func installedRow(_ pack: InstalledShaderPack) -> some View {
        LXCard(padding: 12) {
            HStack(spacing: 12) {
                packIcon(pack.iconURL, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(pack.title).font(LXFont.bodyStrong).foregroundStyle(theme.text)
                        LXBadge(text: pack.source == .modrinth ? "Modrinth" : "Local", tone: pack.source == .modrinth ? .accent : .neutral)
                        if store.activationState?.kind == .enabled, store.activationState?.shaderPack == pack.title {
                            LXBadge(text: "已启用", tone: .success)
                        }
                    }
                    Text("\(pack.versionNumber ?? "本地文件") · \(pack.fileName)")
                        .font(LXFont.caption).foregroundStyle(theme.textSecondary).lineLimit(1)
                    if let license = pack.license {
                        Text("许可证：\(license)").font(LXFont.caption).foregroundStyle(theme.textTertiary)
                    }
                }
                Spacer()
                if let update = store.updates.first(where: { $0.projectID == pack.projectID }) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("可更新至 \(update.latestVersionNumber)")
                            .font(LXFont.caption).foregroundStyle(theme.orange)
                        LXButton("更新", systemImage: "arrow.down.circle", kind: .primary, isDisabled: store.isInstallingShader) {
                            Task { await store.update(update) }
                        }
                    }
                } else {
                    Text("已是最新").font(LXFont.caption).foregroundStyle(theme.textTertiary)
                }
                LXButton("启用", systemImage: "sun.max", kind: .secondary, isDisabled: store.activationState?.kind == .enabled && store.activationState?.shaderPack == pack.title) {
                    store.activate(pack)
                }
                LXButton("删除", systemImage: "trash", kind: .ghost) { store.pendingDelete = pack }
            }
        }
    }

    private var browseContent: some View {
        Group {
            if store.selectedProject != nil {
                detailContent
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 9) {
                            TextField("搜索光影包、作者或关键词", text: $store.searchText)
                                .textFieldStyle(.plain)
                                .lxInput()
                                .onSubmit { Task { await store.search() } }
                            LXButton("搜索", systemImage: "magnifyingglass", kind: .primary) {
                                Task { await store.search() }
                            }
                        }
                        HStack(spacing: 7) {
                            Text("排序").font(LXFont.caption).foregroundStyle(theme.textTertiary)
                            ForEach([ModrinthSort.downloads, .relevance, .newest, .updated], id: \.rawValue) { sort in
                                LXChip(title: sort.displayName, isSelected: store.sort == sort) {
                                    store.sort = sort
                                    Task { await store.search() }
                                }
                            }
                            Spacer()
                            Text("Minecraft \(store.gameVersion) · \(store.loaderName)").font(LXFont.caption).foregroundStyle(theme.textTertiary)
                        }
                        if store.isSearching {
                            ProgressView("搜索 Modrinth…").frame(maxWidth: .infinity, minHeight: 160)
                        } else if store.searchResults.isEmpty {
                            LXEmptyState(icon: "safari", title: "搜索 Modrinth 光影", message: "结果只包含声明支持 Minecraft \(store.gameVersion) 的光影项目。")
                        } else {
                            Text("\(store.totalHits) 个结果").font(LXFont.caption).foregroundStyle(theme.textTertiary)
                            LazyVStack(spacing: 9) {
                                ForEach(store.searchResults) { hit in
                                    searchRow(hit)
                                }
                            }
                            if store.searchOffset + 24 < store.totalHits {
                                LXButton("加载更多", kind: .secondary) { Task { await store.nextPage() } }
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private func searchRow(_ hit: ModrinthProjectHit) -> some View {
        Button {
            Task { await store.selectProject(hit) }
        } label: {
            HStack(spacing: 12) {
                packIcon(hit.iconURL, size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text(hit.title).font(LXFont.bodyStrong).foregroundStyle(theme.text)
                    Text(hit.description).font(LXFont.caption).foregroundStyle(theme.textSecondary).lineLimit(2)
                    HStack(spacing: 8) {
                        Text("\(hit.downloads) 下载").font(LXFont.caption).foregroundStyle(theme.textTertiary)
                        if let author = hit.author { Text("· \(author)").font(LXFont.caption).foregroundStyle(theme.textTertiary) }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textTertiary)
            }
            .padding(12)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.border, lineWidth: 0.8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var detailContent: some View {
        ScrollView {
            if let project = store.selectedProject {
                VStack(alignment: .leading, spacing: 16) {
                    Button { store.closeDetail() } label: {
                        Label("返回搜索结果", systemImage: "chevron.left")
                            .font(LXFont.captionStrong).foregroundStyle(theme.textSecondary)
                    }
                    .buttonStyle(.plain)

                    HStack(alignment: .top, spacing: 14) {
                        packIcon(project.iconURL, size: 64)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(project.title).font(LXFont.display(26)).foregroundStyle(theme.text)
                            Text(project.description).font(LXFont.body).foregroundStyle(theme.textSecondary)
                            HStack(spacing: 8) {
                                LXBadge(text: "光影", tone: .accent)
                                if let license = project.license { LXBadge(text: license.displayName, tone: .neutral) }
                                Text("\(project.downloads) 下载").font(LXFont.caption).foregroundStyle(theme.textTertiary)
                            }
                        }
                        Spacer()
                    }

                    LXCard(padding: 16) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(cleanMarkdown(project.body ?? project.description))
                                .font(LXFont.body).foregroundStyle(theme.textSecondary)
                                .lineSpacing(3).lineLimit(10)
                            Divider().overlay(theme.border)
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("版本").font(LXFont.caption).foregroundStyle(theme.textTertiary)
                                    Picker("版本", selection: $store.selectedVersionID) {
                                        ForEach(store.selectedVersions) { version in
                                            Text("\(version.versionNumber) · \(version.versionType.rawValue)").tag(Optional(version.id))
                                        }
                                    }
                                    .labelsHidden().frame(maxWidth: 280)
                                }
                                Spacer()
                                if store.installedForProject != nil {
                                    LXBadge(text: "已安装", tone: .success)
                                }
                                LXButton("安装此版本", systemImage: "arrow.down.circle", kind: .primary, isDisabled: store.isInstallingShader || store.selectedVersion == nil) {
                                    Task { await store.installSelectedShader() }
                                }
                            }
                            if store.selectedVersions.isEmpty {
                                Text("没有适用于 Minecraft \(store.gameVersion) 的版本。").font(LXFont.caption).foregroundStyle(theme.danger)
                            }
                        }
                    }
                    Text("许可证与项目页：Modrinth / \(project.slug ?? project.id)。资源文件来自 Modrinth CDN，启动器会校验大小与 SHA-1/SHA-512。")
                        .font(LXFont.caption).foregroundStyle(theme.textTertiary)
                }
                .padding(20)
            }
        }
    }

    private var setupContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Iris + Sodium").font(LXFont.display(24)).foregroundStyle(theme.text)
                        Text("性能渲染 + 光影支持。仅修改该实例的 mods，不触碰其他实例或系统 Java。")
                            .font(LXFont.caption).foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    if let environment = store.environment, environment.isReady {
                        LXBadge(text: "已就绪", tone: .success)
                    } else {
                        LXBadge(text: "未就绪", tone: .warning)
                    }
                }

                LXCard(padding: 14) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                        LXKeyValue(label: "Minecraft", value: store.gameVersion)
                        LXKeyValue(label: "\(store.loaderName) Loader", value: store.loaderVersion ?? "未知")
                        LXKeyValue(label: "Java", value: store.environment?.javaDescription ?? "未检测")
                        LXKeyValue(label: "图形", value: store.capabilities.summary)
                    }
                }

                if let warning = store.capabilities.shaderCompatibilityWarning {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.warning)
                        Text(warning).font(LXFont.caption).foregroundStyle(theme.textSecondary)
                        Spacer()
                    }
                    .padding(12)
                    .background(theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }

                if let environment = store.environment {
                    ForEach([("Iris", environment.iris, environment.recommendedIris, GraphicsSetupManager.irisProjectID),
                             ("Sodium", environment.sodium, environment.recommendedSodium, GraphicsSetupManager.sodiumProjectID)], id: \.0) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.0 == "Iris" ? "sparkles" : "bolt.fill")
                                .foregroundStyle(theme.orange).frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.0).font(LXFont.bodyStrong).foregroundStyle(theme.text)
                                if let installed = item.1 {
                                    Text("已安装 \(installed.versionNumber ?? installed.fileName)").font(LXFont.caption).foregroundStyle(theme.textSecondary)
                                } else {
                                    Text("尚未安装").font(LXFont.caption).foregroundStyle(theme.textTertiary)
                                }
                                if let recommended = item.2 {
                                    Text("推荐 \(recommended.versionNumber) · \(store.loaderName) \(store.gameVersion)")
                                        .font(LXFont.caption).foregroundStyle(theme.textTertiary)
                                }
                            }
                            Spacer()
                            if let installed = item.1, installed.enabled == false {
                                LXBadge(text: "已禁用", tone: .warning)
                            }
                        }
                        .padding(12)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    if !environment.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(environment.warnings, id: \.self) { warning in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("·").foregroundStyle(theme.orange)
                                    Text(warning).font(LXFont.caption).foregroundStyle(theme.textSecondary)
                                }
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        LXButton(environment.iris == nil || environment.sodium == nil ? "一键安装 Iris + Sodium" : "检查并更新", systemImage: "wand.and.stars", kind: .primary, isDisabled: store.isInstallingGraphics) {
                            if environment.hasUpdate || environment.iris == nil || environment.sodium == nil {
                                Task { await store.installGraphics(allowReplace: false) }
                            } else {
                                Task { await store.installGraphics(allowReplace: false) }
                            }
                        }
                        if environment.hasUpdate {
                            LXButton("替换现有版本", kind: .secondary, isDisabled: store.isInstallingGraphics) {
                                showReplaceConfirmation = true
                            }
                        }
                        Spacer()
                        Text("Iris \(environment.recommendedIris?.versionNumber ?? "—") / Sodium \(environment.recommendedSodium?.versionNumber ?? "—")")
                            .font(LXFont.caption).foregroundStyle(theme.textTertiary)
                    }

                    if store.isInstallingGraphics {
                        VStack(alignment: .leading, spacing: 6) {
                            LXProgressBar(fraction: 0.55)
                            Text(store.progressMessage ?? "正在处理 Iris / Sodium…").font(LXFont.caption).foregroundStyle(theme.textSecondary)
                        }
                    }
                } else if store.isLoading {
                    ProgressView("读取图形环境…").frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .padding(20)
        }
    }

    private func unsupported(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 30)).foregroundStyle(theme.orange)
            Text("此实例不能使用光影工作台").font(LXFont.headline).foregroundStyle(theme.text)
            Text(message).font(LXFont.body).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            Text("请先在实例安装向导中选择 Fabric 或 NeoForge，并确认实例版本可解析。").font(LXFont.caption).foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    @ViewBuilder
    private func packIcon(_ urlString: String?, size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(theme.orangeSoft)
            if let urlString, let image = store.icons[urlString] {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                Image(systemName: "sparkles").font(.system(size: size * 0.34, weight: .light)).foregroundStyle(theme.orange)
            }
        }
        .frame(width: size, height: size)
    }

    private func cleanMarkdown(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "```", with: "")
        result = result.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "##", with: "")
        result = result.replacingOccurrences(of: "###", with: "")
        result = result.replacingOccurrences(of: "[", with: "")
        result = result.replacingOccurrences(of: "](", with: " (")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // MARK: - Debug actions (opt-in; same methods as visible controls)

    private func registerDebugActions() {
        let center = DebugAutomationCenter.shared
        guard center.isEnabled else { return }
        debugTokens.append(center.register("graphics.state") { _ in
            store.debugState()
        })
        debugTokens.append(center.register("graphics.tab") { params in
            guard let raw = params["tab"], let tab = GraphicsStore.Tab(rawValue: raw) else {
                return ["ok": false, "error": "tab must be installed, browse or setup"]
            }
            store.tab = tab
            return store.debugState()
        })
        debugTokens.append(center.register("graphics.setup") { params in
            await store.installGraphics(allowReplace: params["replace"] == "true")
            return store.debugState()
        })
        debugTokens.append(center.register("graphics.search") { params in
            if let query = params["query"] { store.searchText = query }
            if let raw = params["sort"], let sort = ModrinthSort(rawValue: raw) { store.sort = sort }
            await store.search()
            return store.debugState()
        })
        debugTokens.append(center.register("graphics.select") { params in
            guard let projectID = params["projectID"], !projectID.isEmpty else {
                return ["ok": false, "error": "projectID required"]
            }
            guard let hit = store.searchResults.first(where: { $0.projectID == projectID }) else {
                return ["ok": false, "error": "project not in current search results"]
            }
            await store.selectProject(hit)
            return store.debugState()
        })
        debugTokens.append(center.register("graphics.install") { params in
            if let versionID = params["versionID"], !versionID.isEmpty {
                store.selectedVersionID = versionID
            }
            guard store.selectedVersion != nil else { return ["ok": false, "error": "select a shader version first"] }
            await store.installSelectedShader()
            return store.debugState()
        })
        debugTokens.append(center.register("graphics.import") { params in
            guard let path = params["path"], !path.isEmpty else { return ["ok": false, "error": "path required"] }
            await store.importLocal(url: URL(fileURLWithPath: path))
            return store.debugState()
        })
        debugTokens.append(center.register("graphics.activate") { params in
            guard let file = params["file"], let pack = store.installed.first(where: { $0.fileName == file }) else {
                return ["ok": false, "error": "installed shader not found"]
            }
            store.activate(pack)
            return store.debugState()
        })
        debugTokens.append(center.register("graphics.deactivate") { _ in
            store.deactivate()
            return store.debugState()
        })
        debugTokens.append(center.register("graphics.update") { params in
            guard let projectID = params["projectID"], let update = store.updates.first(where: { $0.projectID == projectID }) else {
                return ["ok": false, "error": "no update for project"]
            }
            await store.update(update)
            return store.debugState()
        })
        debugTokens.append(center.register("graphics.remove") { params in
            guard let file = params["file"], let pack = store.installed.first(where: { $0.fileName == file }) else {
                return ["ok": false, "error": "installed shader not found"]
            }
            store.remove(pack)
            return store.debugState()
        })
        debugTokens.append(center.register("graphics.close") { _ in
            model.showGraphicsForInstance = nil
            dismiss()
            return ["graphicsOpen": model.showGraphicsForInstance?.id ?? ""]
        })
    }

    private func unregisterDebugActions() {
        for token in debugTokens { DebugAutomationCenter.shared.unregister(token) }
        debugTokens.removeAll()
    }

}
