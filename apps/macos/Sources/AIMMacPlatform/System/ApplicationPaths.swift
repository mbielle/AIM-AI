import AIMCore
import Foundation

public struct ApplicationPaths: Sendable {
    public let applicationSupport: URL
    public let database: URL
    public let media: URL
    public let engines: URL
    public let logs: URL

    public init(fileManager: FileManager = .default) throws {
        let supportBase = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        applicationSupport = supportBase.appending(path: AIMInstallationContext.applicationSupportNamespace, directoryHint: .isDirectory)
        database = applicationSupport.appending(path: "aim.sqlite")
        media = applicationSupport.appending(path: "Media", directoryHint: .isDirectory)
        engines = applicationSupport.appending(path: "Engines", directoryHint: .isDirectory)

        let logsBase = try fileManager.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "Logs", directoryHint: .isDirectory)
        logs = logsBase.appending(path: AIMInstallationContext.isQualification ? "AIM Qualification-" + AIMInstallationContext.applicationIdentifier : "AIM AI", directoryHint: .isDirectory)

        for directory in [applicationSupport, media, engines, logs] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
