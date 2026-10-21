import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AIMCore

final class Round23EvidenceTests: XCTestCase {
    func testLongVideoDoesNotSilentlyReduceRequestedSampling() throws {
        XCTAssertEqual(try VideoPreparationService.sampleCount(duration: 200, mode: .automatic), 201)
        XCTAssertEqual(try VideoPreparationService.sampleCount(duration: 60, mode: .detailed), 241)
        XCTAssertThrowsError(try VideoPreparationService.sampleCount(duration: 65, mode: .detailed))
        XCTAssertThrowsError(try VideoPreparationService.sampleCount(duration: 256, mode: .automatic))
        XCTAssertThrowsError(try VideoPreparationService.sampleCount(duration: .infinity, mode: .automatic))
    }
    func testDetailPagesPreserveOrderAndRedactBeforeSlicing() throws {
        let source = String(repeating: "A", count: 16_370) + #"{"api_key":"hidden-value-crossing-page"}"# + String(repeating: "B", count: 20_000)
        var offset = 0, joined = ""
        repeat {
            let page = try XCTUnwrap(ConversationAction.detailPage(source, offset: offset)?.objectValue)
            joined += try XCTUnwrap(page["output"]?.stringValue)
            guard let next = page["next_offset"]?.numberValue else { break }
            XCTAssertGreaterThan(Int(next), offset); offset = Int(next)
        } while true
        XCTAssertEqual(joined, ConversationAction.redact(source, limit: 1_000_000))
        XCTAssertFalse(joined.contains("hidden-value"))
        XCTAssertNil(ConversationAction.detailPage(source, offset: -1))
        XCTAssertNil(ConversationAction.detailPage(source, offset: 999_999))
        XCTAssertFalse(ConversationAction.redact(#"{"api_key":""# + String(repeating: "secret", count: 5000)).contains("secretsecret"))
    }
    func testPreparedPreviewIsBoundedAndValidatedWithoutReencoding() throws {
        let prepared = try XCTUnwrap(InputMediaPreview.jpeg(try jpeg()))
        XCTAssertEqual(InputMediaPreview.validatedJPEG(prepared), prepared)
        XCTAssertNil(InputMediaPreview.validatedJPEG(Data(repeating: 0, count: 300_000)))
        XCTAssertNil(InputMediaPreview.validatedJPEG(Data("invalid".utf8)))
    }
    private func jpeg() throws -> Data {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return data as Data
    }
    private func video(frames: Int = 12) throws -> NativeChatAttachment {
        let bytes = try jpeg()
        let video = PreparedVideoAttachment(name: "clip.mov", duration: 12, rangeStart: 0, rangeEnd: 12, mode: .automatic,
            originDeviceID: "source-device", originDeviceName: "Source iPhone", frames: (0..<frames).map { .init(seconds: Double($0), jpeg: bytes) }, transcript: "Local transcript", audioNotice: nil)
        return .init(id: video.id, name: video.name, kind: .document, mimeType: PreparedInputTransfer.mimeType, text: video.context, video: video)
    }
    func testPreparedVideoIsOneAttachmentAndAllFramesReachEachProvider() throws {
        let input = try video()
        try NativeChatAttachment.validate([input])
        XCTAssertEqual(try PreparedInputTransfer.decode(PreparedInputTransfer.encode(input)), input)
        XCTAssertEqual(input.visualImages.count, 12)
        for provider in [ChatProvider.openRouter, .openAI, .anthropic, .google] {
            let request = try NativeChatTransport.request(provider: provider, modelID: "vision", messages: [.init(role: .user, text: "", attachments: [input])], key: "fixture", catalogMaximum: 8192)
            let json = try XCTUnwrap(request.httpBody)
            let source = String(decoding: json, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
            XCTAssertEqual(source.components(separatedBy: try jpeg().base64EncodedString()).count - 1, 12, provider.rawValue)
            XCTAssertTrue(source.contains("Local transcript")); XCTAssertFalse(source.contains("file://"))
        }
    }
    func testPreparedVideoRejectsForeignIdentityAndInvalidChronology() throws {
        var input = try video()
        input.id = UUID(); XCTAssertThrowsError(try PreparedInputTransfer.encode(input))
        input.id = input.video!.id; input.video!.frames.reverse()
        XCTAssertThrowsError(try PreparedInputTransfer.encode(input))
        input.video!.frames.reverse(); input.video!.frames.append(.init(seconds: 100, jpeg: try jpeg()))
        XCTAssertThrowsError(try PreparedInputTransfer.encode(input))
        XCTAssertThrowsError(try PreparedInputTransfer.decode(Data(repeating: 0, count: RemoteAttachmentRules.maximumSize + 1)))
    }
    func testOldHistoriesRemainNeutralAndVisualReportSurvivesMerge() throws {
        let input = try video(), userID = UUID(), conversationID = UUID()
        let report = VisualAnalysisReport(sourceIDs: [input.id], choice: .init(provider: .openRouter, modelID: "visual"), text: "0 s: observed screen")
        let user = NativeChatMessage(id: userID, role: .user, text: "inspect", attachments: [input], visualReport: report)
        let old = NativeChatMessage(id: userID, role: .user, text: "inspect renamed")
        let a = NativeChatConversation(id: conversationID, title: "A", provider: .deepSeek, modelID: "primary", messages: [user])
        let b = NativeChatConversation(id: conversationID, title: "B", provider: .deepSeek, modelID: "primary", messages: [old], updatedAt: .distantFuture)
        for value in [a.merging(b), b.merging(a)] {
            XCTAssertEqual(value.messages[0].visualReport, report)
            let prepared = VisualAnalysisService.primaryHistory(value.messages)
            XCTAssertTrue(prepared[0].attachments?.isEmpty == true)
            XCTAssertTrue(prepared[0].text.contains(report.text))
            _ = try NativeChatTransport.request(provider: .deepSeek, modelID: "primary", messages: prepared, key: "fixture")
        }
        XCTAssertNil(try JSONDecoder().decode(NativeChatMessage.self, from: JSONEncoder().encode(old)).actions)
    }
    func testActionMergeDoesNotDowngradeOrCrossConversationAndRedactsSecrets() throws {
        let id = UUID(), turn = UUID(), start = Date(timeIntervalSince1970: 100)
        let pending = ConversationAction(id: "stable", conversationID: id, turnID: turn, ordinal: 0, name: "command", state: .running, startedAt: start)
        var done = pending; done.state = .completed; done.finishedAt = start.addingTimeInterval(2)
        done.detail = "Authorization: Bearer secret-value api_key=credential password=hidden sk-abcdefghijklmnopqrst"
        var foreign = done; foreign.conversationID = UUID(); foreign.name = "foreign"
        for values in [ConversationAction.merge([pending], [done]), ConversationAction.merge([done], [pending, foreign])] {
            let action = try XCTUnwrap(values?.first)
            XCTAssertEqual(action.state, .completed); XCTAssertEqual(action.duration, 2); XCTAssertEqual(action.name, "command")
            for secret in ["secret-value", "credential", "hidden", "sk-abcdefghijklmnopqrst"] { XCTAssertFalse(action.detail!.contains(secret)) }
        }
    }
    func testActivityRedactsJSONAndQuotedSecrets() {
        let source = #"{"api_key":"json secret with spaces","password":"escaped \" value","refresh_token":"refresh-value","client_secret":"client-value","path":"safe.swift"} secret='single quoted secret' sk-abcdefghijklmnop"#
        let safe = ConversationAction.redact(source)
        for secret in ["json secret", "escaped", "refresh-value", "client-value", "single quoted", "sk-abcdefghijklmnop"] { XCTAssertFalse(safe.contains(secret), safe) }
        XCTAssertTrue(safe.contains("safe.swift")); XCTAssertTrue(safe.contains("[redacted]"))
    }
    func testVisualConsentIsScopedAndRevocableAndPreferencesDecodeOlderPayload() throws {
        let suite = "round23-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = UUID(), choice = SubagentModelChoice(provider: .openRouter, modelID: "visual")
        var value = SubagentPreferences(); value.visual = choice; value.permanentVisualConsents.insert(choice)
        try SubagentPreferenceStore.save(value, accountID: account, target: "mac:A", defaults: defaults)
        XCTAssertEqual(SubagentPreferenceStore.load(accountID: account, target: "mac:A", defaults: defaults), value)
        XCTAssertTrue(SubagentPreferenceStore.load(accountID: UUID(), target: "mac:A", defaults: defaults).permanentVisualConsents.isEmpty)
        XCTAssertTrue(SubagentPreferenceStore.load(accountID: account, target: "mac:B", defaults: defaults).permanentVisualConsents.isEmpty)
        value.permanentVisualConsents.remove(choice); try SubagentPreferenceStore.save(value, accountID: account, target: "mac:A", defaults: defaults)
        XCTAssertTrue(SubagentPreferenceStore.load(accountID: account, target: "mac:A", defaults: defaults).permanentVisualConsents.isEmpty)
        XCTAssertNil(try JSONDecoder().decode(AccountChatPreferences.self, from: Data(#"{"responseStyle":"balanced","responseLanguage":""}"#.utf8)).subagentDefaults)
    }
    func testProvidedVideoActuallyDecodesChronologicalFrames() async throws {
        guard let path = ProcessInfo.processInfo.environment["AIM_VIDEO_FIXTURE"] else { throw XCTSkip("Run with the supplied physical screen recording to qualify decoding.") }
        let video = try await VideoPreparationService.prepare(URL(fileURLWithPath: path), mode: .detailed, originDeviceID: "fixture", originDeviceName: "Fixture")
        try video.validate(); XCTAssertGreaterThan(video.frames.count, 4)
        XCTAssertEqual(video.frames.map(\.seconds), video.frames.map(\.seconds).sorted())
        XCTAssertGreaterThan(video.frames.last!.seconds, video.duration * 0.9)
        XCTAssertTrue(video.frames.allSatisfy { CGImageSourceCreateWithData($0.jpeg as CFData, nil) != nil })
        XCTAssertNotNil(video.audioNotice)
    }
}

private actor VisualBatchEvidence {
    var messages: [NativeChatMessage] = []
    var admitted: [UUID] = []
    var observed: [UUID] = []
    func append(_ message: NativeChatMessage) { messages.append(message) }
    func admit(_ id: UUID) { admitted.append(id) }
    func finish(_ id: UUID) { observed.append(id) }
    func values() -> ([NativeChatMessage], [UUID], [UUID]) { (messages, admitted, observed) }
}

extension Round23EvidenceTests {
    func testVisualAnalysisAdmitsEveryBatchAndSynthesizesWithoutLosingFrames() async throws {
        let input = try video(), evidence = VisualBatchEvidence()
        let model = ChatModel(id: "fixture/vision", name: "Visual fixture", inputModalities: ["text", "image"], maxOutputTokens: 8192)
        let report = try await VisualAnalysisService.analyse([input], choice: .init(provider: .openRouter, modelID: model.id), model: model, key: "fixture",
            streamFactory: { message, _ in AsyncThrowingStream { stream in
                let task = Task { await evidence.append(message); stream.yield(.init(text: "Observed fixture with timestamps and sampling limits.", usage: .init(inputTokens: 10, outputTokens: 5), isComplete: true)); stream.finish() }
                stream.onTermination = { _ in task.cancel() }
            } }, checkBudget: { await evidence.admit($0) }, observed: { id, _ in await evidence.finish(id) })
        let (messages, admitted, observed) = await evidence.values()
        XCTAssertEqual(messages.count, 4); XCTAssertEqual(admitted, observed)
        XCTAssertEqual(messages.flatMap { $0.attachments ?? [] }.map(\.id), input.visualImages.map(\.id))
        XCTAssertEqual(messages.dropLast().map { $0.attachments?.count }, [4, 4, 4])
        XCTAssertTrue(messages.last?.attachments == nil)
        XCTAssertEqual(report.sourceIDs, [input.id]); XCTAssertTrue(report.text.contains("Segment observations"))
    }
    func testIncompleteVisualAnalysisIsNotGivenToThePrimaryModel() async throws {
        let input = try video(frames: 2), evidence = VisualBatchEvidence()
        let model = ChatModel(id: "fixture/vision", name: "Visual fixture", inputModalities: ["text", "image"])
        do {
            _ = try await VisualAnalysisService.analyse([input], choice: .init(provider: .openRouter, modelID: model.id), model: model, key: "fixture",
                streamFactory: { _, _ in AsyncThrowingStream { $0.yield(.init(text: "Partial observation")); $0.finish() } }, observed: { id, _ in await evidence.finish(id) })
            XCTFail("Partial visual evidence was accepted as complete")
        } catch ChatServiceError.incompleteResponse {}
        let (_, _, observed) = await evidence.values(); XCTAssertTrue(observed.isEmpty)
    }
    func testVisualBudgetRefusalPreventsAnyProviderCall() async throws {
        let input = try video(), evidence = VisualBatchEvidence()
        let model = ChatModel(id: "fixture/vision", name: "Visual fixture", inputModalities: ["text", "image"])
        do {
            _ = try await VisualAnalysisService.analyse([input], choice: .init(provider: .openRouter, modelID: model.id), model: model, key: "fixture",
                streamFactory: { message, _ in AsyncThrowingStream { stream in Task { await evidence.append(message); stream.finish() } } }, checkBudget: { _ in throw NativeDocumentError.limit })
            XCTFail("Budget refused but analysis started")
        } catch NativeDocumentError.limit {}
        let (messages, _, _) = await evidence.values(); XCTAssertTrue(messages.isEmpty)
    }
}
