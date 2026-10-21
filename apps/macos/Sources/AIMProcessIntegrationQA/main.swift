// DEBUG-only synthetic integration host. No XCTest discovery or app startup.
import AIMCore
import AIMAgentKit
import AIMMacPlatform
import CryptoKit
import Darwin
import Foundation
import MachO

#if DEBUG
struct Check: Codable {
    let id: String
    let expected: String
    let observed: String
    let passed: Bool
}
struct Receipt: Encodable {
    let schema = 1
    let runID: String
    let caseID: String
    let originalTest: String
    let sourceSHA256: String
    let binarySHA256: String
    let namespace: String
    let pid = ProcessInfo.processInfo.processIdentifier
    let startedAt: Date
    let finishedAt: Date
    let checks: [Check]
    let status: String
    let isolation = "Separate synthetic home/process; host outside XCTest fence, not host-wide OS isolation; workers retain real Seatbelt network deny"
    let physicalDevicesQualified = false
}
func observedImages() -> [String] {
    (0..<_dyld_image_count()).compactMap { index in
        guard let name = _dyld_get_image_name(index) else { return nil }
        let value = String(cString: name)
        return ["ContactsUICore", "ContactsUI.framework", "XCTest.framework"].contains(where: value.contains)
            ? URL(fileURLWithPath: value).lastPathComponent : nil
    }
}
func digest(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}
func executeCase(_ caseID: String, root: URL, record: (String, String, String, Bool) -> Void) async throws {
    let fm = FileManager.default
    if caseID == "sourcekit" {
        let project = root.appendingPathComponent("project")
        try fm.createDirectory(at: project.appendingPathComponent("Sources/Demo"), withIntermediateDirectories: true)
        try "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"Demo\", targets: [.target(name: \"Demo\")])\n"
            .write(to: project.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        struct Greeter {
            func greet(_ name: String) -> String { "Hi " + name }
        }

        func run() -> Int {
            let text = Greeter().greet("AIM")
            let wrong: Int = text
            return wrong
        }

        """.write(to: project.appendingPathComponent("Sources/Demo/Demo.swift"), atomically: true, encoding: .utf8)
        let outside = root.appendingPathComponent("outside.swift")
        try "// synthetic outside workspace".write(to: outside, atomically: true, encoding: .utf8)
        let service = CodeIntelligenceToolService()
        func run(_ name: String, _ arguments: [String: String]) async -> ToolResult {
            await service.execute(ToolRequest(name: name, arguments: arguments, risk: .readOnly, workspacePath: project.path))
        }
        let diagnostics = await run("code_diagnostics", ["path": "Sources/Demo/Demo.swift"])
        record("diagnostic-line7", "Real type error at Demo.swift:7", diagnostics.content,
            !diagnostics.isError && diagnostics.content.contains("Sources/Demo/Demo.swift:7:") && diagnostics.content.contains("error"))
        let symbols = await run("code_symbols", ["path": "Sources/Demo/Demo.swift"])
        record("symbols-greeter-greet", "struct Greeter line 1 and greet", symbols.content,
            !symbols.isError && symbols.content.contains("struct Greeter (line 1)") && symbols.content.contains("greet"))
        let definition = await run("code_definition", ["path": "Sources/Demo/Demo.swift", "line": "6", "column": "26"])
        record("definition-line2", "Definition at Demo.swift:2", definition.content,
            !definition.isError && definition.content.contains("Sources/Demo/Demo.swift:2:"))
        let rejected = await run("code_diagnostics", ["path": outside.path])
        record("outside-scope-denied", "Synthetic outside file refused", rejected.content, rejected.isError)
        await service.closeSession()
    } else if caseID == "confinement" {
        let project = root.appendingPathComponent("project")
        let package = project.appendingPathComponent("node_modules/sdk/lib/credentials")
        let aws = project.appendingPathComponent(".aws/credentials")
        let env = project.appendingPathComponent(".env")
        let home = root.appendingPathComponent("worker-home")
        for folder in [package, aws.deletingLastPathComponent(), home] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let code = "export {}; // synthetic SDK fixture\n"
        let awsValue = "synthetic-aws-" + UUID().uuidString
        let envValue = "SYNTHETIC=" + UUID().uuidString
        try code.write(to: package.appendingPathComponent("types.mjs"), atomically: true, encoding: .utf8)
        try awsValue.write(to: aws, atomically: true, encoding: .utf8)
        try envValue.write(to: env, atomically: true, encoding: .utf8)
        let runner = MacProcessRunner()
        func worker(_ commandText: String, _ argument: URL) async throws -> (ProcessOutput, String) {
            let marker = "AIM_QA_WORKER_STARTED_" + UUID().uuidString + "\n"
            let command = ProcessCommand(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf '%s' \"$1\"; " + commandText + " \"$2\"", "qa-worker", marker, argument.path],
                workingDirectory: project, environment: [:], timeout: .seconds(20), inheritsEnvironment: false)
            let confined = try OSProcessConfinement.prepare(command, readRoots: [project], writeRoots: [project, home], privateHome: home, network: .deny)
            return (try await runner.runConfined(confined), marker)
        }
        let (listing, listMarker) = try await worker("exec /bin/ls", package)
        record("worker-started-package-list", "Confined worker starts and lists types.mjs", "exit=\(listing.exitCode); \(listing.stdout)",
            listing.exitCode == 0 && listing.stdout.hasPrefix(listMarker) && listing.stdout.contains("types.mjs"))
        let (read, readMarker) = try await worker("exec /bin/cat", package.appendingPathComponent("types.mjs"))
        record("sdk-code-exact", "Exact synthetic SDK contents readable", "exit=\(read.exitCode); exact=\(read.stdout == readMarker + code)",
            read.exitCode == 0 && read.stdout == readMarker + code)
        for (id, file, value) in [("aws-denied-after-start", aws, awsValue), ("env-denied-after-start", env, envValue)] {
            let (output, marker) = try await worker("exec /bin/cat", file)
            let denied = output.stderr.contains("Operation not permitted") || output.stderr.contains("Permission denied")
            record(id, "Worker starts, then synthetic secret read denied", "exit=\(output.exitCode); started=\(output.stdout == marker); permissionDenied=\(denied)",
                output.exitCode != 0 && output.stdout == marker && denied && !output.stdout.contains(value) && !output.stderr.contains("sandbox_apply"))
        }
        await runner.terminateAll()
    } else { throw NSError(domain: "AIMProcessIntegrationQA.invalidCase", code: 1) }
}

var checks: [Check] = []
let started = Date()
do {
    let arguments = CommandLine.arguments
    func option(_ name: String) throws -> String {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
            throw NSError(domain: "AIMProcessIntegrationQA.missingArgument", code: 1)
        }
        return arguments[index + 1]
    }
    let caseID = try option("--case")
    let runID = try option("--run-id")
    let source = try option("--source-sha256")
    let root = URL(fileURLWithPath: try option("--root"), isDirectory: true).resolvingSymlinksInPath()
    let receiptURL = URL(fileURLWithPath: try option("--receipt"))
    let namespace = "com.aimai.macos.qualification." + (try option("--installation-id"))
    guard ["sourcekit", "confinement"].contains(caseID), runID.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil,
        source.count == 64, !FileManager.default.fileExists(atPath: receiptURL.path),
        namespace.range(of: "^com\\.aimai\\.macos\\.qualification\\.[0-9a-f]{32}$", options: .regularExpression) != nil,
        Bundle.main.bundleIdentifier == namespace,
        Bundle.main.object(forInfoDictionaryKey: "AIMQualificationNamespace") as? String == namespace,
        Bundle.main.bundleURL.deletingLastPathComponent() == root,
        receiptURL.deletingLastPathComponent() == root,
        root.lastPathComponent == caseID, root.deletingLastPathComponent().lastPathComponent == runID,
        URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == root.appendingPathComponent("home") else {
        throw NSError(domain: "AIMProcessIntegrationQA.invalidIsolation", code: 1)
    }
    guard AIMInstallationContext.isQualification, AIMInstallationContext.applicationIdentifier == namespace else {
        throw NSError(domain: "AIMProcessIntegrationQA.productionNamespace", code: 1)
    }
    let record: (String, String, String, Bool) -> Void = { id, expected, observed, passed in
        checks.append(Check(id: id, expected: expected, observed: observed, passed: passed))
        print("QA check \(id): \(passed ? "passed" : "FAILED")")
    }
    let initialImages = observedImages()
    record("startup-no-discovery", "No XCTest image; loaded Contacts images observed separately from initialization trace", initialImages.joined(separator: ","), !initialImages.contains("XCTest"))
    if !initialImages.contains("XCTest") {
        do { try await executeCase(caseID, root: root, record: record) }
        catch { record("execution-error", "Integration completes without exception", String(describing: type(of: error)), false) }
    }
    let finalImages = observedImages()
    record("finish-no-discovery", "No XCTest image; Contacts initialization checked by runtime trace", finalImages.joined(separator: ","), !finalImages.contains("XCTest"))
    let passed = !checks.isEmpty && checks.allSatisfy(\.passed)
    let receipt = Receipt(runID: runID, caseID: caseID,
        originalTest: caseID == "sourcekit" ? "AIMMacPlatformTests.CodeIntelligenceTests/testSourceKitDiagnosticsSymbolsAndDefinition" : "AIMMacPlatformTests.ConfinementSecretsTests/testSecretFilesStayHiddenButPackageFoldersNamedCredentialsAreReadable",
        sourceSHA256: source, binarySHA256: try digest(URL(fileURLWithPath: arguments[0])), namespace: namespace,
        startedAt: started, finishedAt: Date(), checks: checks, status: passed ? "passed" : "failed")
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(receipt).write(to: receiptURL, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
    exit(passed ? 0 : 1)
} catch {
    fputs("QA host rejected invocation: \(type(of: error))\n", stderr)
    exit(1)
}
#else
fputs("AIMProcessIntegrationQA requires DEBUG; no integration executed.\n", stderr)
exit(1)
#endif
