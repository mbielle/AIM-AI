#if DEBUG
import AIMAgentKit
import AIMApplication
import AIMCore
import AIMMacPlatform
import Foundation

/// Exercise the production installer from the signed test bundle. No model
/// request or credential is needed to prepare and verify an upstream runtime.
enum UpstreamInstallationQualification {
    @MainActor
    static func run(into report: QualificationReport) async {
        guard AIMInstallationContext.isQualification else {
            report.set("conclusion", "Upstream installation qualification requires the isolated test bundle.")
            return
        }
        do {
            let paths = try ApplicationPaths()
            let installer = UpstreamAgentInstaller(root: paths.applicationSupport.appending(path: "Agents"))
            let arguments = ProcessInfo.processInfo.arguments
            let requested = arguments.firstIndex(of: "--engines").flatMap { index in
                index + 1 < arguments.count ? arguments[index + 1].split(separator: ",").map(String.init) : nil
            } ?? ["openclaw", "hermes"]
            var results: [String: Any] = [:]
            for name in requested {
                guard let engine = AgentEngineID(rawValue: name), UpstreamAgentInstaller.downloadable.contains(engine) else {
                    results[name] = ["passed": false, "error": "Unsupported engine"]
                    continue
                }
                do {
                    // Install, or move to the vetted version this build ships.
                    let current = (try? await installer.installation(engine)) ?? nil
                    if arguments.contains("--reinstall") || current?.updateAvailable != false {
                        for try await progress in await installer.install(engine) {
                            report.set("installation_progress", ["engine": name, "phase": progress.phase.rawValue,
                                "percent": progress.percent, "message": progress.message])
                            report.checkpoint()
                        }
                    }
                    guard let installation = try await installer.installation(engine) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    results[name] = ["passed": true, "version": installation.version, "update_available": installation.updateAvailable,
                        "runtime_and_entry_point_verified_under_network_deny": true,
                        "model_calls": 0, "bridge_mission_qualified": false]
                } catch {
                    results[name] = ["passed": false, "error": error.localizedDescription, "model_calls": 0]
                }
                report.set("engines", results)
                report.checkpoint()
            }
            let failed = results.filter { ($0.value as? [String: Any])?["passed"] as? Bool != true }.map(\.key).sorted()
            report.set("conclusion", failed.isEmpty ? "Official runtimes prepared; model/mission qualification remains." : "failed: " + failed.joined(separator: ", "))
        } catch {
            report.set("conclusion", "Installation could not start: " + error.localizedDescription)
        }
    }
}
#endif
