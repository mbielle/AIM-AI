import AIMAgentKit
import AIMMacPlatform
import Foundation
import XCTest

final class ConfinementSecretsTests: XCTestCase {
    func testSecretFilesStayHiddenButPackageFoldersNamedCredentialsAreReadable() async throws {
        // The real path (/private/var/…): the sandbox profile names canonical folders.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("aim-confine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: String(cString: realpath(temporary.path, nil)))
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("node_modules/sdk/lib/credentials")
        let secrets = root.appendingPathComponent(".aws")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
        try "export {}".write(to: package.appendingPathComponent("types.mjs"), atomically: true, encoding: .utf8)
        try "secret".write(to: secrets.appendingPathComponent("credentials"), atomically: true, encoding: .utf8)
        try "TOKEN=secret".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        func run(_ arguments: [String]) async throws -> Int32 {
            let command = ProcessCommand(executable: URL(fileURLWithPath: "/bin/ls"), arguments: arguments,
                workingDirectory: root, environment: [:], timeout: .seconds(20), inheritsEnvironment: false)
            let confined = try OSProcessConfinement.prepare(command, readRoots: [root], writeRoots: [root],
                privateHome: root.appendingPathComponent("home"), network: .deny)
            let output = try await MacProcessRunner().runConfined(confined)
            if output.exitCode != 0 { print("confined ls", arguments, output.stderr) }
            return output.exitCode
        }
        let control = try await run([root.appendingPathComponent("node_modules").path])
        XCTAssertEqual(control, 0, "the confined ls itself works")
        let listed = try await run([package.path])
        XCTAssertEqual(listed, 0, "an SDK's lib/credentials folder is ordinary package code")
        let secret = try await run(["-l", secrets.appendingPathComponent("credentials").path])
        func cat(_ file: URL) async throws -> Int32 {
            let command = ProcessCommand(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [file.path],
                workingDirectory: root, environment: [:], timeout: .seconds(20), inheritsEnvironment: false)
            let confined = try OSProcessConfinement.prepare(command, readRoots: [root], writeRoots: [root],
                privateHome: root.appendingPathComponent("home"), network: .deny)
            return try await MacProcessRunner().runConfined(confined).exitCode
        }
        _ = secret
        let read = try await cat(secrets.appendingPathComponent("credentials"))
        XCTAssertNotEqual(read, 0, "a credentials file in a hidden folder stays unreadable")
        let environment = try await cat(root.appendingPathComponent(".env"))
        XCTAssertNotEqual(environment, 0, ".env files stay unreadable")
        let code = try await cat(package.appendingPathComponent("types.mjs"))
        XCTAssertEqual(code, 0)
    }
}
