#if DEBUG
import AIMApplication
import AIMMacPlatform
import AppKit
import Foundation

/// Debug-only entry point for field qualification inside the signed bundle:
/// `open -g -a "AIM AI.app" --args --agent-qualification <suite> <report.json> [--exit-when-done]`.
/// Launching through LaunchServices keeps AIM the responsible process for TCC.
/// Suites act only on AIM's disposable fixtures and never on user content.
enum QualificationCommand {
    struct Invocation: Equatable {
        let suite: String
        let destination: URL
        let exitWhenDone: Bool
    }

    static let suites: Set<String> = ["cua-diagnostic", "cua-ladder", "cua-tools", "cua-field", "cua-fixture", "live", "browser-isolated", "native-apps", "mcp", "scheduler", "skill-learning", "cua-manifest", "browser-extension", "cua-real-apps", "upstream-install", "external-live", "capabilities"]

    static func parse(_ arguments: [String]) -> Invocation? {
        if let index = arguments.firstIndex(of: "--agent-qualification"), index + 2 < arguments.count {
            return Invocation(suite: arguments[index + 1],
                destination: URL(fileURLWithPath: arguments[index + 2]),
                exitWhenDone: arguments.contains("--exit-when-done"))
        }
        // Legacy alias kept for older notes and scripts.
        if let index = arguments.firstIndex(of: "--agent-cua-fixture-report"), index + 1 < arguments.count {
            return Invocation(suite: "cua-fixture", destination: URL(fileURLWithPath: arguments[index + 1]),
                exitWhenDone: arguments.contains("--exit-when-done"))
        }
        return nil
    }

    @MainActor
    static func start(_ invocation: Invocation, model: AppModel) {
        // Local qualification drives AIM without a person signed in (DEBUG builds only).
        Task { @MainActor in
            let report = QualificationReport(suite: invocation.suite, destination: invocation.destination)
            // Who acted: AIM's agent with a real model, or a test script calling AIM's tools directly.
            report.set("driver", ["live", "scheduler", "skill-learning", "external-live", "capabilities"].contains(invocation.suite)
                ? "agent (AIM with a real model decides the actions)" : "script (AIM's tools called by a test script, no model)")
            report.checkpoint()
            switch invocation.suite {
            case "upstream-install":
                await UpstreamInstallationQualification.run(into: report)
            case "external-live":
                await ExternalLiveQualification.run(into: report, model: model)
            case "capabilities":
                await CapabilityQualification.run(into: report, model: model)
            case "cua-diagnostic":
                await CuaDiagnosticV2.run(into: report)
            case "cua-ladder":
                await CuaCapabilityQualifier.run(into: report)
                let recorded = await model.recordCuaQualification(report)
                report.set("recorded_capabilities", recorded.map(\.rawValue))
            case "cua-tools":
                let qualified: [CuaCapability: String]
                if let key = await CuaRuntimeIdentity.currentKey() {
                    qualified = (try? await model.cuaQualificationRepository.qualified(for: key)) ?? [:]
                } else {
                    qualified = [:]
                }
                report.set("qualified_capabilities", qualified.keys.map(\.rawValue).sorted())
                await CuaToolServiceQualification.run(into: report, qualified: qualified)
            case "cua-real-apps":
                // --apps calculator,textedit,chrome (default: all three).
                let arguments = ProcessInfo.processInfo.arguments
                let apps = arguments.firstIndex(of: "--apps").flatMap { index in
                    index + 1 < arguments.count ? Set(arguments[index + 1].split(separator: ",").map(String.init)) : nil
                } ?? ["calculator", "textedit", "chrome"]
                var qualified: [CuaCapability: String] = [:]
                if let key = await CuaRuntimeIdentity.currentKey() {
                    qualified = (try? await model.cuaQualificationRepository.qualified(for: key)) ?? [:]
                }
                await CuaRealAppsQualification.run(into: report, qualified: qualified, apps: apps)
            case "cua-field":
                await CuaFieldMatrix.run(into: report)
            case "live":
                // --scenarios a,b,c (default: all) and optional --spend-cap-usd per scenario.
                let arguments = ProcessInfo.processInfo.arguments
                let ids = arguments.firstIndex(of: "--scenarios").flatMap { index in
                    index + 1 < arguments.count ? arguments[index + 1].split(separator: ",").map(String.init) : nil
                } ?? LiveScenarioRunner.scenarios
                let cap = arguments.firstIndex(of: "--spend-cap-usd").flatMap { index in
                    index + 1 < arguments.count ? Decimal(string: arguments[index + 1]) : nil
                }
                await LiveScenarioRunner.run(ids: ids, report: report, model: model, scenarioCap: cap)
            case "browser-isolated":
                await BrowserIsolatedQualification.run(into: report)
            case "browser-extension":
                await BrowserIsolatedQualification.run(into: report, extensionMode: true)
            case "native-apps":
                // --apps calendar,reminders,notes,mail (default: all four).
                let arguments = ProcessInfo.processInfo.arguments
                let apps = arguments.firstIndex(of: "--apps").flatMap { index in
                    index + 1 < arguments.count ? Set(arguments[index + 1].split(separator: ",").map(String.init)) : nil
                } ?? ["calendar", "reminders", "notes", "mail"]
                await NativeAppsQualification.run(into: report, apps: apps)
            case "mcp":
                await MCPQualification.run(into: report)
            case "cua-manifest":
                await exportCuaManifest(into: report, model: model)
            case "scheduler":
                await SchedulerQualification.run(into: report, model: model)
            case "skill-learning":
                await SkillLearningQualification.run(into: report, model: model)
            case "cua-fixture":
                let legacy = await CuaFixtureQualification.report()
                report.set("legacy_report", try? JSONSerialization.jsonObject(with: legacy))
            default:
                report.set("error", "Unknown suite. Known suites: \(suites.sorted().joined(separator: ", "))")
            }
            report.finish()
            guard invocation.exitWhenDone else { return }
            // Suites stop their own helpers before finishing. `terminate` may run a
            // nested modal loop while shutdown is prepared, so arm the fallback first
            // and never leave a stray debug instance behind.
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { exit(0) }
            NSApp.terminate(nil)
        }
    }
}

