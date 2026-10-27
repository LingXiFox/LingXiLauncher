import AppKit
import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.lxTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var levelFilter: LogLevelFilter = .all

    enum LogLevelFilter: String, CaseIterable, Identifiable {
        case all, info, warning, error, game

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部"
            case .info: return "Info"
            case .warning: return "Warn"
            case .error: return "Error"
            case .game: return "Game"
            }
        }
    }

    private var visibleLogs: [AppModel.LogEntry] {
        var entries = model.logs
        if let level = levelFilter.modelLevel {
            entries = entries.filter { $0.level == level }
        }
        guard !model.logSearchText.isEmpty else { return entries }
        return entries.filter {
            $0.text.localizedCaseInsensitiveContains(model.logSearchText)
                || $0.source.localizedCaseInsensitiveContains(model.logSearchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LXSpace.md) {
            LXPageHeader(
                eyebrow: "SYSTEM / CONSOLE",
                title: "运行日志",
                subtitle: "LauncherCore、Java stdout/stderr 与游戏事件；导出前自动脱敏。"
            ) {
                HStack(spacing: 7) {
                    LXButton("复制", systemImage: "doc.on.doc", kind: .secondary, action: copyLogs)
                    LXButton("导出诊断", systemImage: "square.and.arrow.up", kind: .primary, action: exportDiagnostics)
                }
                .padding(.top, 3)
            }

            terminal
        }
        .padding(.horizontal, LXSpace.xxl)
        .padding(.vertical, LXSpace.xl)
        .frame(maxWidth: 1240, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.canvas)
    }

    private var terminal: some View {
        VStack(spacing: 0) {
            chrome
            LXDivider().overlay(theme.terminalBorder)
            logViewport
            LXDivider().overlay(theme.terminalBorder)
            footer
        }
        .background(theme.terminalBackground)
        .clipShape(RoundedRectangle(cornerRadius: LXRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LXRadius.lg, style: .continuous)
                .strokeBorder(theme.terminalBorder, lineWidth: 1)
        )
        .shadow(color: theme.shadow, radius: 14, x: 0, y: 6)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("运行日志控制台")
    }

    private var chrome: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: 0xE57672)).frame(width: 8, height: 8)
                Circle().fill(Color(hex: 0xE7B86C)).frame(width: 8, height: 8)
                Circle().fill(Color(hex: 0x7DCB9D)).frame(width: 8, height: 8)
                Text("launch console")
                    .font(LXFont.monoSmall)
                    .foregroundStyle(theme.terminalDim)
                    .padding(.leading, 4)
                Spacer()
                Toggle("自动滚动", isOn: $model.autoScrollLogs)
                    .toggleStyle(.checkbox)
                    .font(LXFont.caption)
                    .foregroundStyle(theme.terminalDim)
                    .tint(theme.orange)
                if let logURL = model.gameLogURL {
                    LXIconButton(systemImage: "doc.text.magnifyingglass", label: "打开启动器日志") {
                        NSWorkspace.shared.activateFileViewerSelecting([logURL])
                    }
                }
                if let latest = model.latestGameLogURL {
                    LXIconButton(systemImage: "doc.plaintext", label: "打开 Minecraft latest.log") {
                        NSWorkspace.shared.open(latest)
                    }
                }
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .medium))
                    TextField(
                        "",
                        text: $model.logSearchText,
                        prompt: Text("搜索日志").foregroundColor(theme.terminalDim)
                    )
                    .textFieldStyle(.plain)
                    .font(LXFont.monoSmall)
                    .foregroundStyle(theme.terminalText)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(hex: 0x171C23), in: RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous)
                        .strokeBorder(theme.terminalBorder, lineWidth: 0.8)
                )
                .frame(maxWidth: 280)

                ForEach(LogLevelFilter.allCases) { filter in
                    LXChip(title: filter.title, isSelected: levelFilter == filter) {
                        levelFilter = filter
                    }
                }
                Spacer()
                Text("\(visibleLogs.count) 行")
                    .font(LXFont.monoSmall)
                    .foregroundStyle(theme.terminalDim)
            }
        }
        .padding(.horizontal, LXSpace.md)
        .padding(.vertical, 10)
        .background(theme.terminalChrome)
    }

    private var logViewport: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if visibleLogs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("$ waiting for launcher events…")
                                .font(LXFont.mono)
                                .foregroundStyle(theme.terminalDim)
                            Text("启动游戏或安装版本后，这里会实时出现 Core、stdout/stderr 与游戏日志。")
                                .font(LXFont.caption)
                                .foregroundStyle(theme.terminalDim.opacity(0.7))
                        }
                        .padding(LXSpace.lg)
                    } else {
                        ForEach(Array(visibleLogs.enumerated()), id: \.element.id) { index, entry in
                            LogRow(index: index, entry: entry)
                                .id(entry.id)
                        }
                    }
                    Color.clear.frame(height: 1).id("console-bottom")
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
            .onChange(of: model.logs.count) { _, _ in
                guard model.autoScrollLogs else { return }
                if reduceMotion {
                    proxy.scrollTo("console-bottom", anchor: .bottom)
                } else {
                    withAnimation(.linear(duration: 0.12)) {
                        proxy.scrollTo("console-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isGameRunning ? theme.success : theme.terminalDim)
                .frame(width: 5, height: 5)
            Text(model.isGameRunning ? "process attached · \(model.gamePID.map { "PID \($0)" } ?? "starting")" : "idle")
                .font(LXFont.monoSmall)
                .foregroundStyle(theme.terminalDim)
            Spacer()
            Text("导出会自动脱敏 access_token / refresh_token / OAuth code / Bearer / XBL3.0")
                .font(LXFont.caption)
                .foregroundStyle(theme.terminalDim.opacity(0.8))
                .lineLimit(1)
        }
        .padding(.horizontal, LXSpace.md)
        .padding(.vertical, 7)
        .background(theme.terminalChrome)
    }

    private func copyLogs() {
        let text = visibleLogs.map { "[\($0.source)] \(model.redact($0.text))" }.joined(separator: "\n")
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

private struct LogRow: View {
    @Environment(\.lxTheme) private var theme
    let index: Int
    let entry: AppModel.LogEntry

    private var color: Color {
        switch entry.level {
        case .info: return theme.terminalText
        case .warning: return theme.warning
        case .error: return theme.danger
        case .game: return Color(hex: 0x9FB0C3)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(String(format: "%04d", index + 1))
                .font(LXFont.monoSmall)
                .foregroundStyle(theme.terminalDim.opacity(0.55))
                .frame(width: 30, alignment: .trailing)
            Text(entry.date, format: .dateTime.hour().minute().second())
                .font(LXFont.monoSmall)
                .foregroundStyle(theme.terminalDim)
                .frame(width: 54, alignment: .leading)
            Text(entry.source.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(sourceColor)
                .frame(width: 58, alignment: .leading)
                .lineLimit(1)
            Circle()
                .fill(color)
                .frame(width: 4, height: 4)
                .padding(.top, 5)
            Text(entry.text)
                .font(LXFont.mono)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, LXSpace.md)
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.source)，\(entry.level.rawValue)，\(entry.text)")
    }

    private var sourceColor: Color {
        switch entry.source {
        case "auth": return theme.orange
        case "launch", "launcher": return theme.info
        case "install", "downloads": return theme.success
        case "java": return Color(hex: 0x9FB0C3)
        default: return theme.terminalDim
        }
    }
}

extension LogsView.LogLevelFilter {
    var modelLevel: AppModel.LogEntry.Level? {
        switch self {
        case .all: return nil
        case .info: return .info
        case .warning: return .warning
        case .error: return .error
        case .game: return .game
        }
    }
}
