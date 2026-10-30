import LauncherCore
import SwiftUI
import UniformTypeIdentifiers

struct InstancesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.lxTheme) private var theme

    @State private var showCreate = false
    @State private var newName = ""
    @State private var newVersion = ""
    @State private var pendingDelete: Instance?
    @State private var memoryTarget: Instance?
    @State private var memoryText = ""
    @State private var memoryAutomatic = true
    @State private var isMrpackDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: LXSpace.md) {
            LXPageHeader(
                eyebrow: "LIBRARY / INSTANCES",
                title: "游戏实例",
                subtitle: "每个实例都有独立的版本、内存与游戏目录。"
            ) {
                HStack(spacing: 8) {
                    LXIconButton(systemImage: "arrow.clockwise", label: "刷新实例") {
                        model.reloadInstances()
                    }
                    LXButton("导入整合包", systemImage: "shippingbox", kind: .ghost) {
                        model.openMrpackImport()
                    }
                    LXButton("新建实例", systemImage: "plus", kind: .primary) {
                        showCreate = true
                    }
                }
                .padding(.top, 3)
            }

            HStack(alignment: .top, spacing: LXSpace.md) {
                instanceList
                    .frame(width: 300)
                detailPane
                    .frame(minWidth: 0, maxWidth: .infinity)
            }
        }
        .padding(.horizontal, LXSpace.xxl)
        .padding(.vertical, LXSpace.xl)
        .frame(maxWidth: 1240, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.canvas)
        .sheet(isPresented: $showCreate) { createSheet }
        .sheet(item: $memoryTarget) { instance in memorySheet(instance) }
        .sheet(item: $model.showModsForInstance) { instance in
            ModsView(instance: instance, model: model)
                .environmentObject(model)
                .environment(\.lxTheme, theme)
        }
        .sheet(item: $model.showResourcePacksForInstance) { instance in
            ResourcePacksView(instance: instance, manager: model.makeResourcePackManager())
        }
        .sheet(item: $model.showGraphicsForInstance) { instance in
            GraphicsView(instance: instance, model: model)
                .environmentObject(model)
                .environment(\.lxTheme, theme)
        }
        .sheet(item: $model.showPerformanceForInstance) { instance in
            PerformanceView(instance: instance, model: model)
                .environmentObject(model)
                .environment(\.lxTheme, theme)
        }
        .sheet(item: $model.showInstanceToolsForInstance) { instance in
            InstanceToolsView(instance: instance)
                .environmentObject(model)
                .environment(\.lxTheme, theme)
        }
        .sheet(isPresented: $model.showMrpackImport) {
            MrpackImportView()
                .environmentObject(model)
                .environment(\.lxTheme, theme)
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isMrpackDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                guard let url, url.pathExtension.lowercased() == "mrpack" else {
                    Task { @MainActor in model.lastError = "请拖入扩展名为 .mrpack 的 Modrinth 整合包" }
                    return
                }
                Task { @MainActor in model.openMrpackImport(url: url) }
            }
            return true
        }
        .overlay {
            if isMrpackDropTargeted {
                RoundedRectangle(cornerRadius: LXRadius.lg, style: .continuous)
                    .strokeBorder(theme.orange, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    .padding(10)
                    .allowsHitTesting(false)
                    .overlay {
                        Text("松开以导入 .mrpack")
                            .font(LXFont.bodyStrong)
                            .foregroundStyle(theme.orange)
                            .padding(14)
                            .background(theme.canvas.opacity(0.92), in: Capsule())
                    }
            }
        }
        .confirmationDialog(
            "删除实例？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { instance in
            Button("删除 \(instance.manifest.displayName)", role: .destructive) {
                model.deleteInstance(instance)
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { instance in
            Text("这会删除实例元数据、隔离游戏目录及其中的世界、配置与日志：\n\(instance.directory.path)\n\(instance.gameDirectory.path)\n此操作不可撤销。")
        }
    }

    private var instanceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                LXOverline(text: "ALL INSTANCES")
                Spacer()
                Text("\(model.instances.count)")
                    .font(LXFont.monoSmall)
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 2)
            .padding(.bottom, LXSpace.sm)

            if model.instances.isEmpty {
                LXCard(padding: 0) {
                    LXEmptyState(
                        icon: "square.stack.3d.up",
                        title: "还没有实例",
                        message: "创建一个空实例，或到版本下载安装 Minecraft。",
                        actionTitle: "安装版本"
                    ) {
                        model.section = .downloads
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(model.instances) { instance in
                            InstanceRow(
                                instance: instance,
                                selected: model.selectedInstanceID == instance.id,
                                running: model.isGameRunning && model.selectedInstanceID == instance.id,
                                onSelect: { model.selectedInstanceID = instance.id },
                                onOpen: { model.openInstanceFolder(instance) },
                                onMemory: {
                                    memoryTarget = instance
                                    memoryAutomatic = instance.manifest.memoryMiB == nil
                                    memoryText = instance.manifest.memoryMiB.map(String.init) ?? ""
                                },
                                onDelete: { pendingDelete = instance },
                                onMods: { model.openMods(instance: instance) },
                                onLaunch: {
                                    model.selectedInstanceID = instance.id
                                    model.launchSelectedInstance()
                                }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.never)
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let instance = model.selectedInstance {
            InstanceDetailPane(
                instance: instance,
                onEditMemory: {
                    memoryTarget = instance
                    memoryAutomatic = instance.manifest.memoryMiB == nil
                    memoryText = instance.manifest.memoryMiB.map(String.init) ?? ""
                },
                onDelete: { pendingDelete = instance },
                onMods: { model.openMods(instance: instance) }
            )
        } else {
            LXCard(padding: 0) {
                LXEmptyState(
                    icon: "sidebar.left",
                    title: "选择一个实例",
                    message: "实例详情、内存与启动操作会显示在这里。"
                )
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: LXSpace.lg) {
            HStack {
                LXOverline(text: "NEW INSTANCE", color: theme.orange)
                Spacer()
                LXIconButton(systemImage: "xmark", label: "关闭") { showCreate = false }
            }
            Text("创建游戏实例")
                .font(LXFont.display(26))
                .foregroundStyle(theme.text)
            Text("实例会在唯一 `.minecraft/versions/` 下获得独立隔离目录；版本可以稍后绑定。")
                .font(LXFont.body)
                .foregroundStyle(theme.textSecondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("显示名称").font(LXFont.captionStrong).foregroundStyle(theme.textSecondary)
                TextField("例如：Survival 1.20.1", text: $newName)
                    .lxInput()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Minecraft 版本").font(LXFont.captionStrong).foregroundStyle(theme.textSecondary)
                Menu {
                    Button("稍后绑定") { newVersion = "" }
                    if !model.installedVersionIDs.isEmpty {
                        Divider()
                        ForEach(model.installedVersionIDs, id: \.self) { version in
                            Button {
                                newVersion = version
                            } label: {
                                if newVersion == version {
                                    Label(version, systemImage: "checkmark")
                                } else {
                                    Text(version)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Text(newVersion.isEmpty ? "稍后绑定" : newVersion)
                            .font(LXFont.body)
                            .foregroundStyle(theme.text)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(theme.canvas.opacity(theme.isDark ? 0.55 : 0.45), in: RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous)
                            .strokeBorder(theme.border, lineWidth: 0.8)
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                if model.installedVersionIDs.isEmpty {
                    Text("还没有本地版本；可先到版本下载安装。")
                        .font(LXFont.caption)
                        .foregroundStyle(theme.warning)
                }
            }
            HStack {
                Spacer()
                LXButton("取消", kind: .ghost) { showCreate = false }
                LXButton("创建实例", systemImage: "plus", kind: .primary, isDisabled: newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    model.createInstance(name: newName, versionID: newVersion.isEmpty ? nil : newVersion)
                    showCreate = false
                    newName = ""
                    newVersion = ""
                }
            }
        }
        .padding(LXSpace.xl)
        .frame(width: 460)
        .background(theme.canvas)
        .environment(\.lxTheme, theme)
    }

    private func memorySheet(_ instance: Instance) -> some View {
        VStack(alignment: .leading, spacing: LXSpace.lg) {
            HStack {
                LXOverline(text: "JVM MEMORY", color: theme.orange)
                Spacer()
                LXIconButton(systemImage: "xmark", label: "关闭") { memoryTarget = nil }
            }
            Text("内存上限")
                .font(LXFont.display(26))
                .foregroundStyle(theme.text)
            Text("为 \(instance.manifest.displayName) 选择自动或手动堆上限。自动模式会按物理内存解析为具体 -Xmx，不会让 JVM 无界。")
                .font(LXFont.body)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                LXChip(title: "自动分配", isSelected: memoryAutomatic) { memoryAutomatic = true }
                LXChip(title: "手动", isSelected: !memoryAutomatic) { memoryAutomatic = false }
                Spacer()
            }
            if memoryAutomatic {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(theme.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动 · \(InstanceMemory.automaticMiB()) MiB")
                            .font(LXFont.bodyStrong)
                            .foregroundStyle(theme.text)
                        Text("基于本机物理内存；后续可随时切换为手动。")
                            .font(LXFont.caption)
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.orangeSoft, in: RoundedRectangle(cornerRadius: LXRadius.md, style: .continuous))
            } else {
                TextField("例如 4096", text: $memoryText)
                    .lxInput()
            }
            HStack {
                Spacer()
                LXButton("取消", kind: .ghost) { memoryTarget = nil }
                LXButton("保存", kind: .primary) {
                    let value = memoryAutomatic ? nil : Int(memoryText.trimmingCharacters(in: .whitespacesAndNewlines))
                    model.setMemory(value, for: instance)
                    memoryTarget = nil
                }
            }
        }
        .padding(LXSpace.xl)
        .frame(width: 440)
        .background(theme.canvas)
        .environment(\.lxTheme, theme)
    }
}

// MARK: - Rows

private struct InstanceRow: View {
    @Environment(\.lxTheme) private var theme
    @State private var hovering = false

    let instance: Instance
    let selected: Bool
    let running: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onMemory: () -> Void
    let onDelete: () -> Void
    let onMods: () -> Void
    let onLaunch: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous)
                        .fill(selected ? theme.orangeSoft : theme.surfaceRaised)
                    Image(systemName: "cube.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(selected ? theme.orange : theme.textSecondary)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(instance.manifest.displayName)
                            .font(LXFont.bodyStrong)
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                        if running {
                            Circle().fill(theme.success).frame(width: 5, height: 5)
                        }
                    }
                    Text("\(instance.manifest.versionID ?? "未绑定版本") · \(instance.id)")
                        .font(LXFont.caption)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(instance.manifest.memoryMiB.map { "\($0)M" } ?? "自动")
                        .font(LXFont.monoSmall)
                        .foregroundStyle(theme.textTertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(theme.textTertiary.opacity(0.7))
                }
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: LXRadius.md, style: .continuous)
                    .fill(selected ? theme.sidebarActive : (hovering ? theme.surfaceHover : theme.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: LXRadius.md, style: .continuous)
                    .strokeBorder(selected ? theme.orange.opacity(0.55) : theme.border, lineWidth: selected ? 1.2 : 0.8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            Button("启动此实例", action: onLaunch)
            Button("模组管理…", action: onMods)
            Button("编辑 JVM 内存…", action: onMemory)
            Divider()
            Button("打开实例文件夹", action: onOpen)
            Button("删除实例…", role: .destructive, action: onDelete)
        }
        .accessibilityLabel("\(instance.manifest.displayName)，版本 \(instance.manifest.versionID ?? "未绑定")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct InstanceDetailPane: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.lxTheme) private var theme

    let instance: Instance
    let onEditMemory: () -> Void
    let onDelete: () -> Void
    let onMods: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LXSpace.md) {
                header
                metadata
                memory
                actions
                dangerZone
            }
            .padding(LXSpace.lg)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .background(
            RoundedRectangle(cornerRadius: LXRadius.lg, style: .continuous)
                .fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LXRadius.lg, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: LXRadius.lg, style: .continuous))
        .frame(maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                LXOverline(text: "INSTANCE DETAIL", color: theme.orange)
                Spacer()
                LXBadge(
                    text: instance.manifest.versionID ?? "未绑定版本",
                    tone: instance.manifest.versionID == nil ? .warning : .neutral
                )
            }
            Text(instance.manifest.displayName)
                .font(LXFont.display(30))
                .foregroundStyle(theme.text)
                .lineLimit(2)
            VStack(alignment: .leading, spacing: 2) {
                Text("游戏目录 · \(instance.gameDirectory.path)")
                    .font(LXFont.monoSmall)
                    .foregroundStyle(theme.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text("实例元数据 · \(instance.directory.path)")
                    .font(LXFont.monoSmall)
                    .foregroundStyle(theme.textTertiary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var metadata: some View {
        LXCard(padding: LXSpace.md) {
            VStack(alignment: .leading, spacing: 10) {
                LXOverline(text: "RUNTIME PROFILE")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: LXSpace.xl) {
                        LXKeyValue(label: "Minecraft", value: compatibility?.gameVersion ?? instance.manifest.versionID ?? "未绑定")
                        LXKeyValue(label: "Loader", value: loaderLabel)
                        LXKeyValue(label: "最近启动", value: lastLaunch)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        LXKeyValue(label: "Minecraft", value: compatibility?.gameVersion ?? instance.manifest.versionID ?? "未绑定")
                        LXKeyValue(label: "Loader", value: loaderLabel)
                        LXKeyValue(label: "最近启动", value: lastLaunch)
                    }
                }
            }
        }
    }

    private var compatibility: ModCompatibility? {
        try? ModCompatibilityResolver.resolve(instance: instance, layout: model.layout)
    }

    private var loaderLabel: String {
        switch compatibility?.loader {
        case .fabric: return "Fabric"
        case .neoforge: return "NeoForge"
        case .vanilla: return "Vanilla"
        case nil: return "未知"
        }
    }

    private var memory: some View {
        LXCard(padding: LXSpace.md) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "memorychip.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.orange)
                    .frame(width: 28, height: 28)
                    .background(theme.orangeSoft, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text("JVM 内存")
                        .font(LXFont.bodyStrong)
                        .foregroundStyle(theme.text)
                    Text(instance.manifest.memoryMiB.map { "\($0) MiB · -Xmx\($0)M（手动）" } ?? "自动 · \(InstanceMemory.automaticMiB()) MiB · -Xmx\(InstanceMemory.automaticMiB())M")
                        .font(LXFont.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                LXButton("修改", kind: .secondary, action: onEditMemory)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            LXButton("启动此实例", systemImage: "play.fill", kind: .primary, isDisabled: model.isGameRunning || model.activeMicrosoftAccount == nil) {
                model.selectedInstanceID = instance.id
                model.launchSelectedInstance()
            }
            LXButton("模组管理", systemImage: "puzzlepiece.extension", kind: .secondary) {
                model.openMods(instance: instance)
            }
            LXButton("图形与光影", systemImage: "sparkles", kind: .secondary) {
                model.openGraphics(instance: instance)
            }
            LXButton("资源包", systemImage: "photo.on.rectangle", kind: .secondary) {
                model.openResourcePacks(instance: instance)
            }
            LXButton("性能工作台", systemImage: "gauge.with.dots.needle.50percent", kind: .secondary) {
                model.openPerformance(instance: instance)
            }
            LXButton("实例管理", systemImage: "wrench.and.screwdriver", kind: .secondary) {
                model.openInstanceTools(instance)
            }
            LXButton("打开文件夹", systemImage: "folder", kind: .secondary) {
                model.openInstanceFolder(instance)
            }
            Spacer()
        }
    }

    private var dangerZone: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("危险操作")
                    .font(LXFont.captionStrong)
                    .foregroundStyle(theme.textSecondary)
                Text("删除实例会同时删除其中的世界和配置。")
                    .font(LXFont.caption)
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer()
            LXButton("删除实例…", systemImage: "trash", kind: .destructive, action: onDelete)
        }
        .padding(.top, LXSpace.sm)
    }

    private var lastLaunch: String {
        guard let date = instance.manifest.lastLaunchedAt else { return "尚未启动" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
