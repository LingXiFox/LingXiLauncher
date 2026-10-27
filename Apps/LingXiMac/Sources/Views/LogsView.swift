import AppKit
import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索日志", text: $model.logSearchText)
                    .textFieldStyle(.plain)
                if !model.logSearchText.isEmpty {
                    Button {
                        model.logSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Divider().frame(height: 16)
                Toggle("自动滚动", isOn: $model.autoScrollLogs)
                    .toggleStyle(.checkbox)
                Button {
                    copyLogs()
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                Button {
                    exportDiagnostics()
                } label: {
                    Label("导出诊断", systemImage: "square.and.arrow.up")
                }
                if let logURL = model.gameLogURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([logURL])
                    } label: {
                        Label("启动器日志", systemImage: "doc.text.magnifyingglass")
                    }
                    .help(logURL.path)
                }
                if let latest = model.latestGameLogURL {
                    Button {
                        NSWorkspace.shared.open(latest)
                    } label: {
                        Label("Minecraft 日志", systemImage: "doc.plaintext")
                    }
                    .help(latest.path)
                }
            }
            .padding(10)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.filteredLogs) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entry.date, format: .dateTime.hour().minute().second())
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 62, alignment: .leading)
                                Text(entry.source)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 58, alignment: .leading)
                                Text(entry.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(entry.level.color)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 1)
                            .id(entry.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: model.logs.count) { _, _ in
                    guard model.autoScrollLogs else { return }
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            Divider()
            HStack {
                Text("\(model.filteredLogs.count) 行")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("日志导出会自动脱敏 access_token / refresh_token / OAuth code / Bearer / XBL3.0")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func copyLogs() {
        let text = model.filteredLogs.map { "[\($0.source)] \(model.redact($0.text))" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "lingxi-diagnostics.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.diagnosticReport().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            model.setError(error)
        }
    }
}
