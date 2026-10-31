import AppKit
import Foundation
import LauncherCore
import MacPlatform
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable, Hashable {
        case home, instances, downloads, accounts, logs, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home: return "首页"
            case .instances: return "游戏实例"
            case .downloads: return "版本下载"
            case .accounts: return "账户管理"
            case .logs: return "运行日志"
            case .settings: return "设置"
            }
        }
        var icon: String {
            switch self {
            case .home: return "house"
            case .instances: return "square.stack.3d.up"
            case .downloads: return "arrow.down.circle"
            case .accounts: return "person.crop.circle"
            case .logs: return "text.alignleft"
            case .settings: return "gearshape"
            }
        }
    }

    enum VersionFilter: String, CaseIterable, Identifiable, Hashable {
        case release, snapshot, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .release: return "Release"
            case .snapshot: return "Snapshot"
            case .all: return "全部"
            }
        }
        var kind: VersionManifest.Entry.Kind? {
            switch self {
            case .release: return .release
            case .snapshot: return .snapshot
            case .all: return nil
            }
        }
    }

    struct LogEntry: Identifiable {
        enum Level: String {
            case info, warning, error, game
            var color: Color {
                switch self {
                case .info: return .primary
                case .warning: return .orange
                case .error: return .red
                case .game: return .secondary
                }
            }
        }
        let id = UUID()
        let date: Date
        let level: Level
        let source: String
        let text: String
    }

    struct AccountRow: Identifiable {
        enum Kind: Equatable { case microsoft, local }
        let id: String
        let kind: Kind
        let name: String
        let uuid: String
        let ownsGame: Bool?
        let lastValidated: Date?
        let active: Bool
        let appearance: PlayerAppearance?
    }

    enum InstanceToolsTab: String, CaseIterable, Identifiable, Hashable {
        case manage, worlds, diagnostics
        var id: String { rawValue }
        var title: String {
            switch self {
            case .manage: return "实例管理"
            case .worlds: return "世界存档"
            case .diagnostics: return "启动诊断"
            }
        }
        var icon: String {
            switch self {
            case .manage: return "square.on.square"
            case .worlds: return "archivebox"
            case .diagnostics: return "stethoscope"
            }
        }
    }

    struct Settings: Equatable {
        var javaPath = ""
        var sourceRaw = DownloadSourcePolicy.auto.rawValue
        var mirrorConfigPath = ""
        var defaultMemoryMiB = 2048
        var appearanceRaw = LXAppearance.dark.rawValue

        var appearance: LXAppearance {
            get { LXAppearance(rawValue: appearanceRaw) ?? .dark }
            set { appearanceRaw = newValue.rawValue }
        }

        var source: DownloadSourcePolicy {
            get { DownloadSourcePolicy(rawValue: sourceRaw) ?? .auto }
            set { sourceRaw = newValue.rawValue }
        }
    }

    // MARK: - Published state

    @Published var section: Section = .home
    @Published var instances: [Instance] = []
    @Published var selectedInstanceID: String? {
        didSet {
            if oldValue != selectedInstanceID {
                ensureCompatibleJava()
            }
        }
    }
    @Published var installedVersionIDs: [String] = []
    @Published var javaRuntimes: [JavaRuntime] = []
    @Published var managedJava: [ManagedJava] = []
    @Published var selectedJavaPath = ""

    @Published var accounts: [AccountRow] = []
    @Published var activeMicrosoftAccountID: UUID?
    @Published var authState: AuthenticationState = .signedOut
    @Published var authSetupError: String?
    @Published var authActionInProgress = false
    @Published var playerAppearance: PlayerAppearance?
    @Published var lastError: String?
    @Published var logs: [LogEntry] = []
    @Published var logSearchText = ""
    @Published var autoScrollLogs = true
    @Published var isGameRunning = false
    @Published var gamePID: Int32?
    @Published var lastExit: GameExit?
    @Published var gameLogURL: URL?
    @Published var lastLaunchAt: Date?
    @Published var versionEntries: [VersionManifest.Entry] = []
    @Published var versionFilter: VersionFilter = .release
    @Published var isLoadingVersions = false
    @Published var settings: Settings
    @Published var showInstallWizard = false
    @Published var installWizardInitialVersion: String?
    @Published var showModsForInstance: Instance?
    @Published var showGraphicsForInstance: Instance?
    @Published var showResourcePacksForInstance: Instance?
    @Published var showModpackUpdateForInstance: Instance?
    @Published var showPerformanceForInstance: Instance?
    @Published var showMrpackImport = false
    @Published var mrpackImportURL: URL?
    @Published var showInstanceToolsForInstance: Instance?
    @Published var instanceToolsTab: InstanceToolsTab = .manage
    @Published var crashReport: CrashDiagnosticReport?
    @Published var crashReportError: String?
    @Published var isDiagnosing = false

    // MARK: - Services

    let layout: GameDataLayout
    private let instanceRepository: InstanceRepository
    private let localAccountStore: LocalAccountStore
    private let microsoftAccountStore: MicrosoftAccountStore
    private let activeAccountStore: ActiveAccountStore
    private let javaInspector = JavaRuntimeInspector()
    private let javaManager: JavaManager
    private let launchService: LaunchService
    private var authService: MicrosoftAuthenticationService?
    private var authObserver: Task<Void, Never>?
    private var launchTask: Task<Void, Never>?
    private var logBuffers: [String: String] = [:]
    private var launchInstanceID: String?

    // MARK: - Init

    init() {
        let environment = ProcessInfo.processInfo.environment
        let dataRoot = Self.root(
            environment["LINGXI_DATA_ROOT"],
            fallback: GameDataLayout.defaultDataRoot
        )
        let defaultGameRoot = FileManager.default.fileExists(atPath: GameDataLayout.officialMinecraftRoot.path)
            ? GameDataLayout.officialMinecraftRoot
            : dataRoot.appendingPathComponent("minecraft", isDirectory: true)
        let gameRoot = Self.root(environment["LINGXI_GAME_ROOT"], fallback: defaultGameRoot)
        let layout = GameDataLayout(gameRoot: gameRoot, dataRoot: dataRoot)
        self.layout = layout
        self.instanceRepository = InstanceRepository(layout: layout)
        self.localAccountStore = LocalAccountStore(layout: layout)
        self.microsoftAccountStore = MicrosoftAccountStore(layout: layout)
        self.activeAccountStore = ActiveAccountStore(layout: layout)
        self.launchService = LaunchService(layout: layout)
        self.javaManager = JavaManager(layout: layout, transport: URLSessionTransport())
        self.settings = Self.loadSettings()

        appendLine("LingXi Launcher \(LauncherInfo.version) starting", source: "launcher")
        appendLine("game root: \(gameRoot.path)", source: "launcher")
        appendLine("data root: \(dataRoot.path)", source: "launcher")

        reloadInstances()
        reloadAccounts()
        setupAuthentication()
        Task { await refreshJavaRuntimes() }
        Task { await loadVersions() }
    }

    private static func root(_ raw: String?, fallback: URL) -> URL {
        guard let raw, !raw.isEmpty else { return fallback }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    // MARK: - Derived state

    var selectedInstance: Instance? {
        guard let selectedInstanceID else { return nil }
        return instances.first { $0.id == selectedInstanceID }
    }

    var selectedJavaRuntime: JavaRuntime? {
        javaRuntimes.first { $0.executable.path == selectedJavaPath }
    }

    var activeMicrosoftAccount: MicrosoftAccount? {
        guard let activeMicrosoftAccountID else { return nil }
        return try? microsoftAccountStore.load(id: activeMicrosoftAccountID)
    }

    var activeAccountDescription: String {
        if let account = activeMicrosoftAccount {
            return "\(account.playerName) · Microsoft"
        }
        if let active = activeAccountStore.load(), active.kind == .local {
            return "\(active.identifier) · 本地（未验证，GUI 不提供启动）"
        }
        return "未登录"
    }

    var authConfigAvailable: Bool {
        MicrosoftAuthenticationFactory.isConfigured(layout: layout)
    }

    var latestGameLogURL: URL? {
        guard let instance = selectedInstance else { return nil }
        let url = instance.gameDirectory.appendingPathComponent("logs/latest.log")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var authPhaseText: String {
        switch authState {
        case .signedOut:
            return activeMicrosoftAccount == nil ? "未登录" : "已保存登录（启动时刷新）"
        case let .working(phase): return Self.phaseText(phase)
        case let .signedIn(account): return "已登录 \(account.playerName)"
        case let .failed(message, _): return "失败：\(message)"
        }
    }

    var filteredLogs: [LogEntry] {
        guard !logSearchText.isEmpty else { return logs }
        return logs.filter {
            $0.text.localizedCaseInsensitiveContains(logSearchText)
                || $0.source.localizedCaseInsensitiveContains(logSearchText)
        }
    }

    private static func phaseText(_ phase: AuthenticationPhase) -> String {
        switch phase {
        case .openingBrowser: return "打开浏览器…"
        case .waitingForCallback: return "等待微软回调…"
        case .exchangingCode: return "交换授权码…"
        case .xboxLive: return "Xbox Live 认证…"
        case .xsts: return "XSTS 授权…"
        case .minecraftServices: return "Minecraft Services 登录…"
        case .verifyingOwnership: return "验证游戏所有权…"
        case .refreshing: return "刷新登录状态…"
        case .completed: return "完成"
        }
    }

    // MARK: - Instances

    func reloadInstances() {
        do {
            instances = try instanceRepository.list()
            installedVersionIDs = Self.scanInstalledVersions(layout: layout)
            if selectedInstanceID == nil || !instances.contains(where: { $0.id == selectedInstanceID }) {
                selectedInstanceID = instances.first?.id
            }
        } catch {
            setError(error)
        }
    }

    private static func scanInstalledVersions(layout: GameDataLayout) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: layout.versionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
    }

    func createInstance(name: String, versionID: String?) {
        do {
            let instance = try instanceRepository.create(displayName: name, versionID: versionID)
            reloadInstances()
            selectedInstanceID = instance.id
            appendLine("Created instance \(instance.id) (\(name))", source: "instances")
        } catch {
            setError(error)
        }
    }

    func deleteInstance(_ instance: Instance) {
        do {
            try instanceRepository.delete(id: instance.id)
            appendLine("Deleted instance \(instance.manifest.displayName)", source: "instances")
            if selectedInstanceID == instance.id { selectedInstanceID = nil }
            reloadInstances()
        } catch {
            setError(error)
        }
    }

    func setMemory(_ memoryMiB: Int?, for instance: Instance) {
        do {
            _ = try instanceRepository.setMemory(id: instance.id, memoryMiB: memoryMiB)
            reloadInstances()
        } catch {
            setError(error)
        }
    }

    func openMods(instance: Instance) {
        section = .instances
        selectedInstanceID = instance.id
        showModsForInstance = instance
    }

    func openResourcePacks(instance: Instance) {
        showResourcePacksForInstance = instance
    }

    func openModpackUpdate(instance: Instance) {
        section = .instances
        selectedInstanceID = instance.id
        showModpackUpdateForInstance = instance
    }

    func openGraphics(instance: Instance) {
        section = .instances
        selectedInstanceID = instance.id
        showGraphicsForInstance = instance
    }

    func openPerformance(instance: Instance) {
        section = .instances
        selectedInstanceID = instance.id
        showPerformanceForInstance = instance
    }

    func openInstanceTools(_ instance: Instance, tab: InstanceToolsTab = .manage) {
        showInstanceToolsForInstance = instance
        instanceToolsTab = tab
        section = .instances
    }

    func openInstanceFolder(_ instance: Instance) {
        NSWorkspace.shared.open(instance.gameDirectory)
    }

    func openInstanceMetadataFolder(_ instance: Instance) {
        NSWorkspace.shared.open(instance.directory)
    }

    func openGameLogFolder() {
        let url = selectedInstance?.gameDirectory.appendingPathComponent("logs", isDirectory: true) ?? layout.gameRoot
        NSWorkspace.shared.open(url)
    }

    // MARK: - Java

    func refreshJavaRuntimes() async {
        javaRuntimes = javaManager.detectRuntimes()
        managedJava = javaManager.managedRuntimes()
        let runtimes = javaRuntimes
        if !settings.javaPath.isEmpty,
           let saved = runtimes.first(where: { $0.executable.path == settings.javaPath }) {
            selectedJavaPath = saved.executable.path
        } else if selectedJavaPath.isEmpty || !runtimes.contains(where: { $0.executable.path == selectedJavaPath }) {
            selectedJavaPath = runtimes.first?.executable.path ?? ""
        }
        appendLine("Detected \(runtimes.count) Java runtime(s)", source: "java")
        ensureCompatibleJava()
    }

    func javaSourceLabel(for runtime: JavaRuntime) -> String {
        managedJava.first { $0.runtime.executable == runtime.executable }?.source ?? "系统 / 本地 JDK"
    }

    /// Picks the closest compatible, preferably arm64 runtime for the selected instance.
    /// Keeps an explicit user choice when it satisfies the version requirement.
    func ensureCompatibleJava() {
        guard let versionID = selectedInstance?.manifest.versionID,
              let version = try? VersionResolver().resolve(versionID: versionID, from: layout.gameRoot),
              let required = version.javaRequirement.majorVersion,
              !javaRuntimes.isEmpty else { return }
        // Prefer the closest compatible runtime (1.20.1 → Java 17, not the newest JDK).
        let candidates = javaRuntimes.filter { $0.majorVersion >= required }
        let best = candidates.min { lhs, rhs in
            if lhs.architecture == .arm64 && rhs.architecture != .arm64 { return true }
            if lhs.architecture != .arm64 && rhs.architecture == .arm64 { return false }
            return lhs.majorVersion < rhs.majorVersion
        }
        if let best {
            selectJava(path: best.executable.path)
            appendLine("Auto-selected \(best.displayDescription) for Minecraft \(versionID)", source: "java")
        }
    }

    func selectJava(path: String) {
        selectedJavaPath = path
        settings.javaPath = path
        saveSettings()
        appendLine("Selected Java \(path)", source: "java")
    }

    func chooseJavaFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a java executable (…/bin/java)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let runtime = try javaInspector.inspect(executable: url)
            if !javaRuntimes.contains(where: { $0.executable.path == url.path }) {
                javaRuntimes.append(runtime)
            }
            selectJava(path: url.path)
        } catch {
            setError(error)
        }
    }

    // MARK: - Authentication

    private func setupAuthentication() {
        guard MicrosoftAuthenticationFactory.isConfigured(layout: layout) else {
            authSetupError = "内嵌 Microsoft Entra 注册不可用：请检查启动器构建。"
            return
        }
        do {
            let service = try MicrosoftAuthenticationFactory.makeDefault(
                layout: layout,
                authorizer: LoopbackOAuthAuthorizer(browser: ProcessBrowser())
            )
            authService = service
            authObserver = Task { [weak self] in
                guard let self else { return }
                for await state in await service.stateUpdates() {
                    self.applyAuthState(state)
                }
            }
        } catch {
            authSetupError = (error as? LauncherError)?.description ?? error.localizedDescription
            setError(error)
        }
    }

    private func applyAuthState(_ state: AuthenticationState) {
        authState = state
        switch state {
        case let .working(phase):
            appendLine("auth: \(Self.phaseText(phase))", source: "auth")
        case let .signedIn(account):
            appendLine("auth: signed in as \(account.playerName) (ownership verified: \(account.ownsGame))", source: "auth")
            reloadAccounts()
        case let .failed(message, _):
            lastError = message
            appendLine("auth failed: \(message)", source: "auth", level: .error)
        case .signedOut:
            reloadAccounts()
        }
    }

    func reloadAccounts() {
        let active = activeAccountStore.load()
        var rows: [AccountRow] = []
        let microsoftAccounts = (try? microsoftAccountStore.list()) ?? []
        for account in microsoftAccounts {
            rows.append(AccountRow(
                id: account.id.uuidString.lowercased(),
                kind: .microsoft,
                name: account.playerName,
                uuid: account.id.uuidString.lowercased(),
                ownsGame: account.ownsGame,
                lastValidated: account.lastValidatedAt,
                active: active?.kind == .microsoft && active?.identifier == account.id.uuidString.lowercased(),
                appearance: account.appearance
            ))
        }
        let localAccounts = (try? localAccountStore.list()) ?? []
        for account in localAccounts {
            rows.append(AccountRow(
                id: "local-\(account.playerName)",
                kind: .local,
                name: account.playerName,
                uuid: account.offlineUUID.uuidString.lowercased(),
                ownsGame: nil,
                lastValidated: nil,
                active: active?.kind == .local && active?.identifier == account.playerName,
                appearance: nil
            ))
        }
        accounts = rows
        if active?.kind == .microsoft, let uuid = UUID(uuidString: active?.identifier ?? "") {
            activeMicrosoftAccountID = uuid
        } else if activeMicrosoftAccountID == nil || !microsoftAccounts.contains(where: { $0.id == activeMicrosoftAccountID }) {
            activeMicrosoftAccountID = microsoftAccounts.first?.id
            if let id = activeMicrosoftAccountID {
                try? activeAccountStore.save(AccountReference(kind: .microsoft, identifier: id.uuidString.lowercased()))
            }
        }
        loadPlayerAppearance()
    }

    private func loadPlayerAppearance() {
        playerAppearance = activeMicrosoftAccount?.appearance
    }

    func signInMicrosoft() {
        guard let authService else {
            setError(authSetupError ?? "Microsoft authentication is not configured")
            return
        }
        authActionInProgress = true
        Task {
            defer { authActionInProgress = false }
            do {
                let account = try await authService.signIn()
                try? activeAccountStore.save(AccountReference(kind: .microsoft, identifier: account.id.uuidString.lowercased()))
                activeMicrosoftAccountID = account.id
                reloadAccounts()
                appendLine("Signed in as \(account.playerName)", source: "auth")
            } catch {
                setError(error)
            }
        }
    }

    func signOutMicrosoft(_ row: AccountRow) {
        guard let authService, let uuid = UUID(uuidString: row.id) else { return }
        authActionInProgress = true
        Task {
            defer { authActionInProgress = false }
            do {
                try await authService.signOut(accountID: uuid)
                if activeMicrosoftAccountID == uuid {
                    activeMicrosoftAccountID = nil
                    playerAppearance = nil
                }
                try? activeAccountStore.save(nil)
                reloadAccounts()
                appendLine("Signed out \(row.name)", source: "auth")
            } catch {
                setError(error)
            }
        }
    }

    func validateMicrosoft(_ row: AccountRow) {
        guard let authService, let uuid = UUID(uuidString: row.id) else { return }
        authActionInProgress = true
        Task {
            defer { authActionInProgress = false }
            do {
                let account = try await authService.validate(accountID: uuid)
                appendLine("Validated \(account.playerName) (ownership: \(account.ownsGame))", source: "auth")
                reloadAccounts()
            } catch {
                setError(error)
            }
        }
    }

    func selectAccount(_ row: AccountRow) {
        let reference = row.kind == .microsoft
            ? AccountReference(kind: .microsoft, identifier: row.id)
            : AccountReference(kind: .local, identifier: row.name)
        try? activeAccountStore.save(reference)
        if row.kind == .microsoft { activeMicrosoftAccountID = UUID(uuidString: row.id) }
        reloadAccounts()
    }

    // MARK: - Launch

    func launchSelectedInstance() {
        guard !isGameRunning else { return }
        guard let instance = selectedInstance else {
            lastError = "请选择一个游戏实例"
            return
        }
        guard let account = activeMicrosoftAccount else {
            lastError = "GUI 启动需要已登录的 Microsoft 账户；本地离线身份仅保留给 CLI 技术验证。"
            return
        }
        guard let java = selectedJavaRuntime else {
            lastError = "未选择可用的 Java 运行时"
            return
        }
        guard let authService else {
            lastError = authSetupError ?? "Microsoft authentication is not configured"
            return
        }
        lastError = nil
        lastLaunchAt = Date()
        launchInstanceID = instance.id
        crashReport = nil
        crashReportError = nil
        isGameRunning = true
        appendLine("Preparing launch of \(instance.manifest.displayName) with \(java.displayDescription)", source: "launch")
        launchTask?.cancel()
        launchTask = Task {
            do {
                let session = try await authService.session(for: account.id)
                let request = LaunchServiceRequest(
                    instance: instance,
                    identity: .microsoft(session),
                    javaExecutable: java.executable,
                    additionalJVMArguments: []
                )
                let stream = await launchService.launch(request)
                for await event in stream {
                    self.handleLaunchEvent(event)
                }
            } catch {
                self.isGameRunning = false
                self.setError(error)
                self.appendLine("Launch failed: \(Self.describe(error))", source: "launch", level: .error)
            }
            self.isGameRunning = await self.launchService.isRunning()
        }
    }

    /// Builds the same Microsoft-backed identity and Java runtime used by a real launch. The
    /// benchmark runner must not use a fake/offline identity or silently fall back to system Java.
    func makeBenchmarkContext(for instance: Instance) async throws -> (LaunchIdentity, URL) {
        guard let account = activeMicrosoftAccount else {
            throw LauncherError(.unauthorized, "Benchmarking requires a signed-in Microsoft account")
        }
        guard let java = selectedJavaRuntime else {
            throw LauncherError(.javaNotFound, "Select a Java runtime before benchmarking")
        }
        guard let authService else {
            throw LauncherError(.configurationMissing, authSetupError ?? "Microsoft authentication is not configured")
        }
        let session = try await authService.session(for: account.id)
        return (.microsoft(session), java.executable)
    }

    func makePerformanceProfileStore() -> PerformanceProfileStore {
        PerformanceProfileStore(layout: layout)
    }

    func makeBenchmarkRunner() -> BenchmarkRunner {
        BenchmarkRunner(layout: layout)
    }

    func refreshCrashDiagnostics(instance: Instance, exitCode: Int32? = nil) {
        isDiagnosing = true
        crashReportError = nil
        let service = CrashDiagnosticsService(layout: layout)
        Task {
            do {
                let report = try service.collect(instanceID: instance.id, exitCode: exitCode)
                self.crashReport = report
                self.isDiagnosing = false
            } catch {
                self.crashReportError = Self.describe(error)
                self.isDiagnosing = false
            }
        }
    }

    func exportCrashReport(_ report: CrashDiagnosticReport, markdown: Bool) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "lingxi-crash-\(report.instanceID).\(markdown ? "md" : "json")"
        panel.allowedContentTypes = markdown ? [.plainText] : [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            if markdown {
                data = Data(CrashReportExporter.markdown(for: report).utf8)
            } else {
                data = try CrashReportExporter.json(for: report)
            }
            try data.write(to: url, options: [.atomic])
            appendLine("Crash report exported: \(url.path)", source: "diagnostics")
        } catch {
            setError(error)
        }
    }

    func stopGame() {
        Task {
            appendLine("Stopping game process…", source: "launch")
            await launchService.stop()
        }
    }

    private func handleLaunchEvent(_ event: LaunchServiceEvent) {
        switch event {
        case let .phase(text):
            appendLine(text, source: "launch")
        case let .prepared(preview):
            appendLine(
                "Launch plan: \(preview.classpathEntryCount) classpath entries, \(preview.missingDependencies.count) missing, identity \(preview.identityMode.rawValue)",
                source: "launch"
            )
        case let .logFile(url):
            gameLogURL = url
            appendLine("Launcher log: \(url.path)", source: "launch")
        case let .started(pid):
            gamePID = pid
            appendLine("Game process started (pid \(pid))", source: "launch")
        case let .stdout(text):
            appendStreaming(text, source: "java")
        case let .stderr(text):
            appendStreaming(text, source: "java")
        case let .exited(exit):
            lastExit = exit
            isGameRunning = false
            gamePID = nil
            appendLine(
                "Game exited with code \(exit.code) (\(exit.reason.rawValue))",
                source: "launch",
                level: exit.isSuccess ? .info : .error
            )
            reloadInstances()
            if !exit.isSuccess, let id = launchInstanceID,
               let instance = instances.first(where: { $0.id == id }) {
                instanceToolsTab = .diagnostics
                showInstanceToolsForInstance = instance
                refreshCrashDiagnostics(instance: instance, exitCode: exit.code)
            }
        case let .failed(error):
            isGameRunning = false
            gamePID = nil
            setError(error)
            appendLine("Launch failed: \(Self.describe(error))", source: "launch", level: .error)
            if let id = launchInstanceID,
               let instance = instances.first(where: { $0.id == id }) {
                instanceToolsTab = .diagnostics
                showInstanceToolsForInstance = instance
                refreshCrashDiagnostics(instance: instance)
            }
        }
    }

    // MARK: - Downloads

    func loadVersions() async {
        guard !isLoadingVersions else { return }
        isLoadingVersions = true
        defer { isLoadingVersions = false }
        do {
            let mirror = try mirrorConfiguration()
            let installer = VanillaInstaller(
                layout: layout,
                transport: URLSessionTransport(),
                mirror: mirror
            )
            let entries = try await installer.listVersions(type: versionFilter.kind, policy: settings.source)
            versionEntries = entries
            appendLine("Loaded \(entries.count) Minecraft versions (\(settings.source.rawValue))", source: "downloads")
        } catch {
            setError(error)
        }
    }

    private func mirrorConfiguration() throws -> TrustedMirrorConfiguration? {
        guard !settings.mirrorConfigPath.isEmpty else {
            if settings.source == .mirror {
                throw LauncherError(
                    .usageError,
                    "Mirror mode requires a trusted mirror configuration",
                    suggestion: "Set the mirror JSON path in Settings → 下载源."
                )
            }
            return nil
        }
        return try TrustedMirrorConfiguration.load(
            from: URL(fileURLWithPath: (settings.mirrorConfigPath as NSString).expandingTildeInPath)
        )
    }

    // MARK: - Settings

    func makeOneStopInstaller() throws -> OneStopInstaller {
        OneStopInstaller(layout: layout, transport: URLSessionTransport(), mirror: try mirrorConfiguration())
    }

    func makeJavaManager() -> JavaManager {
        JavaManager(layout: layout, transport: URLSessionTransport())
    }

    func makeModManager() -> ModManager {
        ModManager(layout: layout, transport: URLSessionTransport())
    }

    func makeGraphicsSetupManager() -> GraphicsSetupManager {
        GraphicsSetupManager(layout: layout, transport: URLSessionTransport())
    }

    func makeModpackUpdateManager() -> ModpackUpdateManager {
        ModpackUpdateManager(layout: layout)
    }

    func makeResourcePackManager() -> ResourcePackManager {
        ResourcePackManager(layout: layout)
    }

    func makeShaderPackManager() -> ShaderPackManager {
        ShaderPackManager(layout: layout, transport: URLSessionTransport())
    }

    func makeMrpackInstaller() throws -> MrpackInstaller {
        MrpackInstaller(layout: layout, transport: URLSessionTransport(), mirror: try mirrorConfiguration())
    }

    func openMrpackImport(url: URL? = nil) {
        mrpackImportURL = url
        showMrpackImport = true
        section = .instances
    }

    func recordJavaRuntime(instanceID: String, runtime: JavaRuntime) {
        let record = makeJavaManager().runtimeRecord(for: runtime)
        do {
            _ = try InstanceRepository(layout: layout).setJavaRuntime(id: instanceID, record: record)
            appendLine("Java record: \(record.source) \(record.version) sha=\(record.artifactSHA1 ?? record.artifactSHA256 ?? record.executableSHA256 ?? "?")", source: "java")
        } catch {
            appendLine("Unable to record Java runtime for \(instanceID): \(Self.describe(error))", source: "java", level: .warning)
        }
    }

    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(settings.javaPath, forKey: "lingxi.javaPath")
        defaults.set(settings.sourceRaw, forKey: "lingxi.source")
        defaults.set(settings.mirrorConfigPath, forKey: "lingxi.mirrorConfigPath")
        defaults.set(settings.defaultMemoryMiB, forKey: "lingxi.defaultMemoryMiB")
        defaults.set(settings.appearanceRaw, forKey: "lingxi.appearance")
    }

    private static func loadSettings() -> Settings {
        let defaults = UserDefaults.standard
        var settings = Settings()
        settings.javaPath = defaults.string(forKey: "lingxi.javaPath") ?? ""
        settings.sourceRaw = defaults.string(forKey: "lingxi.source") ?? DownloadSourcePolicy.auto.rawValue
        settings.mirrorConfigPath = defaults.string(forKey: "lingxi.mirrorConfigPath") ?? ""
        let memory = defaults.integer(forKey: "lingxi.defaultMemoryMiB")
        if memory > 0 { settings.defaultMemoryMiB = memory }
        let appearance = ProcessInfo.processInfo.environment["LINGXI_APPEARANCE"]
            ?? defaults.string(forKey: "lingxi.appearance")
        if let appearance, let parsed = LXAppearance(rawValue: appearance) {
            settings.appearanceRaw = parsed.rawValue
        } else {
            settings.appearanceRaw = LXAppearance.dark.rawValue
        }
        return settings
    }

    func openDataFolder() {
        NSWorkspace.shared.open(layout.dataRoot)
    }

    func openGameRoot() {
        NSWorkspace.shared.open(layout.gameRoot)
    }

    // MARK: - Logging

    func appendLine(_ text: String, source: String, level: LogEntry.Level? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = LogEntry(
            date: Date(),
            level: level ?? Self.detectLevel(trimmed),
            source: source,
            text: trimmed
        )
        logs.append(entry)
        if logs.count > 6_000 {
            logs.removeFirst(logs.count - 6_000)
        }
    }

    private func appendStreaming(_ text: String, source: String) {
        let combined = (logBuffers[source] ?? "") + text
        let parts = combined.components(separatedBy: "\n")
        logBuffers[source] = parts.last
        for line in parts.dropLast() {
            appendLine(line, source: source, level: .game)
        }
        if let remainder = logBuffers[source], remainder.count > 8_192 {
            appendLine(remainder, source: source, level: .game)
            logBuffers[source] = ""
        }
    }

    private static func detectLevel(_ line: String) -> LogEntry.Level {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("exception") || lower.contains("fatal") {
            return .error
        }
        if lower.contains("warn") { return .warning }
        return .info
    }

    func diagnosticReport() -> String {
        var lines: [String] = [
            "# LingXi Launcher diagnostics",
            "generated: \(ISO8601DateFormatter().string(from: Date()))",
            "launcher: \(LauncherInfo.version)",
            "game root: \(layout.gameRoot.path)",
            "data root: \(layout.dataRoot.path)",
            "selected instance: \(selectedInstance.map { "\($0.id) (\($0.manifest.displayName))" } ?? "none")",
            "java: \(selectedJavaRuntime?.displayDescription ?? "none")",
            "account: \(activeMicrosoftAccount?.playerName ?? "none")",
            "auth state: \(authPhaseText)",
            "last exit: \(lastExit.map { "code \($0.code) \($0.reason.rawValue)" } ?? "none")",
            "",
            "# logs (redacted)",
        ]
        lines.append(contentsOf: logs.suffix(800).map { "[\($0.source)] \(redact($0.text))" })
        return lines.joined(separator: "\n")
    }

    func redact(_ text: String) -> String {
        var result = text
        let patterns = [
            #"(?i)(access_token|refresh_token|authorization|code)=([^&\s]+)"#,
            #"(?i)Bearer\s+[A-Za-z0-9._\-]+"#,
            #"XBL3\.0 x=[^;\s]+;[^\s]+"#,
            #"(?i)client_secret=([^&\s]+)"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "[redacted]",
                options: [.regularExpression]
            )
        }
        return result
    }

    // MARK: - Errors

    func setError(_ message: String) {
        lastError = message
    }

    func setError(_ error: Error) {
        if let launcherError = error as? LauncherError {
            lastError = launcherError.description
        } else {
            lastError = error.localizedDescription
        }
    }

    func clearError() {
        lastError = nil
    }

    static func describe(_ error: Error) -> String {
        (error as? LauncherError)?.description ?? error.localizedDescription
    }
}

/// Opens URLs through the system `open` tool (works from any actor, no AppKit isolation).
struct ProcessBrowser: BrowserOpening {
    func open(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LauncherError(.unauthorized, "The system browser could not open the sign-in page")
        }
    }
}
