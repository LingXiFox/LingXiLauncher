import Foundation
import LauncherCore

/// CLI surface for instance copy, world backups and crash diagnostics. Every operation calls the
/// same LauncherCore service used by the SwiftUI app; no filesystem rules are duplicated here.
enum InstanceToolsCLI {
    private struct CopyJSON: Encodable {
        let sourceID: String
        let instanceID: String
        let displayName: String
        let gameDirectory: String
        let copiedPaths: [String]
        let includeSaves: Bool
    }

    private struct DiagnosisJSON: Encodable {
        let report: CrashDiagnosticReport
    }

    static func copy(_ arguments: [String]) throws -> Int32 {
        guard let sourceID = arguments.first else {
            throw LauncherError(.usageError, "Missing source instance id", suggestion: "Use `lingxi instance copy <source-id> --name <new-name> [--saves]`.")
        }
        let spec = ArgumentParser.Spec(valueOptions: ["name", "root", "data-root"], flagOptions: ["json", "help", "saves"])
        let input = try ArgumentParser.parse(Array(arguments.dropFirst()), spec: spec)
        if input.has("help") {
            print("usage: lingxi instance copy <source-id> --name <new-name> [--saves] [--json]")
            return ExitStatus.success.rawValue
        }
        let layout = try CLI.resolveLayout(input, requireGameRoot: false)
        let repository = InstanceRepository(layout: layout)
        _ = repository
        let service = InstanceCopyService(layout: layout)
        let report = try service.copy(
            instanceID: sourceID,
            displayName: input.requireValue("name"),
            options: InstanceCopyOptions(includeSaves: input.has("saves"))
        )
        if input.has("json") {
            CLIOutput.emitJSON(CopyJSON(
                sourceID: report.sourceID,
                instanceID: report.instance.id,
                displayName: report.instance.manifest.displayName,
                gameDirectory: report.instance.gameDirectory.path,
                copiedPaths: report.copiedPaths,
                includeSaves: report.includeSaves
            ))
        } else {
            print("Instance copied: \(report.instance.id)")
            CLIOutput.field("source", report.sourceID)
            CLIOutput.field("display name", report.instance.manifest.displayName)
            CLIOutput.field("game directory", report.instance.gameDirectory.path)
            CLIOutput.field("copied", report.copiedPaths.joined(separator: ", "))
            CLIOutput.field("saves", report.includeSaves ? "included" : "skipped")
        }
        return ExitStatus.success.rawValue
    }

    static func runDiagnose(_ arguments: [String]) throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "root", "data-root", "exit-code"], flagOptions: ["json", "help"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi diagnose --instance <id> [--exit-code <n>] [--json]")
            return ExitStatus.success.rawValue
        }
        let layout = try CLI.resolveLayout(input, requireGameRoot: false)
        let service = CrashDiagnosticsService(layout: layout)
        let exitCode = input.value("exit-code").flatMap(Int32.init)
        let report = try service.collect(instanceID: input.requireValue("instance"), exitCode: exitCode)
        if input.has("json") {
            CLIOutput.emitJSON(DiagnosisJSON(report: report))
        } else {
            print("Diagnosis: \(report.summary)")
            CLIOutput.field("abnormal exit", report.abnormalExit ? "yes" : "no")
            for diagnostic in report.diagnostics {
                let root = diagnostic.isRootCause ? " [root cause]" : (diagnostic.isSecondary ? " [secondary]" : "")
                print("- \(diagnostic.category.displayName) (\(diagnostic.confidence.rawValue))\(root)")
                print("  \(diagnostic.explanation)")
                for recommendation in diagnostic.recommendations {
                    print("  -> \(recommendation)")
                }
            }
        }
        return ExitStatus.success.rawValue
    }


}
