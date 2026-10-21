import AIMCore
import AIMAgentRuntime
import Foundation
#if DEBUG
import AIMApplication
import AIMMacPlatform
import GRDB
#endif

@main
enum AIMMacEntry {
    @MainActor static func main() async {
#if DEBUG
        let arguments = CommandLine.arguments
        if arguments.count == 2, arguments[1] == "--disable-empty-qualification-service" {
            do {
                guard AIMInstallationContext.isQualification else { throw CocoaError(.featureUnsupported) }
                // Recovery of a disposable test installation after a lost stop ACK.
                // No migrations, missions, keys or pairing data are changed.
                let paths = try ApplicationPaths()
                var configuration = Configuration(); configuration.readonly = true
                let database = try DatabaseQueue(path: paths.database.path, configuration: configuration)
                let empty = try await database.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agentExecutions") == 0
                        && Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scheduledTasks") == 0
                }
                guard empty else { throw CocoaError(.featureUnsupported) }
                let settings = UserDefaultsSettingsRepository(defaults: AIMInstallationContext.sharedPreferences)
                var value = await settings.load()
                var continuity = value.continuity ?? ContinuitySettings()
                continuity.permanent = false; value.continuity = continuity
                try await settings.save(value)
                try await AgentHostServiceController().disable()
                FileHandle.standardOutput.write(Data("Empty qualification service disabled; data retained.\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("Qualification service cleanup refused or incomplete.\n".utf8)); exit(1)
            }
            return
        }
        if AIMInstallationContext.isQualification,
           arguments.dropFirst().contains(where: { $0 == "--smappservice-qualification" || $0 == "--xpc-qualification-client" }) {
            FileHandle.standardError.write(Data("Legacy fixtures are separate from an isolated AIM test installation.\n".utf8)); exit(1)
        }
        if arguments.count == 4, arguments[1] == "--smappservice-qualification" {
            do {
                try await SignedXPCQualification.registerAndProbe(helperBundle: URL(fileURLWithPath: arguments[2]), report: URL(fileURLWithPath: arguments[3]))
            } catch { FileHandle.standardError.write(Data("SMAppService qualification failed.\n".utf8)); exit(1) }
            return
        }
        if arguments.count == 5, arguments[1] == "--xpc-qualification-client" {
            do {
                try await SignedXPCQualification.probe(name: arguments[2], helperBundle: URL(fileURLWithPath: arguments[3]),
                    report: URL(fileURLWithPath: arguments[4]), expectedRejection: false)
            } catch { FileHandle.standardError.write(Data("Signed XPC qualification failed.\n".utf8)); exit(1) }
            return
        }
#endif
        AIMMacApp.main()
    }
}