/// Builds the release manifest entry from this Mac's ladder-qualified records
/// (not from adopted ones) merged with the bundled manifest. Copy the report's
/// "manifest" object to Config/CuaQualificationManifest.json to ship it.
@MainActor
private func exportCuaManifest(into report: QualificationReport, model: AppModel) async {
    guard let key = await CuaRuntimeIdentity.currentKey() else {
        report.set("conclusion", "No signed embedded CUA driver.")
        return
    }
    let records = ((try? await model.cuaQualificationRepository.allQualified()) ?? [])
        .filter { $0.key == key && !$0.evidence.hasPrefix("Release manifest:") }
    guard !records.isEmpty else {
        report.set("conclusion", "No ladder-qualified capability for this driver, macOS build and contract; run cua-ladder first.")
        return
    }
    let entry = CuaReleaseManifest.Entry(key: key,
        capabilities: Dictionary(records.map { ($0.capability.rawValue, $0.schemaDigest) }, uniquingKeysWith: { first, _ in first }),
        qualifiedAt: records.map(\.qualifiedAt).max() ?? .now)
    let bundled = Bundle.main.url(forResource: "CuaQualificationManifest", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }.flatMap { try? CuaReleaseManifest.decode($0) } ?? CuaReleaseManifest(entries: [])
    let manifest = bundled.merging(entry)
    if let data = try? manifest.encoded(), let object = try? JSONSerialization.jsonObject(with: data) {
        report.set("manifest", object)
    }
    report.set("conclusion", "manifest entry for macOS \(key.osBuild) with \(entry.capabilities.count) capabilities (\(manifest.entries.count) entries in total)")
}
#endif
