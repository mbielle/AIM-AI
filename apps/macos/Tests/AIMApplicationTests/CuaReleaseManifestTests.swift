import AIMApplication
import XCTest

final class CuaReleaseManifestTests: XCTestCase {
    private func key(_ build: String, sha: String = "cdhash:aa", contract: String = "c1") -> CuaQualificationKey {
        CuaQualificationKey(driverVersion: "0.28.2", driverSHA256: sha, osBuild: build, adapterContract: contract)
    }

    private var manifest: CuaReleaseManifest {
        CuaReleaseManifest(entries: [
            .init(key: key("26A428"), capabilities: ["observe": "s1", "ax_click": "s1", "bogus": "s1"],
                  qualifiedAt: Date(timeIntervalSince1970: 1_000))
        ])
    }

    func testMatchingIsExactThenSameMajorVersionOnly() {
        let exact = manifest.adoptionRecords(for: key("26A428"))
        XCTAssertEqual(exact.map(\.capability), [.axClick, .observe], "unknown capabilities are ignored")
        XCTAssertTrue(exact[0].evidence.contains("qualified on macOS 26A428."))
        XCTAssertEqual(exact[0].key, key("26A428"))

        let provisional = manifest.adoptionRecords(for: key("26B12"))
        XCTAssertEqual(provisional.count, 2)
        XCTAssertTrue(provisional[0].evidence.contains("provisional on 26B12"))
        XCTAssertEqual(provisional[0].key.osBuild, "26B12", "records are keyed to this Mac's build")

        XCTAssertTrue(manifest.adoptionRecords(for: key("27A100")).isEmpty, "another major macOS version")
        XCTAssertTrue(manifest.adoptionRecords(for: key("26A428", sha: "cdhash:bb")).isEmpty, "another driver binary")
        XCTAssertTrue(manifest.adoptionRecords(for: key("26A428", contract: "c2")).isEmpty, "another adapter contract")
        XCTAssertEqual(CuaReleaseManifest.majorVersion(ofBuild: "26A428"), "26")
    }

    func testPermanentHostAndTestBundlesAdoptTheReleaseForTheSameContract() {
        // The permanent host (":host=") and Test bundles (":app=") run the same driver and contract.
        let host = manifest.adoptionRecords(for: key("26A428", contract: "c1:host=com.aimai.macos.agent-host"))
        XCTAssertEqual(host.map(\.capability), [.axClick, .observe])
        XCTAssertEqual(host[0].key.adapterContract, "c1:host=com.aimai.macos.agent-host", "recorded under the process's own key")
        XCTAssertEqual(manifest.adoptionRecords(for: key("26A428", contract: "c1:app=com.aimai.macos.qualification.x")).count, 2)
        XCTAssertTrue(manifest.adoptionRecords(for: key("26A428", contract: "c2:host=h")).isEmpty)
    }

    func testAdoptionNeverOverridesALocalRecordOrDisqualification() async throws {
        let repository = SQLiteCuaQualificationRepository(database: try AIMDatabase(inMemory: true))
        let mine = key("26B12")
        let adopted = try await repository.adopt(manifest.adoptionRecords(for: mine))
        XCTAssertEqual(adopted, 2)
        let qualified = try await repository.qualified(for: mine)
        XCTAssertEqual(Set(qualified.keys), [.observe, .axClick])

        try await repository.disqualify(.axClick, for: mine, reason: "foreground delivery")
        let again = try await repository.adopt(manifest.adoptionRecords(for: mine))
        XCTAssertEqual(again, 0, "a relaunch does not re-adopt")
        let remaining = try await repository.qualified(for: mine)
        XCTAssertEqual(Set(remaining.keys), [.observe], "the local disqualification stays final")
    }

    func testMergingAndRoundTrip() throws {
        let replacement = CuaReleaseManifest.Entry(key: key("26A428"), capabilities: ["observe": "s2"], qualifiedAt: Date(timeIntervalSince1970: 2_000))
        let other = CuaReleaseManifest.Entry(key: key("26C3"), capabilities: ["scroll": "s3"], qualifiedAt: Date(timeIntervalSince1970: 3_000))
        let merged = manifest.merging(replacement).merging(other)
        XCTAssertEqual(merged.entries.count, 2)
        XCTAssertEqual(merged.entries.first { $0.key.osBuild == "26A428" }?.capabilities, ["observe": "s2"])
        XCTAssertEqual(try CuaReleaseManifest.decode(merged.encoded()), merged)
        // The most recent same-major entry is used for another build.
        XCTAssertEqual(merged.match(for: key("26D1"))?.0.key.osBuild, "26C3")
    }
}
