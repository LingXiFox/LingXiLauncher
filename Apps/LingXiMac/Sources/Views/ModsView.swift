import AppKit
import LauncherCore
import SwiftUI

struct ModsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.lxTheme) private var theme
    let instance: Instance
    @StateObject private var store: ModsStore
    @State private var selectedInstalledFileName: String?
    @State private var showDeleteConfirmation = false
    @State private var showUpdateConfirmation = false
    @State private var debugTokens: [UUID] = []

    init(instance: Instance, model: AppModel) {
        self.instance = instance
        _store = StateObject(wrappedValue: ModsStore(instance: instance, model: model))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            LXDivider()
            if let compatibilityError = store.compatibilityError {
                unsupported(compatibilityError)
            } else {
                tabBar
                if let error = store.errorMessage {
                    LXErrorBanner(
                        message: store.errorSuggestion.map { "\(error)\n\($0)" } ?? error,
                        dismiss: { store.clearError() }
                    )
                }
                Divider().overlay(theme.border)
                Group {
                    if store.tab == .installed {
                        installedView
                    } else {
                        browseView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
        .frame(width: 1060, height: 760)
        .background(theme.canvas)
        .task {
            await store.load()
            if store.tab == .browse, store.results.isEmpty { await store.search() }
            registerDebugActions()
        }
        .onDisappear { unregisterDebugActions() }
        .confirmationDialog(
            "删除模组？",
            isPresented: $showDeleteConfirmation,
            presenting: store.pendingDelete
        ) { mod in
            Button("删除 \(mod.fileName)", role: .destructive) {
                store.delete(mod)
                if selectedInstalledFileName == mod.fileName { selectedInstalledFileName = nil }
                store.pendingDelete = nil
            }
            Button("取消", role: .cancel) { store.pendingDelete = nil }
        } message: { mod in
            Text("将删除实例中的 \(mod.fileName)，不会修改存档或配置。此操作无法撤销。")
        }
        .confirmationDialog(
            "更新模组？",
            isPresented: $showUpdateConfirmation,
            presenting: store.pendingUpdate
        ) { update in
            Button("下载、校验并更新 \(update.title)") {
                store.pendingUpdate = nil
                Task { await store.update(update) }
            }
            Button("取消", role: .cancel) { store.pendingUpdate = nil }
        } message: { update in
            Text("旧文件会保留到新文件下载并通过哈希校验；替换失败会恢复旧文件。")
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .top, spacing: LXSpace.md) {
            VStack(alignment: .leading, spacing: 5) {
                LXOverline(text: "INSTANCE / MODS", color: theme.orange)
                Text("模组管理")
                    .font(LXFont.display(28))
                    .foregroundStyle(theme.text)
                Text("\(instance.manifest.displayName) · \(instance.manifest.versionID ?? "未绑定版本")")
                    .font(LXFont.caption)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if let compatibility = store.compatibility {
                LXBadge(text: "\(compatibility.gameVersion) · \(compatibility.loader.displayName)", tone: .success, dot: true)
            }
            LXIconButton(systemImage: "xmark", label: "关闭模组管理") { dismissSheet() }
        }
        .padding(.horizontal, LXSpace.xl)
        .padding(.vertical, LXSpace.lg)
        .background(theme.surface)
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(ModsStore.Tab.allCases) { tab in
                LXChip(title: tab.title, isSelected: store.tab == tab) {
                    Task { await store.selectTab(tab) }
                }
            }
            Spacer()
            if store.tab == .installed {
                LXButton("检查更新", systemImage: "arrow.triangle.2.circlepath", kind: .secondary, isDisabled: store.isCheckingUpdates) {
                    Task { await store.checkUpdates() }
                }
                if !store.updates.isEmpty {
                    LXBadge(text: "\(store.updates.count) 个更新", tone: .warning)
                }
            }
        }
        .padding(.horizontal, LXSpace.xl)
        .padding(.vertical, 9)
        .background(theme.canvas)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "shippingbox")
                .font(.system(size: 9))
            Text("模组数据来自 Modrinth 官方 API；文件由 cdn.modrinth.com 直接下载并校验发布方哈希。")
            Spacer()
            Text("Fabric / NeoForge")
                .foregroundStyle(theme.textTertiary)
        }
        .font(LXFont.monoSmall)
        .foregroundStyle(theme.textTertiary)
        .padding(.horizontal, LXSpace.xl)
        .padding(.vertical, 7)
        .background(theme.surface)
    }

    private func unsupported(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(theme.warning)
            Text("此实例暂不支持模组管理")
                .font(LXFont.title(23))
                .foregroundStyle(theme.text)
            Text(message)
                .font(LXFont.body)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            Text("请先在安装向导中创建/更新为 Fabric 或 NeoForge 实例。")
                .font(LXFont.caption)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Installed

    private var installedView: some View {
        HStack(alignment: .top, spacing: 0) {
            installedList
                .frame(width: 390)
            Divider().overlay(theme.border)
            installedDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedInstalledMod: InstalledMod? {
        if let selectedInstalledFileName,
           let mod = store.installed.first(where: { $0.fileName == selectedInstalledFileName }) {
            return mod
        }
        return store.installed.first
    }

    private var installedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                LXOverline(text: "LOCAL MODS")
                Spacer()
                Text("\(store.installed.count)")
                    .font(LXFont.monoSmall)
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, LXSpace.md)
            .padding(.top, LXSpace.md)

            if store.installed.isEmpty {
                LXEmptyState(
                    icon: "puzzlepiece.extension",
                    title: "还没有本地模组",
                    message: "到“浏览模组”搜索 Modrinth，或把 JAR 放入实例的 mods 目录。"
                )
                .padding(LXSpace.md)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(store.installed) { mod in
                            installedRow(mod)
                        }
                    }
                    .padding(.horizontal, LXSpace.md)
                    .padding(.bottom, LXSpace.md)
                }
                .scrollIndicators(.never)
            }
        }
        .background(theme.surface.opacity(0.45))
    }

    private func installedRow(_ mod: InstalledMod) -> some View {
        let selected = selectedInstalledMod?.fileName == mod.fileName
        return Button { selectedInstalledFileName = mod.fileName } label: {
            HStack(spacing: 9) {
                modTile(url: mod.iconURL, fallback: "shippingbox.fill", size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(mod.title)
                            .font(LXFont.bodyStrong)
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                        if store.updateFor(mod) != nil {
                            LXBadge(text: "可更新", tone: .warning)
                        }
                    }
                    Text(mod.fileName)
                        .font(LXFont.monoSmall)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                    Text(mod.versionNumber ?? mod.source)
                        .font(LXFont.caption)
                        .foregroundStyle(theme.textTertiary)
                }
                Spacer(minLength: 3)
                Image(systemName: mod.enabled ? "checkmark.circle.fill" : "pause.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(mod.enabled ? theme.success : theme.textTertiary)
                    .help(mod.enabled ? "已启用" : "已禁用")
            }
            .padding(9)
            .background(selected ? theme.orangeSoft : theme.surface, in: RoundedRectangle(cornerRadius: LXRadius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LXRadius.md, style: .continuous).strokeBorder(selected ? theme.orange.opacity(0.5) : theme.border, lineWidth: selected ? 1.2 : 0.8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var installedDetail: some View {
        Group {
            if let mod = selectedInstalledMod {
                ScrollView {
                    VStack(alignment: .leading, spacing: LXSpace.md) {
                        HStack(alignment: .top, spacing: 12) {
                            modTile(url: mod.iconURL, fallback: "shippingbox.fill", size: 62)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mod.title)
                                    .font(LXFont.title(23))
                                    .foregroundStyle(theme.text)
                                Text(mod.fileName)
                                    .font(LXFont.monoSmall)
                                    .foregroundStyle(theme.textTertiary)
                                    .textSelection(.enabled)
                                HStack(spacing: 6) {
                                    LXBadge(text: mod.enabled ? "已启用" : "已禁用", tone: mod.enabled ? .success : .neutral)
                                    LXBadge(text: mod.source == "modrinth" ? "Modrinth" : "本地", tone: mod.source == "modrinth" ? .accent : .neutral)
                                    if let license = mod.license { LXBadge(text: license, tone: .info) }
                                }
                            }
                            Spacer()
                        }

                        LXCard(padding: LXSpace.md) {
                            VStack(alignment: .leading, spacing: 8) {
                                LXKeyValue(label: "版本", value: mod.versionNumber ?? "本地文件")
                                LXKeyValue(label: "Project ID", value: mod.projectID ?? "无")
                                LXKeyValue(label: "状态", value: mod.enabled ? "游戏会加载此模组" : "文件已移到 mods-disabled")
                                if let update = store.updateFor(mod) {
                                    LXKeyValue(label: "可用更新", value: "\(update.latestVersionNumber) · \(update.latestFile.filename)")
                                }
                            }
                        }

                        if let update = store.updateFor(mod) {
                            LXCard(padding: LXSpace.md, accent: theme.orange) {
                                HStack(spacing: 9) {
                                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(theme.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("发现兼容的新版本")
                                            .font(LXFont.bodyStrong)
                                            .foregroundStyle(theme.text)
                                        Text("\(mod.versionNumber ?? "当前") → \(update.latestVersionNumber)")
                                            .font(LXFont.caption)
                                            .foregroundStyle(theme.textSecondary)
                                    }
                                    Spacer()
                                    LXButton("更新", systemImage: "arrow.down.circle", kind: .primary) {
                                        store.pendingUpdate = update
                                        showUpdateConfirmation = true
                                    }
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            LXButton(mod.enabled ? "禁用" : "启用", systemImage: mod.enabled ? "pause.fill" : "play.fill", kind: .secondary) {
                                store.toggle(mod)
                            }
                            if store.updateFor(mod) != nil {
                                LXButton("更新", systemImage: "arrow.triangle.2.circlepath", kind: .primary) {
                                    store.pendingUpdate = store.updateFor(mod)
                                    showUpdateConfirmation = true
                                }
                            }
                            Spacer()
                            LXButton("删除", systemImage: "trash", kind: .destructive) {
                                store.pendingDelete = mod
                                showDeleteConfirmation = true
                            }
                        }
                    }
                    .padding(LXSpace.xl)
                }
                .scrollIndicators(.never)
            } else {
                LXEmptyState(icon: "sidebar.left", title: "选择一个模组", message: "本地模组详情会显示在这里。")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Browse

    private var browseView: some View {
        VStack(spacing: 0) {
            searchBar
            HStack(alignment: .top, spacing: 0) {
                browseList
                    .frame(width: 390)
                Divider().overlay(theme.border)
                projectDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.textTertiary)
                TextField("搜索 Modrinth 模组…", text: $store.query)
                    .textFieldStyle(.plain)
                    .font(LXFont.body)
                    .onSubmit { Task { await store.search() } }
                if !store.query.isEmpty {
                    LXIconButton(systemImage: "xmark.circle.fill", label: "清除搜索") {
                        store.query = ""
                        Task { await store.search() }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous).strokeBorder(theme.border, lineWidth: 0.8))

            Menu {
                Button("全部分类") { store.selectedCategory = nil; Task { await store.search() } }
                Divider()
                ForEach(store.categories) { category in
                    Button(category.name) {
                        store.selectedCategory = category.name
                        Task { await store.search() }
                    }
                }
            } label: {
                filterLabel(store.selectedCategory ?? "全部分类")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Menu {
                ForEach(ModrinthSort.allCases, id: \.self) { sort in
                    Button(sort.displayName) {
                        store.sort = sort
                        Task { await store.search() }
                    }
                }
            } label: {
                filterLabel(store.sort.displayName)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            LXButton("搜索", systemImage: "magnifyingglass", kind: .primary, isDisabled: store.isSearching) {
                Task { await store.search() }
            }
        }
        .padding(.horizontal, LXSpace.xl)
        .padding(.vertical, 9)
    }

    private func filterLabel(_ text: String) -> some View {
        HStack(spacing: 5) {
            Text(text).font(LXFont.captionStrong).foregroundStyle(theme.textSecondary)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(theme.textTertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous))
    }

    private var browseList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                LXOverline(text: "MODRINTH")
                Spacer()
                Text(store.totalResults > 0 ? "\(store.totalResults) results" : "—")
                    .font(LXFont.monoSmall)
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, LXSpace.md)
            .padding(.top, LXSpace.md)

            if store.isSearching && store.results.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在搜索…").font(LXFont.caption).foregroundStyle(theme.textSecondary)
                }.padding(LXSpace.md)
                Spacer()
            } else if store.results.isEmpty {
                LXEmptyState(icon: "magnifyingglass", title: "搜索 Modrinth", message: "结果会按当前实例的 Minecraft 版本和 Mod Loader 过滤。")
                    .padding(LXSpace.md)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(store.results) { hit in
                            browseRow(hit)
                        }
                        if store.hasMore {
                            LXButton("加载更多", systemImage: "arrow.down.circle", kind: .secondary) {
                                Task { await store.search(reset: false) }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    .padding(.horizontal, LXSpace.md)
                    .padding(.bottom, LXSpace.md)
                }
                .scrollIndicators(.never)
            }
        }
        .background(theme.surface.opacity(0.45))
    }

    private func browseRow(_ hit: ModrinthProjectHit) -> some View {
        let selected = store.selectedHit?.projectID == hit.projectID
        let installed = store.installedProjectIDs.contains(hit.projectID)
        return Button {
            Task { await store.select(hit) }
        } label: {
            HStack(spacing: 9) {
                modTile(url: hit.iconURL, fallback: "cube.fill", size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(hit.title).font(LXFont.bodyStrong).foregroundStyle(theme.text).lineLimit(1)
                        if installed { LXBadge(text: "已安装", tone: .success) }
                    }
                    Text(hit.description).font(LXFont.caption).foregroundStyle(theme.textSecondary).lineLimit(2)
                    Text("\(hit.author ?? "Modrinth") · \(hit.downloads) downloads")
                        .font(LXFont.monoSmall).foregroundStyle(theme.textTertiary)
                }
                Spacer(minLength: 3)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(theme.textTertiary)
            }
            .padding(9)
            .background(selected ? theme.orangeSoft : theme.surface, in: RoundedRectangle(cornerRadius: LXRadius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LXRadius.md, style: .continuous).strokeBorder(selected ? theme.orange.opacity(0.5) : theme.border, lineWidth: selected ? 1.2 : 0.8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear { store.loadIcon(hit.iconURL) }
    }

    private var projectDetail: some View {
        Group {
            if store.isLoadingDetail {
                VStack(spacing: 9) { ProgressView(); Text("读取项目…").font(LXFont.caption).foregroundStyle(theme.textSecondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let project = store.project {
                ScrollView {
                    VStack(alignment: .leading, spacing: LXSpace.md) {
                        HStack(alignment: .top, spacing: 12) {
                            modTile(url: project.iconURL ?? store.selectedHit?.iconURL, fallback: "cube.fill", size: 64)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.title).font(LXFont.title(24)).foregroundStyle(theme.text)
                                Text(store.selectedHit?.author.map { "作者 \($0)" } ?? "Modrinth 项目")
                                    .font(LXFont.caption).foregroundStyle(theme.textSecondary)
                                HStack(spacing: 5) {
                                    if let license = project.license?.displayName { LXBadge(text: license, tone: .info) }
                                    if store.installedProjectIDs.contains(project.id) { LXBadge(text: "已安装", tone: .success) }
                                    LXBadge(text: "\(project.downloads) downloads", tone: .neutral)
                                }
                            }
                            Spacer()
                        }

                        Text(project.description)
                            .font(LXFont.body)
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let body = project.body, !body.isEmpty {
                            Text(cleanMarkdown(body))
                                .font(LXFont.caption)
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(14)
                        }

                        LXCard(padding: LXSpace.md) {
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    LXOverline(text: "VERSION")
                                    Spacer()
                                    if store.versions.isEmpty {
                                        Text("无兼容版本").font(LXFont.caption).foregroundStyle(theme.warning)
                                    }
                                }
                                if !store.versions.isEmpty {
                                    Menu {
                                        ForEach(store.versions) { version in
                                            Button {
                                                store.selectedVersionID = version.id
                                            } label: {
                                                if version.id == store.selectedVersion?.id {
                                                    Label("\(version.versionNumber) · \(version.versionType.rawValue)", systemImage: "checkmark")
                                                } else {
                                                    Text("\(version.versionNumber) · \(version.versionType.rawValue)")
                                                }
                                            }
                                        }
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(store.selectedVersion?.versionNumber ?? "选择版本")
                                                    .font(LXFont.bodyStrong).foregroundStyle(theme.text)
                                                Text(store.selectedVersion.map { "\($0.gameVersions.joined(separator: ", ")) · \($0.loaders.joined(separator: ", "))" } ?? "")
                                                    .font(LXFont.monoSmall).foregroundStyle(theme.textTertiary).lineLimit(1)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.up.chevron.down").foregroundStyle(theme.textTertiary)
                                        }
                                        .padding(9)
                                        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous))
                                    }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)

                                    if let version = store.selectedVersion {
                                        dependencySummary(version)
                                    }
                                }
                            }
                        }

                        if let version = store.selectedVersion, !version.dependencies.isEmpty {
                            LXCard(padding: LXSpace.md) {
                                VStack(alignment: .leading, spacing: 6) {
                                    LXOverline(text: "DEPENDENCIES")
                                    ForEach(Array(version.dependencies.enumerated()), id: \.offset) { _, dependency in
                                        HStack(spacing: 6) {
                                            LXBadge(text: dependencyLabel(dependency.type), tone: dependency.type == .required ? .warning : (dependency.type == .incompatible ? .danger : .neutral))
                                            Text(dependency.projectID ?? dependency.versionID ?? dependency.fileName ?? "未知依赖")
                                                .font(LXFont.monoSmall)
                                                .foregroundStyle(theme.textSecondary)
                                                .textSelection(.enabled)
                                            if dependency.versionID != nil {
                                                Text("固定版本").font(LXFont.caption).foregroundStyle(theme.textTertiary)
                                            }
                                        }
                                    }
                                    Text("必需依赖会在安装前自动解析；可选依赖不会自动安装。")
                                        .font(LXFont.caption).foregroundStyle(theme.textTertiary)
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            let already = store.installedProjectIDs.contains(project.id)
                            LXButton(already ? "重新安装" : "安装", systemImage: "arrow.down.circle", kind: .primary, isDisabled: store.isInstalling || store.versions.isEmpty) {
                                store.install(allowReplace: already)
                            }
                            if store.isInstalling {
                                LXButton("取消", systemImage: "stop.fill", kind: .destructive) { store.cancelInstall() }
                            }
                            Spacer()
                        }
                        if let progress = store.installProgress {
                            installProgressView(progress)
                        }
                    }
                    .padding(LXSpace.xl)
                }
                .scrollIndicators(.never)
            } else {
                LXEmptyState(icon: "square.grid.2x2", title: "选择一个项目", message: "查看介绍、兼容版本和依赖后安装。")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func cleanMarkdown(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\r", with: "")
        value = value.replacingOccurrences(of: "<br>", with: "\n")
        value = value.replacingOccurrences(of: "<br/>", with: "\n")
        value = value.replacingOccurrences(of: "<br />", with: "\n")
        value = value.replacingOccurrences(of: "**", with: "")
        value = value.replacingOccurrences(of: "__", with: "")
        value = value.replacingOccurrences(of: "`", with: "")
        let replacements: [(String, String)] = [
            ("<[^>]+>", ""),
            ("!\\[[^\\]]*\\]\\([^)]*\\)", ""),
            ("\\[([^\\]]+)\\]\\([^)]*\\)", "$1"),
            ("\\[\\([^)]*\\)\\]", ""),
            ("https?://\\S+", ""),
            ("(?m)^#{1,6}\\s*", ""),
            ("(?m)^---$", ""),
        ]
        for (pattern, template) in replacements {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(value.startIndex..<value.endIndex, in: value)
                value = regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: template)
            }
        }
        return value
    }

    private func dependencyLabel(_ type: ModrinthDependencyType) -> String {
        switch type {
        case .required: return "必需"
        case .optional: return "可选"
        case .incompatible: return "冲突"
        case .embedded: return "内嵌"
        case .unknown: return "依赖"
        }
    }

    private func dependencySummary(_ version: ModrinthVersion) -> some View {
        let required = version.dependencies.filter { $0.type == .required }
        let optional = version.dependencies.filter { $0.type == .optional }
        return HStack(spacing: 5) {
            if !required.isEmpty { LXBadge(text: "\(required.count) 必需依赖", tone: .warning) }
            if !optional.isEmpty { LXBadge(text: "\(optional.count) 可选", tone: .neutral) }
            if version.dependencies.contains(where: { $0.type == .incompatible }) {
                LXBadge(text: "存在冲突", tone: .danger)
            }
        }
    }

    private func installProgressView(_ progress: ModInstallProgress) -> some View {
        LXCard(padding: LXSpace.md) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(progress.message).font(LXFont.bodyStrong).foregroundStyle(theme.text)
                    Spacer()
                    Text("\(progress.completed)/\(progress.total)").font(LXFont.monoSmall).foregroundStyle(theme.textTertiary)
                }
                LXProgressBar(fraction: progress.total > 0 ? Double(progress.completed) / Double(progress.total) : 0, height: 6)
                if let file = progress.currentFile {
                    Text(file).font(LXFont.monoSmall).foregroundStyle(theme.textTertiary).lineLimit(1)
                }
                if let report = store.lastReport {
                    Text("已安装 \(report.installed.count) 个文件；来源哈希校验通过。")
                        .font(LXFont.caption).foregroundStyle(theme.success)
                }
            }
        }
    }

    @ViewBuilder
    private func modTile(url: String?, fallback: String, size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .fill(theme.surfaceRaised)
            if let url, let image = store.iconCache[url] {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
            } else {
                Image(systemName: fallback)
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(theme.orange)
            }
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).strokeBorder(theme.border, lineWidth: 0.7))
    }

    private func dismissSheet() {
        model.showModsForInstance = nil
    }

    // MARK: - Debug actions (opt-in, loopback only)

    private func registerDebugActions() {
        let center = DebugAutomationCenter.shared
        guard center.isEnabled else { return }
        debugTokens.append(center.register("mods.state") { _ in
            store.debugState()
        })
        debugTokens.append(center.register("mods.tab") { params in
            guard let raw = params["tab"], let tab = ModsStore.Tab(rawValue: raw) else {
                return ["ok": false, "error": "tab must be installed or browse"]
            }
            await store.selectTab(tab)
            return store.debugState()
        })
        debugTokens.append(center.register("mods.search") { params in
            if let query = params["query"] { store.query = query }
            if let category = params["category"], !category.isEmpty { store.selectedCategory = category }
            if let sortRaw = params["sort"], let sort = ModrinthSort(rawValue: sortRaw) { store.sort = sort }
            await store.search()
            return store.debugState()
        })
        debugTokens.append(center.register("mods.select") { params in
            guard let projectID = params["projectID"], !projectID.isEmpty else {
                return ["ok": false, "error": "projectID required"]
            }
            await store.select(projectID: projectID)
            return store.debugState()
        })
        debugTokens.append(center.register("mods.install") { params in
            guard store.project != nil else { return ["ok": false, "error": "select a project first"] }
            store.install(versionID: params["versionID"], allowReplace: params["replace"] == "true")
            await waitForInstall()
            return store.debugState()
        })
        debugTokens.append(center.register("mods.toggle") { params in
            guard let file = params["file"], let mod = store.installed.first(where: { $0.fileName == file }) else {
                return ["ok": false, "error": "installed mod not found"]
            }
            store.toggle(mod)
            return store.debugState()
        })
        debugTokens.append(center.register("mods.delete") { params in
            guard let file = params["file"], let mod = store.installed.first(where: { $0.fileName == file }) else {
                return ["ok": false, "error": "installed mod not found"]
            }
            store.delete(mod)
            return store.debugState()
        })
        debugTokens.append(center.register("mods.checkUpdates") { _ in
            await store.checkUpdates()
            return store.debugState()
        })
        debugTokens.append(center.register("mods.update") { params in
            guard let projectID = params["projectID"] else { return ["ok": false, "error": "projectID required"] }
            if store.updates.isEmpty { await store.checkUpdates() }
            guard let update = store.updates.first(where: { $0.projectID == projectID }) else {
                return ["ok": false, "error": "no update for project"]
            }
            await store.update(update)
            return store.debugState()
        })
        debugTokens.append(center.register("mods.close") { _ in
            dismissSheet()
            return ["modsOpen": model.showModsForInstance?.id ?? ""]
        })
    }

    private func unregisterDebugActions() {
        for token in debugTokens { DebugAutomationCenter.shared.unregister(token) }
        debugTokens.removeAll()
    }

    private func waitForInstall() async {
        while store.isInstalling {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
