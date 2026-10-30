import SwiftUI
import UniformTypeIdentifiers
import LauncherCore

struct ResourcePacksView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lxTheme) private var theme
    let instance: Instance
    let manager: ResourcePackManager
    @State private var installed: [ResourcePackRecord] = []
    @State private var hits: [ModrinthProjectHit] = []
    @State private var query = ""
    @State private var tab = 0
    @State private var loading = false
    @State private var busyFile: String?
    @State private var errorMessage: String?
    @State private var showImporter = false
    @State private var enabledSupported = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.border)
            if let errorMessage {
                Text(errorMessage)
                    .font(LXFont.caption)
                    .foregroundStyle(theme.danger)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.danger.opacity(0.08))
            }
            Picker("", selection: $tab) {
                Text("已安装 \(installed.count)").tag(0)
                Text("浏览 Modrinth").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(14)
            if tab == 0 { installedPane } else { browsePane }
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(theme.canvas)
        .task { await reload() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip]) { result in
            guard case let .success(url) = result else { return }
            do {
                _ = try manager.importLocal(instanceID: instance.id, archiveURL: url)
                Task { await reload() }
            } catch { errorMessage = errorText(error) }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("资源包").font(LXFont.title())
                Text("\(instance.manifest.displayName) · \(instance.gameDirectory.path)")
                    .font(LXFont.caption).foregroundStyle(theme.textSecondary).lineLimit(1)
            }
            Spacer()
            LXButton("导入 ZIP", systemImage: "square.and.arrow.down", kind: .secondary) { showImporter = true }
            LXIconButton(systemImage: "xmark", label: "关闭") { dismiss() }
        }
        .padding(18)
    }

    private var installedPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if installed.isEmpty {
                    LXCard {
                        VStack(spacing: 8) {
                            Image(systemName: "shippingbox").font(.system(size: 28)).foregroundStyle(theme.textTertiary)
                            Text("还没有资源包").font(LXFont.bodyStrong)
                            Text("从 Modrinth 下载，或导入本地 ZIP。资源包不会写入 mods/。")
                                .font(LXFont.caption).foregroundStyle(theme.textSecondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 26)
                    }
                } else {
                    ForEach(installed) { record in
                        LXCard(padding: 14) {
                            HStack(spacing: 12) {
                                Image(systemName: "photo.stack").font(.system(size: 18)).foregroundStyle(theme.orange)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.title).font(LXFont.bodyStrong)
                                    Text([record.versionNumber, record.source == "modrinth" ? "Modrinth" : "本地"]
                                        .compactMap { $0 }.joined(separator: " · "))
                                        .font(LXFont.caption).foregroundStyle(theme.textSecondary)
                                    Text(record.fileName).font(LXFont.monoSmall).foregroundStyle(theme.textTertiary)
                                }
                                Spacer()
                                if enabledSupported {
                                    Toggle("启用", isOn: Binding(
                                        get: { record.enabled },
                                        set: { value in Task { await setEnabled(record, value) } }
                                    )).toggleStyle(.switch).labelsHidden()
                                } else {
                                    LXBadge(text: "游戏内启用", tone: .neutral)
                                }
                                Button(role: .destructive) {
                                    Task { await remove(record) }
                                } label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain).foregroundStyle(theme.danger)
                            }
                        }
                    }
                }
                Text(enabledSupported
                     ? "启用状态写入 options.txt；修改前会备份并验证。游戏运行时禁止修改。"
                     : "当前 Minecraft 版本没有已验证的启动器侧资源包格式，请在游戏内 Options → Resource Packs 启用。")
                    .font(LXFont.caption).foregroundStyle(theme.textSecondary)
            }.padding(16)
        }
    }

    private var browsePane: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("搜索 Modrinth 资源包", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                LXButton("搜索", systemImage: "magnifyingglass", kind: .primary, isDisabled: loading) {
                    Task { await search() }
                }
            }.padding(.horizontal, 16)
            if loading { ProgressView().padding() }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(hits) { hit in
                        LXCard(padding: 14) {
                            HStack(spacing: 12) {
                                AsyncImage(url: hit.iconURL.flatMap(URL.init(string:))) { image in
                                    image.resizable().scaledToFit()
                                } placeholder: {
                                    Image(systemName: "photo.stack").foregroundStyle(theme.textTertiary)
                                }.frame(width: 42, height: 42).clipShape(RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(hit.title).font(LXFont.bodyStrong)
                                    Text(hit.description).font(LXFont.caption).foregroundStyle(theme.textSecondary).lineLimit(2)
                                    Text("\(hit.author ?? "未知作者") · \(hit.downloads) 次下载")
                                        .font(LXFont.caption).foregroundStyle(theme.textTertiary)
                                }
                                Spacer()
                                LXButton("安装", systemImage: "arrow.down.circle", kind: .primary) {
                                    Task { await install(hit) }
                                }
                            }
                        }
                    }
                }.padding(16)
            }
        }
    }

    private func reload() async {
        do {
            installed = try manager.list(instanceID: instance.id)
            enabledSupported = try manager.canEnableLauncherSide(instanceID: instance.id)
        } catch { errorMessage = errorText(error) }
    }

    private func gameVersion() throws -> String {
        guard let versionID = instance.manifest.versionID else { return "" }
        let resolved = try VersionResolver().resolve(versionID: versionID, from: manager.layout.gameRoot)
        return resolved.inheritsFrom ?? resolved.id
    }

    private func search() async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        loading = true; errorMessage = nil
        do { hits = try await manager.search(query: query, gameVersion: try gameVersion()).hits }
        catch { self.errorMessage = errorText(error) }
        loading = false
    }

    private func install(_ hit: ModrinthProjectHit) async {
        loading = true; errorMessage = nil
        do {
            let versions = try await manager.compatibleVersions(instanceID: instance.id, projectID: hit.projectID)
            guard let version = versions.first else { throw LauncherError(.missingDependency, "没有兼容的资源包版本") }
            busyFile = hit.title
            _ = try await manager.install(instanceID: instance.id, projectID: hit.projectID, versionID: version.id)
            await reload()
            tab = 0
        } catch { self.errorMessage = errorText(error) }
        busyFile = nil; loading = false
    }

    private func setEnabled(_ record: ResourcePackRecord, _ value: Bool) async {
        do { try manager.setEnabled(instanceID: instance.id, fileName: record.fileName, enabled: value); await reload() }
        catch { self.errorMessage = errorText(error) }
    }

    private func remove(_ record: ResourcePackRecord) async {
        do { try manager.delete(instanceID: instance.id, fileName: record.fileName); await reload() }
        catch { self.errorMessage = errorText(error) }
    }

    private func errorText(_ error: Error) -> String {
        (error as? LauncherError)?.message ?? error.localizedDescription
    }
}
