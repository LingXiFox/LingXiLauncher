import LauncherCore
import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedVersionID: String?

    private struct VersionRow: Identifiable {
        let id: String
        let entry: VersionManifest.Entry
    }

    private var versionRows: [VersionRow] {
        model.versionEntries.map { VersionRow(id: $0.id, entry: $0) }
    }

    private func versionRow(_ row: VersionRow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.entry.id)
                    .font(.body.weight(.medium))
                Text(row.entry.releaseTime ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(row.entry.type.rawValue)
                .font(.caption2)
                .foregroundStyle(row.entry.type == .release ? Color.secondary : Color.orange)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selectedVersionID == row.id ? Color.accentColor.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Picker("类型", selection: $model.versionFilter) {
                        ForEach(AppModel.VersionFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .onChange(of: model.versionFilter) { _, _ in
                        Task { await model.loadVersions() }
                    }

                    Picker("源", selection: $model.settings.source) {
                        ForEach(DownloadSourcePolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .onChange(of: model.settings.sourceRaw) { _, _ in
                        model.saveSettings()
                        Task { await model.loadVersions() }
                    }

                    Spacer()

                    if model.isLoadingVersions {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        Task { await model.loadVersions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("刷新版本列表")
                }
                .padding(10)
                Divider()

                if model.versionEntries.isEmpty {
                    EmptyStateView(
                        icon: "arrow.down.circle",
                        title: model.isLoadingVersions ? "正在获取版本列表…" : "没有版本",
                        message: "选择类型和下载源后刷新；官方清单会缓存到 dataRoot/cache。"
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(versionRows) { row in
                                Button {
                                    selectedVersionID = row.id
                                } label: {
                                    versionRow(row)
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 420, idealWidth: 480)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SectionCard(title: "安装目标") {
                        if let instance = model.selectedInstance {
                            LabeledValue(title: "现有实例", value: instance.manifest.displayName)
                            Text("安装会更新该实例的版本指向，不会删除世界。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("未选择实例；安装时将创建全新实例（id: vanilla-<version>）。")
                                .foregroundStyle(.secondary)
                        }
                    }

                    SectionCard(title: "下载") {
                        if let versionID = selectedVersionID {
                            LabeledValue(title: "Minecraft 版本", value: versionID)
                        } else {
                            Text("从左侧选择一个版本。").foregroundStyle(.secondary)
                        }
                        HStack {
                            Button {
                                if let versionID = selectedVersionID {
                                    model.installVersion(versionID)
                                }
                            } label: {
                                Label("安装", systemImage: "arrow.down.circle")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedVersionID == nil || model.installState.isRunning)

                            if model.installState.isRunning {
                                Button("取消下载") { model.cancelInstall() }
                            }
                            Spacer()
                        }
                        .padding(.top, 4)
                    }

                    SectionCard(title: "进度") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(model.installState.phase)
                                    .font(.callout.weight(.medium))
                                Spacer()
                                if model.installState.total > 0 {
                                    Text("\(model.installState.completed)/\(model.installState.total)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            ProgressView(value: model.installState.fraction)
                            HStack {
                                Text("\(Downloader.format(bytes: model.installState.bytes)) / \(Downloader.format(bytes: model.installState.totalBytes))")
                                Spacer()
                                if model.installState.bytesPerSecond > 0 {
                                    Text("\(Downloader.format(bytes: Int(model.installState.bytesPerSecond)))/s")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if let file = model.installState.currentFile {
                                Text(file)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            if let error = model.installState.error {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                            if let verify = model.installState.verifyMessage {
                                Label(
                                    verify,
                                    systemImage: verify.contains("通过") ? "checkmark.seal" : "exclamationmark.triangle"
                                )
                                .font(.caption)
                                .foregroundStyle(verify.contains("通过") ? .green : .orange)
                            }
                        }
                    }

                    SectionCard(title: "下载源") {
                        Text(model.settings.source.displayName)
                        Text("镜像需要在设置中提供显式 HTTPS host 映射；官方源不会做任何 URL 重写。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(22)
            }
            .frame(minWidth: 300)
        }
        .task {
            if model.versionEntries.isEmpty {
                await model.loadVersions()
            }
        }
    }
}
