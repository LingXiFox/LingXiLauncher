import AppKit
import Foundation
import LauncherCore

@MainActor
final class GraphicsStore: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case installed
        case browse
        case setup

        var id: String { rawValue }
        var title: String {
            switch self {
            case .installed: return "已安装光影"
            case .browse: return "浏览 Modrinth"
            case .setup: return "Iris + Sodium"
            }
        }
        var icon: String {
            switch self {
            case .installed: return "sparkles"
            case .browse: return "safari"
            case .setup: return "wand.and.stars"
            }
        }
    }

    let instance: Instance
    let compatibility: ShaderCompatibility?
    let compatibilityError: String?
    let capabilities: GraphicsCapabilities

    @Published var tab: Tab = .installed
    @Published private(set) var environment: GraphicsSetupEnvironment?
    @Published private(set) var installed: [InstalledShaderPack] = []
    @Published private(set) var updates: [ShaderPackUpdate] = []
    @Published private(set) var activationState: ShaderActivationState?
    @Published private(set) var searchResults: [ModrinthProjectHit] = []
    @Published private(set) var totalHits = 0
    @Published private(set) var selectedProject: ModrinthProject?
    @Published private(set) var selectedVersions: [ModrinthVersion] = []
    @Published var selectedVersionID: String?
    @Published var searchText = ""
    @Published var sort: ModrinthSort = .downloads
    @Published var searchOffset = 0
    @Published private(set) var icons: [String: NSImage] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isSearching = false
    @Published private(set) var isLoadingDetail = false
    @Published private(set) var isInstallingGraphics = false
    @Published private(set) var isInstallingShader = false
    @Published private(set) var progressMessage: String?
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var pendingReplacement = false
    @Published var pendingShaderUpdate: ShaderPackUpdate?
    @Published var pendingDelete: InstalledShaderPack?

    private let setupManager: GraphicsSetupManager
    private let shaderManager: ShaderPackManager
    private var searchGeneration = 0

    init(instance: Instance, setupManager: GraphicsSetupManager, shaderManager: ShaderPackManager) {
        self.instance = instance
        self.setupManager = setupManager
        self.shaderManager = shaderManager
        do {
            self.compatibility = try shaderManager.compatibility(for: instance)
            self.compatibilityError = nil
        } catch {
            self.compatibility = nil
            self.compatibilityError = (error as? LauncherError)?.message ?? error.localizedDescription
        }
        self.capabilities = GraphicsCapabilities.current()
    }

    var isFabric: Bool { compatibility?.loader == .fabric }
    var isNeoForge: Bool { compatibility?.loader == .neoforge }
    var loaderName: String { compatibility?.loader.displayName ?? "Mod Loader" }
    var gameVersion: String { compatibility?.gameVersion ?? instance.manifest.versionID ?? "未知" }
    var loaderVersion: String? { compatibility?.loaderVersion }
    var selectedVersion: ModrinthVersion? {
        guard let selectedVersionID else { return selectedVersions.first }
        return selectedVersions.first { $0.id == selectedVersionID }
    }
    var installedForProject: InstalledShaderPack? {
        guard let projectID = selectedProject?.id else { return nil }
        return installed.first { $0.projectID == projectID }
    }

    func load() async {
        guard isFabric || isNeoForge else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            environment = try await setupManager.environment(instanceID: instance.id)
            installed = try shaderManager.installed(instanceID: instance.id)
            activationState = try shaderManager.activationState(instanceID: instance.id)
            updates = try await shaderManager.updates(instanceID: instance.id)
            await loadIcons()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func refreshEnvironment() async {
        do {
            environment = try await setupManager.environment(instanceID: instance.id)
            installed = try shaderManager.installed(instanceID: instance.id)
            updates = try await shaderManager.updates(instanceID: instance.id)
            activationState = try shaderManager.activationState(instanceID: instance.id)
            await loadIcons()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func installGraphics(allowReplace: Bool = false) async {
        guard !isInstallingGraphics else { return }
        isInstallingGraphics = true
        errorMessage = nil
        notice = nil
        defer { isInstallingGraphics = false; progressMessage = nil }
        do {
            let report = try await setupManager.install(instanceID: instance.id, allowReplace: allowReplace) { [weak self] message in
                Task { @MainActor in self?.progressMessage = message.message }
            }
            environment = report.environment
            notice = report.changedProjectIDs.isEmpty
                ? "Iris 与 Sodium 已是最新版本。"
                : "已安装 Iris \(report.installedIris.versionNumber ?? "") 与 Sodium \(report.installedSodium.versionNumber ?? "")。"
            await refreshEnvironment()
        } catch is CancellationError {
            notice = "已取消图形环境安装。"
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func search(reset: Bool = true) async {
        guard isFabric || isNeoForge else { return }
        if reset { searchOffset = 0; selectedProject = nil; searchGeneration += 1 }
        let generation = searchGeneration
        isSearching = true
        errorMessage = nil
        defer { if generation == searchGeneration { isSearching = false } }
        do {
            let result = try await shaderManager.search(
                instanceID: instance.id,
                query: searchText,
                sort: sort,
                offset: searchOffset,
                limit: 24
            )
            guard generation == searchGeneration else { return }
            searchResults = reset ? result.hits : searchResults + result.hits
            totalHits = result.totalHits
            await loadIcons()
        } catch {
            if generation == searchGeneration { errorMessage = Self.describe(error) }
        }
    }

    func nextPage() async {
        guard searchOffset + 24 < totalHits else { return }
        searchOffset += 24
        await search(reset: false)
    }

    func selectProject(_ hit: ModrinthProjectHit) async {
        isLoadingDetail = true
        errorMessage = nil
        selectedProject = nil
        selectedVersions = []
        selectedVersionID = nil
        defer { isLoadingDetail = false }
        do {
            async let project = shaderManager.project(idOrSlug: hit.projectID)
            async let versions = shaderManager.compatibleVersions(instanceID: instance.id, projectID: hit.projectID)
            let loadedProject = try await project
            let loadedVersions = try await versions
            selectedProject = loadedProject
            selectedVersions = loadedVersions.sorted { $0.datePublished > $1.datePublished }
            selectedVersionID = selectedVersions.first?.id
            if let iconURL = loadedProject.iconURL {
                await loadIcon(for: iconURL)
            }
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func closeDetail() {
        selectedProject = nil
        selectedVersions = []
        selectedVersionID = nil
    }

    func installSelectedShader() async {
        guard let project = selectedProject, let version = selectedVersion, !isInstallingShader else { return }
        isInstallingShader = true
        errorMessage = nil
        notice = nil
        defer { isInstallingShader = false; progressMessage = nil }
        do {
            let replacement = installedForProject
            let report = try await shaderManager.install(
                instanceID: instance.id,
                projectIDOrSlug: project.id,
                versionID: version.id,
                replacingFileName: replacement?.fileName
            ) { [weak self] message in
                Task { @MainActor in self?.progressMessage = message.message }
            }
            notice = "已安装 \(report.installed.title) \(report.installed.versionNumber ?? "")."
            installed = try shaderManager.installed(instanceID: instance.id)
            activationState = try shaderManager.activationState(instanceID: instance.id)
            updates = try await shaderManager.updates(instanceID: instance.id)
            await loadIcons()
            closeDetail()
        } catch is CancellationError {
            notice = "已取消光影安装。"
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func importLocal(url: URL) async {
        guard !isInstallingShader else { return }
        isInstallingShader = true
        errorMessage = nil
        notice = nil
        defer { isInstallingShader = false; progressMessage = nil }
        do {
            let report = try shaderManager.importLocal(archiveURL: url, instanceID: instance.id) { [weak self] message in
                Task { @MainActor in self?.progressMessage = message.message }
            }
            notice = "已导入本地光影 \(report.installed.title)。"
            installed = try shaderManager.installed(instanceID: instance.id)
            activationState = try shaderManager.activationState(instanceID: instance.id)
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func update(_ update: ShaderPackUpdate) async {
        guard !isInstallingShader else { return }
        isInstallingShader = true
        errorMessage = nil
        notice = nil
        defer { isInstallingShader = false; progressMessage = nil }
        do {
            let report = try await shaderManager.install(
                instanceID: instance.id,
                projectIDOrSlug: update.projectID,
                versionID: update.latestVersionID,
                replacingFileName: installed.first(where: { $0.projectID == update.projectID })?.fileName
            ) { [weak self] message in
                Task { @MainActor in self?.progressMessage = message.message }
            }
            notice = "已更新 \(report.installed.title) 到 \(report.installed.versionNumber ?? "")."
            installed = try shaderManager.installed(instanceID: instance.id)
            activationState = try shaderManager.activationState(instanceID: instance.id)
            updates = try await shaderManager.updates(instanceID: instance.id)
            await loadIcons()
        } catch is CancellationError {
            notice = "已取消更新。"
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func activate(_ pack: InstalledShaderPack) {
        errorMessage = nil
        notice = nil
        do {
            let result = try shaderManager.activate(
                fileName: pack.fileName,
                instanceID: instance.id
            )
            activationState = try shaderManager.activationState(instanceID: instance.id)
            notice = result.message
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func deactivate() {
        errorMessage = nil
        notice = nil
        do {
            let result = try shaderManager.deactivate(instanceID: instance.id)
            activationState = try shaderManager.activationState(instanceID: instance.id)
            notice = result.message
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func remove(_ pack: InstalledShaderPack) {
        errorMessage = nil
        notice = nil
        do {
            try shaderManager.remove(fileName: pack.fileName, instanceID: instance.id)
            installed = try shaderManager.installed(instanceID: instance.id)
            activationState = try shaderManager.activationState(instanceID: instance.id)
            notice = "已删除 \(pack.title)。"
            Task { await loadIcons() }
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func openFolder() {
        do {
            let url = try shaderManager.openDirectoryURL(instanceID: instance.id)
            NSWorkspace.shared.open(url)
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func loadIcons() async {
        for pack in installed where pack.iconURL != nil {
            if let iconURL = pack.iconURL { await loadIcon(for: iconURL) }
        }
        for hit in searchResults where hit.iconURL != nil {
            if let iconURL = hit.iconURL { await loadIcon(for: iconURL) }
        }
    }

    private func loadIcon(for urlString: String) async {
        guard icons[urlString] == nil else { return }
        guard let data = try? await shaderManager.fetchIcon(from: urlString), let image = NSImage(data: data) else { return }
        icons[urlString] = image
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? LauncherError { return error.description }
        return error.localizedDescription
    }

    // MARK: - Debug state (read-only; actions use the same methods as visible controls)

    func debugState() -> [String: Any] {
        var state: [String: Any] = [
            "instanceID": instance.id,
            "gameVersion": gameVersion,
            "tab": tab.rawValue,
            "fabric": isFabric,
            "neoforge": isNeoForge,
            "loader": compatibility?.loader.displayName ?? "unknown",
            "busy": isInstallingGraphics || isInstallingShader || isSearching || isLoadingDetail,
            "searching": isSearching,
            "installingGraphics": isInstallingGraphics,
            "installingShader": isInstallingShader,
            "totalHits": totalHits,
            "notice": notice ?? "",
            "error": errorMessage ?? "",
            "progress": progressMessage ?? "",
            "installed": installed.map {
                [
                    "file": $0.fileName,
                    "title": $0.title,
                    "projectID": $0.projectID ?? "",
                    "versionID": $0.versionID ?? "",
                    "version": $0.versionNumber ?? "",
                    "source": $0.source.rawValue,
                ]
            },
            "updates": updates.map {
                [
                    "projectID": $0.projectID,
                    "title": $0.title,
                    "current": $0.currentVersionNumber ?? "",
                    "latest": $0.latestVersionNumber,
                ]
            },
            "activation": activationState.map {
                [
                    "kind": $0.kind.rawValue,
                    "shaderPack": $0.shaderPack ?? "",
                    "message": $0.message,
                ]
            } ?? [:],
            "environment": environment.map {
                [
                    "iris": $0.iris?.versionNumber ?? "",
                    "sodium": $0.sodium?.versionNumber ?? "",
                    "recommendedIris": $0.recommendedIris?.versionNumber ?? "",
                    "recommendedSodium": $0.recommendedSodium?.versionNumber ?? "",
                    "warnings": $0.warnings,
                ]
            } ?? [:],
            "search": searchResults.prefix(20).map {
                [
                    "projectID": $0.projectID,
                    "slug": $0.slug ?? "",
                    "title": $0.title,
                    "downloads": $0.downloads,
                ]
            },
            "project": selectedProject.map {
                [
                    "id": $0.id,
                    "slug": $0.slug ?? "",
                    "title": $0.title,
                    "body": $0.body ?? "",
                ]
            } ?? [:],
            "versions": selectedVersions.prefix(20).map {
                [
                    "id": $0.id,
                    "version": $0.versionNumber,
                    "gameVersions": $0.gameVersions,
                ]
            },
            "selectedVersionID": selectedVersionID ?? "",
            "capabilities": [
                "appleSilicon": capabilities.isAppleSilicon,
                "openGL": capabilities.openGLVersion ?? "",
                "renderer": capabilities.renderer ?? "",
                "summary": capabilities.summary,
                "warning": capabilities.shaderCompatibilityWarning ?? capabilities.probeError ?? "",
            ],
        ]
        if let compatibility {
            state["loaderVersion"] = compatibility.loaderVersion ?? ""
        }
        return state
    }
}
