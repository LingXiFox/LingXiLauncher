import AppKit
import Foundation
import LauncherCore
import SwiftUI

@MainActor
final class ModsStore: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case installed, browse
        var id: String { rawValue }
        var title: String { self == .installed ? "已安装" : "浏览模组" }
    }

    let instance: Instance
    private let model: AppModel

    @Published var tab: Tab = .installed
    @Published var installed: [InstalledMod] = []
    @Published var compatibility: ModCompatibility?
    @Published var compatibilityError: String?
    @Published var errorMessage: String?
    @Published var errorSuggestion: String?

    // Browse
    @Published var query = ""
    @Published var selectedCategory: String?
    @Published var sort: ModrinthSort = .relevance
    @Published var results: [ModrinthProjectHit] = []
    @Published var totalResults = 0
    @Published var categories: [ModrinthCategory] = []
    @Published var isSearching = false
    @Published var hasMore = false
    @Published var selectedHit: ModrinthProjectHit?
    @Published var project: ModrinthProject?
    @Published var versions: [ModrinthVersion] = []
    @Published var selectedVersionID: String?
    @Published var isLoadingDetail = false
    @Published var iconCache: [String: NSImage] = [:]

    // Updates / install
    @Published var updates: [ModUpdate] = []
    @Published var isCheckingUpdates = false
    @Published var isInstalling = false
    @Published var installProgress: ModInstallProgress?
    @Published var installTask: Task<Void, Never>?
    @Published var pendingDelete: InstalledMod?
    @Published var pendingUpdate: ModUpdate?
    @Published var lastReport: ModInstallReport?

    init(instance: Instance, model: AppModel) {
        self.instance = instance
        self.model = model
    }

    var selectedVersion: ModrinthVersion? {
        versions.first { $0.id == selectedVersionID } ?? versions.first
    }

    var installedProjectIDs: Set<String> {
        Set(installed.compactMap(\.projectID))
    }

    func updateFor(_ mod: InstalledMod) -> ModUpdate? {
        guard let projectID = mod.projectID else { return nil }
        return updates.first { $0.projectID == projectID }
    }

    func selectTab(_ tab: Tab) async {
        self.tab = tab
        if tab == .browse, results.isEmpty { await search() }
    }

    func load() async {
        do {
            let manager = model.makeModManager()
            compatibility = try manager.compatibility(for: instance)
            compatibilityError = nil
            installed = try manager.installed(instanceID: instance.id)
            for mod in installed { loadIcon(mod.iconURL) }
            categories = (try? await manager.categories()) ?? []
        } catch {
            compatibilityError = Self.describe(error)
        }
    }

    func search(reset: Bool = true) async {
        guard compatibility != nil else { return }
        if reset {
            results = []
            totalResults = 0
        }
        isSearching = true
        defer { isSearching = false }
        do {
            let manager = model.makeModManager()
            let result = try await manager.search(
                instanceID: instance.id,
                query: query,
                categories: selectedCategory.map { [$0] } ?? [],
                sort: sort,
                offset: reset ? 0 : results.count,
                limit: 20
            )
            if reset {
                results = result.hits
            } else {
                results.append(contentsOf: result.hits.filter { hit in !results.contains(where: { $0.projectID == hit.projectID }) })
            }
            totalResults = result.totalHits
            hasMore = results.count < result.totalHits
            clearError()
            for hit in result.hits { loadIcon(hit.iconURL) }
        } catch {
            setError(error)
        }
    }

    func select(_ hit: ModrinthProjectHit) async {
        await loadProject(id: hit.projectID, hit: hit)
    }

    func select(projectID: String) async {
        if let hit = results.first(where: { $0.projectID == projectID }) {
            await select(hit)
        } else {
            await loadProject(id: projectID, hit: nil)
        }
    }

    private func loadProject(id: String, hit: ModrinthProjectHit?) async {
        selectedHit = hit
        project = nil
        versions = []
        selectedVersionID = nil
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        do {
            let manager = model.makeModManager()
            let project = try await manager.project(idOrSlug: id)
            self.project = project
            versions = try await manager.compatibleVersions(instanceID: instance.id, projectID: project.id)
            selectedVersionID = versions.first?.id
            loadIcon(project.iconURL ?? hit?.iconURL)
        } catch {
            setError(error)
        }
    }

    func install(versionID: String? = nil, allowReplace: Bool = false) {
        guard let project, !isInstalling else { return }
        isInstalling = true
        lastReport = nil
        installProgress = ModInstallProgress(phase: .resolving, message: "准备安装", completed: 0, total: 1)
        let request = ModInstallRequest(
            instanceID: instance.id,
            projectIDOrSlug: project.id,
            versionID: versionID ?? selectedVersionID,
            allowReplace: allowReplace
        )
        installTask = Task {
            do {
                let manager = model.makeModManager()
                let report = try await manager.install(request) { event in
                    Task { @MainActor in self.installProgress = event }
                }
                lastReport = report
                installed = try manager.installed(instanceID: instance.id)
                for mod in installed { loadIcon(mod.iconURL) }
                updates = (try? await manager.updates(instanceID: instance.id)) ?? []
                clearError()
            } catch is CancellationError {
                setError(LauncherError(.usageError, "安装已取消；已有模组文件未改变"))
            } catch {
                setError(error)
            }
            isInstalling = false
            installProgress = nil
        }
    }

    func cancelInstall() {
        installTask?.cancel()
        installTask = nil
    }

    func checkUpdates() async {
        guard compatibility != nil, !isCheckingUpdates else { return }
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }
        do {
            updates = try await model.makeModManager().updates(instanceID: instance.id)
            clearError()
        } catch {
            setError(error)
        }
    }

    func toggle(_ mod: InstalledMod) {
        do {
            _ = try model.makeModManager().setEnabled(!mod.enabled, fileName: mod.fileName, instanceID: instance.id)
            installed = try model.makeModManager().installed(instanceID: instance.id)
            for mod in installed { loadIcon(mod.iconURL) }
            clearError()
        } catch {
            setError(error)
        }
    }

    func delete(_ mod: InstalledMod) {
        do {
            try model.makeModManager().remove(fileName: mod.fileName, instanceID: instance.id)
            installed = try model.makeModManager().installed(instanceID: instance.id)
            updates.removeAll { $0.projectID == mod.projectID }
            clearError()
        } catch {
            setError(error)
        }
    }

    func update(_ update: ModUpdate) async {
        if project?.id != update.projectID {
            do {
                let manager = model.makeModManager()
                let project = try await manager.project(idOrSlug: update.projectID)
                self.project = project
                versions = try await manager.compatibleVersions(instanceID: instance.id, projectID: project.id)
                selectedVersionID = update.latestVersionID
                tab = .browse
            } catch {
                setError(error)
                return
            }
        }
        install(versionID: update.latestVersionID, allowReplace: true)
        await waitForInstall()
    }

    private func waitForInstall() async {
        while isInstalling {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func loadIcon(_ urlString: String?) {
        guard let urlString, iconCache[urlString] == nil else { return }
        Task {
            do {
                if let data = try await model.makeModManager().fetchIcon(from: urlString),
                   let image = NSImage(data: data) {
                    iconCache[urlString] = image
                }
            } catch {
                // Icon failures are non-fatal; the textual card remains usable.
            }
        }
    }

    func debugState() -> [String: Any] {
        [
            "tab": tab.rawValue,
            "installed": installed.map { ["file": $0.fileName, "project": $0.projectID ?? "", "title": $0.title, "enabled": $0.enabled, "version": $0.versionNumber ?? ""] },
            "results": results.map { ["project_id": $0.projectID, "title": $0.title] },
            "total": totalResults,
            "selectedProject": project?.id ?? "",
            "selectedVersion": selectedVersionID ?? "",
            "versions": versions.map { ["id": $0.id, "number": $0.versionNumber] },
            "installing": isInstalling,
            "updates": updates.map { ["project_id": $0.projectID, "from": $0.currentVersionNumber ?? "", "to": $0.latestVersionNumber] },
            "error": errorMessage ?? "",
        ]
    }

    func clearError() {
        errorMessage = nil
        errorSuggestion = nil
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

    private static func describe(_ error: Error) -> String {
        if let launcher = error as? LauncherError {
            return launcher.suggestion.map { "\(launcher.message) — \($0)" } ?? launcher.message
        }
        return error.localizedDescription
    }
}
