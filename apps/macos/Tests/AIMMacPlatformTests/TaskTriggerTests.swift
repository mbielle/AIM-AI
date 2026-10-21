import AIMApplication
@testable import AIMMacPlatform
import XCTest

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(UUID, String, String?)] = []
    func add(_ item: (UUID, String, String?)) { lock.withLock { items.append(item) } }
    var all: [(UUID, String, String?)] { lock.withLock { items } }
}

private final class ScriptOutputs: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [String]
    init(_ outputs: [String]) { self.outputs = outputs }
    func next() -> String? { lock.withLock { outputs.isEmpty ? nil : outputs.removeFirst() } }
}

@MainActor
final class TaskTriggerTests: XCTestCase {
    private func task(_ trigger: ScheduledTaskSpec.Trigger) -> ScheduledTask {
        ScheduledTask(title: "T", prompt: "p", spec: ScheduledTaskSpec(trigger: trigger, modelID: "m"))
    }

    func testWebhookParsing() {
        let id = UUID()
        let request = Data("POST /aim/tasks/\(id.uuidString) HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer tok\r\nContent-Length: 5\r\n\r\nhello".utf8)
        XCTAssertEqual(LocalWebhookServer.parse(request), .request(taskID: id, token: "tok", body: "hello"))
        XCTAssertEqual(LocalWebhookServer.parse(request.prefix(request.count - 2)), .incomplete)
        XCTAssertEqual(LocalWebhookServer.parse(Data("GET /aim/tasks/\(id) HTTP/1.1\r\n\r\n".utf8)), .invalid(405))
        XCTAssertEqual(LocalWebhookServer.parse(Data("POST /aim/tasks/\(id) HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8)), .invalid(401))
        XCTAssertEqual(LocalWebhookServer.parse(Data("POST /other HTTP/1.1\r\n\r\n".utf8)), .invalid(404))
        let token = LocalWebhookServer.newToken()
        XCTAssertTrue(token.hasPrefix("aimwh_"))
        XCTAssertTrue(LocalWebhookServer.matches(token, hash: LocalWebhookServer.tokenHash(token)))
        XCTAssertFalse(LocalWebhookServer.matches(token + "x", hash: LocalWebhookServer.tokenHash(token)))
    }

    func testWebhookFiresOverLoopbackOnlyWithTheToken() async throws {
        let recorder = Recorder()
        let port = UInt16.random(in: 48_000...49_000)
        let monitor = TaskTriggerMonitor(debounce: 60, webhookPort: port) { recorder.add(($0, $1, $2)) }
        let token = LocalWebhookServer.newToken()
        let hooked = task(.webhook(tokenSHA256: LocalWebhookServer.tokenHash(token)))
        monitor.update([hooked])
        defer { monitor.stopAll() }
        try await Task.sleep(for: .milliseconds(300))
        func post(_ bearer: String) async throws -> Int {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/aim/tasks/\(hooked.id.uuidString)")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            request.httpBody = Data("deploy finished".utf8)
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        let wrong = try await post("nope")
        XCTAssertEqual(wrong, 401)
        let accepted = try await post(token)
        XCTAssertEqual(accepted, 202)
        let debounced = try await post(token)
        XCTAssertEqual(debounced, 429)
        XCTAssertEqual(recorder.all.count, 1)
        XCTAssertEqual(recorder.all.first?.0, hooked.id)
        XCTAssertEqual(recorder.all.first?.2, "deploy finished")
    }

    func testScriptAndNewMailTriggersFireOnlyOnNewResults() async throws {
        let recorder = Recorder()
        let mail = ScriptOutputs(["10\tAlice\tHello", "10\tAlice\tHello", "9\tBob\tOld", "", "11\tCarol\tNews"])
        let script = ScriptOutputs(["a", "a", "", "b"])
        let mailTask = task(.newMail)
        let scriptTask = task(.scriptResultChanged(source: "return 1", intervalSeconds: 30))
        let monitor = TaskTriggerMonitor(debounce: 0, pollUnit: .milliseconds(1), runScript: { source in
            source.contains("com.apple.mail") ? mail.next() : script.next()
        }) { recorder.add(($0, $1, $2)) }
        monitor.update([mailTask, scriptTask])
        defer { monitor.stopAll() }
        try await Task.sleep(for: .milliseconds(800))
        let mailFires = recorder.all.filter { $0.0 == mailTask.id }
        let scriptFires = recorder.all.filter { $0.0 == scriptTask.id }
        XCTAssertEqual(mailFires.count, 1, "reading or older mail never fires; the first result is the baseline")
        XCTAssertEqual(mailFires.first?.2, "From/subject: Carol — News")
        XCTAssertEqual(scriptFires.count, 1)
        XCTAssertEqual(scriptFires.first?.2, "b")
    }
}
