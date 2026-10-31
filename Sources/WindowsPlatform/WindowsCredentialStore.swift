import Foundation
import LauncherCore

/// DPAPI-backed refresh-token store. The token is sent to a short-lived PowerShell process over
/// stdin (never argv), encrypted for the current Windows user, and written atomically.
public struct WindowsCredentialStore: RefreshTokenStoring, Sendable {
    private let directory: URL

    public init() {
        let base = ProcessInfo.processInfo.environment["APPDATA"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        self.directory = URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("LingXiLauncher/credentials", isDirectory: true)
    }

    public func save(refreshToken: String, for accountID: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = file(for: accountID)
        let temporary = target.appendingPathExtension("tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let script = """
        Add-Type -AssemblyName System.Security
        $plain = [Console]::In.ReadToEnd()
        $bytes = [Text.Encoding]::UTF8.GetBytes($plain)
        $entropy = [Text.Encoding]::UTF8.GetBytes('LingXiLauncher')
        $protected = [Security.Cryptography.ProtectedData]::Protect($bytes, $entropy, 'CurrentUser')
        [IO.File]::WriteAllBytes($env:LINGXI_DPAPI_PATH, $protected)
        """
        _ = try runPowerShell(script, path: temporary.path, stdin: refreshToken)
        guard FileManager.default.fileExists(atPath: temporary.path) else {
            throw LauncherError(.ioFailure, "DPAPI did not produce a credential file")
        }
        if FileManager.default.fileExists(atPath: target.path) {
            try PlatformRuntime.replacer.replaceItem(at: target, with: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: target)
        }
    }

    public func loadRefreshToken(for accountID: UUID) throws -> String? {
        let target = file(for: accountID)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        let script = """
        Add-Type -AssemblyName System.Security
        $protected = [IO.File]::ReadAllBytes($env:LINGXI_DPAPI_PATH)
        $entropy = [Text.Encoding]::UTF8.GetBytes('LingXiLauncher')
        $plain = [Security.Cryptography.ProtectedData]::Unprotect($protected, $entropy, 'CurrentUser')
        [Console]::Out.Write([Convert]::ToBase64String($plain))
        """
        let output = try runPowerShell(script, path: target.path, stdin: nil)
        guard let data = Data(base64Encoded: output.trimmingCharacters(in: .whitespacesAndNewlines)),
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw LauncherError(.keychainFailure, "The saved Windows credential is damaged")
        }
        return token
    }

    public func deleteRefreshToken(for accountID: UUID) throws {
        let target = file(for: accountID)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        do { try FileManager.default.removeItem(at: target) }
        catch { throw LauncherError(.keychainFailure, "Cannot delete Windows credential: \(error.localizedDescription)") }
    }

    private func file(for accountID: UUID) -> URL {
        directory.appendingPathComponent("\(accountID.uuidString.lowercased()).bin", isDirectory: false)
    }

    private func runPowerShell(_ script: String, path: String, stdin: String?) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")
        process.arguments = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script]
        var environment = ProcessInfo.processInfo.environment
        environment["LINGXI_DPAPI_PATH"] = path
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch {
            throw LauncherError(.keychainFailure, "Cannot start Windows DPAPI helper: \(error.localizedDescription)")
        }
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
        }
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw LauncherError(.keychainFailure, "Windows DPAPI helper failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return stdout
    }
}
