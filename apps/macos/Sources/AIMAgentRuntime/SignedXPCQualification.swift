#if DEBUG
import Foundation
import ServiceManagement

/// Signed-peer transport only. No accounts, live runtime, model or desktop.
package enum SignedXPCQualification {
    package static func registerAndProbe(helperBundle: URL, report: URL) async throws {
        let name = "com.aimai.macos.agenthost.qualification.smappservice"
        let service = SMAppService.agent(plistName: name + ".plist")
        if service.status != .enabled { try service.register() }
        if service.status == .requiresApproval {
            try JSONEncoder().encode(["qualification": "smappservice-signed-nsxpc", "status": "requiresApproval",
                "limitation": "Only an isolated fixture service; no production runtime or data"]).write(to: report, options: .atomic)
            return
        }
        do {
            try await probe(name: name, helperBundle: helperBundle, report: report, expectedRejection: false)
            try await service.unregister()
            try JSONEncoder().encode(["qualification": "smappservice-signed-nsxpc", "status": "passed",
                "limitation": "No production runtime, account, permissions or desktop qualification"]).write(to: report, options: .atomic)
        } catch { try? await service.unregister(); throw error }
    }
    private actor FixtureClient: AgentHostClient {
        var stopped = false
        func send(_ command: AgentHostCommand) throws -> Data {
            switch command.action {
            case .list: return Data("[]".utf8)
            case .stop: stopped = true; return Data("{}".utf8)
            default: throw AgentHostTransportError.invalidMessage
            }
        }
    }
    package static func serve(name: String, applicationBundle: URL) async throws {
        guard name.hasPrefix("com.aimai.macos.agenthost.qualification.") else { throw AgentHostTransportError.wrongIdentity }
        let client = FixtureClient()
        let server = try AgentHostXPCServer(client: client, applicationBundle: applicationBundle, machServiceName: name)
        server.start(); defer { server.stop() }
        let deadline = Date.now.addingTimeInterval(120)
        while !(await client.stopped), Date.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
    }
    package static func probe(name: String, helperBundle: URL, report: URL, expectedRejection: Bool) async throws {
        guard name.hasPrefix("com.aimai.macos.agenthost.qualification."),
              report.path.hasPrefix("/private/tmp/aim-continuity-") else { throw AgentHostTransportError.wrongIdentity }
        let client = try XPCBasedAgentHostClient(helperBundle: helperBundle, machServiceName: name)
        var accepted = false
        do {
            let data = try await client.send(AgentHostCommand(action: .list))
            accepted = data == Data("[]".utf8)
        } catch {
            if !expectedRejection { throw error }
        }
        let passed = expectedRejection ? !accepted : accepted
        let result = ["qualification": "signed-nsxpc-transport", "passed": passed ? "true" : "false",
            "expectedRejection": expectedRejection ? "true" : "false", "uidChecked": "true",
            "limitation": "No SMAppService, account, model, desktop or permanent runtime qualification"]
        try JSONEncoder().encode(result).write(to: report, options: .atomic)
        guard passed else { throw AgentHostTransportError.invalidSignature }
        if !expectedRejection { _ = try await client.send(AgentHostCommand(action: .stop)) }
    }
}
#endif
