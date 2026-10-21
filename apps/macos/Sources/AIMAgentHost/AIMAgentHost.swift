import AIMCore
import AIMAgentRuntime
import AIMApplication
import AppKit
import Foundation

@main
struct AIMAgentHostMain {
    @MainActor
    static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
#if DEBUG
            if AIMInstallationContext.isQualification,
               CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--xpc-qualification") || $0 == "--remote-continuity-qualification" }) {
                // Legacy fixtures intentionally have their own production-account
                // read-only proxy. They are not a path into an isolated test app.
                throw CocoaError(.featureUnsupported)
            }
            if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--migrate-qualification-database" {
                let file = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
                let root = URL(fileURLWithPath: "/private/tmp").standardizedFileURL.resolvingSymlinksInPath()
                guard file.lastPathComponent == "database.sqlite",
                      file.deletingLastPathComponent().lastPathComponent.hasPrefix("aim-continuity-qualification-migration-"),
                      file.deletingLastPathComponent().deletingLastPathComponent().path == root.path,
                      FileManager.default.fileExists(atPath: file.path) else { throw DatabaseOpenError.missingSchema }
                _ = try AIMDatabase(path: file.path)
                return
            }
            if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--remote-continuity-qualification" {
                try await RemoteContinuityQualification.run(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
                return
            }
            if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--xpc-qualification-server" {
                try await SignedXPCQualification.serve(name: CommandLine.arguments[2], applicationBundle: URL(fileURLWithPath: CommandLine.arguments[3]))
                return
            }
            if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--xpc-qualification-rejected-peer" {
                try await SignedXPCQualification.probe(name: CommandLine.arguments[2], helperBundle: Bundle.main.bundleURL,
                    report: URL(fileURLWithPath: CommandLine.arguments[4]), expectedRejection: true)
                return
            }
            if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--continuity-qualification",
               let duration = Double(CommandLine.arguments[3]) {
                try await ContinuityQualificationHarness.run(directory: URL(fileURLWithPath: CommandLine.arguments[2]), duration: duration)
                return
            }
#endif
            // A previously registered service can still be launched during disable.
            // Exit successfully before opening or migrating the live database.
            let settings = UserDefaultsSettingsRepository(defaults: AIMInstallationContext.sharedPreferences)
            guard await settings.load().continuity?.permanent == true else { return }
            let runtime = try await AgentHostRuntime()
            signal(SIGTERM, SIG_IGN)
            let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            termination.setEventHandler { Task { try? await runtime.stop() } }
            termination.resume()
            while !runtime.stopped {
                try await Task.sleep(for: .seconds(1))
                try await runtime.tick()
            }
            termination.cancel()
        } catch {
#if DEBUG
            if CommandLine.arguments.contains("--continuity-qualification") {
                // This fixture cannot contain user requests or credentials.
                FileHandle.standardError.write(Data("Isolated endurance diagnostic: \(error)\n".utf8))
            }
#endif
            // No request, token or provider response is printed to system logs.
            FileHandle.standardError.write(Data("AIMAgentHost could not start or continue safely.\n".utf8))
            exit(1)
        }
    }
}
