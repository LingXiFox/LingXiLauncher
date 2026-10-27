import LauncherCore
import SwiftUI

struct InstancesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showCreate = false
    @State private var newName = ""
    @State private var newVersion = ""
    @State private var pendingDelete: Instance?
    @State private var memoryTarget: Instance?
    @State private var memoryText = ""

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(
                    model.instances,
                    selection: Binding(
                        get: { model.selectedInstanceID },
                        set: { model.selectedInstanceID = $0 }
                    )
                ) { instance in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(instance.manifest.displayName)
                            .font(.body.weight(.medium))
                        Text("\(instance.manifest.versionID ?? "未指定版本") · \(instance.id)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(instance.id)
                }
                .overlay {
                    if model.instances.isEmpty {
                        EmptyStateView(
                            icon: "square.stack.3d.up",
                            title: "没有游戏实例",
                            message: "创建实例后即可配置内存、打开目录或启动游戏。"
                        )
                    }
                }
                Divider()
                HStack {
                    Button {
                        showCreate = true
                    } label: {
                        Label("新建实例", systemImage: "plus")
                    }
                    Spacer()
                    Button {
                        model.reloadInstances()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("刷新")
                }
                .padding(10)
            }
            .frame(minWidth: 280, maxWidth: 340)

            Divider()

            Group {
                if let instance = model.selectedInstance {
                    InstanceDetailView(
                        instance: instance,
                        onDelete: { pendingDelete = instance },
                        onEditMemory: {
                            memoryTarget = instance
                            memoryText = instance.manifest.memoryMiB.map(String.init) ?? ""
                        }
                    )
                } else {
                    EmptyStateView(
                        icon: "sidebar.left",
                        title: "选择一个实例",
                        message: "左侧列表显示所有本地实例；所有数据来自 LauncherCore 的 InstanceRepository。"
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showCreate) {
            createSheet
        }
        .sheet(item: $memoryTarget) { instance in
            memorySheet(instance)
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
            Text("这会删除实例目录及其中的世界、配置和日志：\n\(instance.directory.path)\n此操作不可撤销。")
        }
    }

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建游戏实例").font(.title3.weight(.semibold))
            TextField("显示名称", text: $newName)
            Picker("Minecraft 版本", selection: $newVersion) {
                Text("稍后选择").tag("")
                ForEach(model.installedVersionIDs, id: \.self) { version in
                    Text(version).tag(version)
                }
            }
            if model.installedVersionIDs.isEmpty {
                Text("尚无可用的本地版本。请先在“版本下载”中安装一个版本。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消") { showCreate = false }
                Button("创建") {
                    model.createInstance(name: newName, versionID: newVersion.isEmpty ? nil : newVersion)
                    showCreate = false
                    newName = ""
                    newVersion = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private func memorySheet(_ instance: Instance) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("JVM 内存上限").font(.title3.weight(.semibold))
            Text("为实例 \(instance.manifest.displayName) 设置 -Xmx 值（256–65536 MiB）。留空表示不添加启动器参数。")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("例如 4096", text: $memoryText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { memoryTarget = nil }
                Button("保存") {
                    let value = Int(memoryText.trimmingCharacters(in: .whitespaces))
                    model.setMemory(value, for: instance)
                    memoryTarget = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

private struct InstanceDetailView: View {
    @EnvironmentObject private var model: AppModel
    let instance: Instance
    let onDelete: () -> Void
    let onEditMemory: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(instance.manifest.displayName)
                            .font(.title2.weight(.semibold))
                        Text(instance.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusPill(
                        text: instance.manifest.versionID ?? "未指定版本",
                        color: instance.manifest.versionID == nil ? .orange : .secondary
                    )
                }

                SectionCard(title: "路径") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledValue(title: "实例目录", value: instance.directory.path)
                        LabeledValue(title: "游戏目录", value: instance.gameDirectory.path)
                    }
                    HStack {
                        Button("打开实例文件夹") { model.openInstanceFolder(instance) }
                        Spacer()
                    }
                    .padding(.top, 6)
                }

                SectionCard(title: "JVM 内存") {
                    HStack {
                        Text(instance.manifest.memoryMiB.map { "\($0) MiB（-Xmx\($0)M）" } ?? "未设置")
                        Spacer()
                        Button("修改") { onEditMemory() }
                    }
                }

                SectionCard(title: "最近启动") {
                    if let date = instance.manifest.lastLaunchedAt {
                        Text(date.formatted(date: .abbreviated, time: .standard))
                        Text(instance.manifest.lastIdentityMode?.rawValue ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("尚未启动").foregroundStyle(.secondary)
                    }
                }

                HStack {
                    if model.selectedInstanceID == instance.id {
                        Button {
                            model.launchSelectedInstance()
                        } label: {
                            Label("启动此实例", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isGameRunning || model.activeMicrosoftAccount == nil)
                    }
                    Spacer()
                    Button("删除实例…", role: .destructive) { onDelete() }
                }
            }
            .padding(22)
        }
    }
}
