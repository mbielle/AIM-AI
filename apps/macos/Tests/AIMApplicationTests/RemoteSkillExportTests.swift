import XCTest
import AIMCore
@testable import AIMApplication

final class RemoteSkillExportTests: XCTestCase {
    func testReviewedInstallDisabledVersionedAndReadonlyExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "---\nname: writing\ndescription: Writing guidance\n---\n\nUse clear prose."
        let skill = try NativeSkill(name: "writing", summary: "Writing guidance", origin: "store:author/repo/writing", files: ["SKILL.md": text, "scripts/example.py": "print('not executed')"])
        var disabled = Set<String>()
        let result = try RemoteSkillExport.install(NativeSkillImportContract.installRequest(skill), global: root, disable: { disabled.insert($0) })
        XCTAssertEqual(result.objectValue?["enabled"], .bool(false)); XCTAssertTrue(disabled.contains("writing"))
        let manifest = try NativeSkillImportContract.manifests(RemoteSkillExport.result(NativeSkillImportContract.request(), global: root))
        XCTAssertEqual(manifest.map(\.name), ["writing"])
        let bundle = try NativeSkillImportContract.skill(RemoteSkillExport.result(NativeSkillImportContract.request(name: "writing"), global: root))
        XCTAssertEqual(bundle.files["scripts/example.py"], "print('not executed')"); XCTAssertFalse(bundle.enabled)
        let update = try NativeSkill(name: "writing", summary: "Writing guidance", origin: "x", files: ["SKILL.md": text + "\nNew note."])
        _ = try RemoteSkillExport.install(NativeSkillImportContract.installRequest(update), global: root, disable: { _ in })
        XCTAssertEqual(SkillCatalog.versions(name: "writing", global: root).count, 1)
    }
    func testSymlinkAndSecretFilesNeverExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("writing")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\nname: writing\ndescription: Guidance\n---\n\nInstructions".write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "credential".write(to: folder.appendingPathComponent("AuthKey.p8"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape.md"), withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        let bundle = try NativeSkillImportContract.skill(RemoteSkillExport.result(NativeSkillImportContract.request(name: "writing"), global: root))
        XCTAssertEqual(Set(bundle.files.keys), ["SKILL.md"])
    }
}
