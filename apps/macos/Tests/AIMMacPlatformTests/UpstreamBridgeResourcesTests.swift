import AIMAgentKit
@testable import AIMMacPlatform
import XCTest

final class UpstreamBridgeResourcesTests: XCTestCase {
    func testCurrentBundleBridgesOverrideImmutableInstalledCopyWithoutWritingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-bridge-resources-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("installed")
        let bundled = root.appendingPathComponent("Resources/AgentBridges/hermes")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        let old = installed.appendingPathComponent("aim_hermes_bridge.py")
        try Data("old immutable shim".utf8).write(to: old)
        try Data("current bundle shim".utf8).write(to: bundled.appendingPathComponent("aim_hermes_bridge.py"))
        let resolved = try UpstreamAgentInstaller.activeBridgeDirectory(engine: .hermes, installed: installed,
            resources: root.appendingPathComponent("Resources"))
        XCTAssertEqual(resolved, bundled)
        XCTAssertEqual(try Data(contentsOf: old), Data("old immutable shim".utf8))
    }

    func testIncompleteOrSymlinkedBundleFailsClosedRatherThanRunningStaleShim() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-bridge-invalid-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Resources")
        let bundled = resources.appendingPathComponent("AgentBridges/openclaw")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        XCTAssertThrowsError(try UpstreamAgentInstaller.activeBridgeDirectory(engine: .openClaw, installed: root, resources: resources))
        for name in ["aim_openclaw_bridge.mjs", "aim_openclaw_preload.mjs", "aim_openclaw_plugin.mjs"] {
            try Data("fixture".utf8).write(to: bundled.appendingPathComponent(name))
        }
        let plugin = bundled.appendingPathComponent("aim_openclaw_plugin.mjs")
        try FileManager.default.removeItem(at: plugin)
        try FileManager.default.createSymbolicLink(at: plugin, withDestinationURL: bundled.appendingPathComponent("aim_openclaw_bridge.mjs"))
        XCTAssertThrowsError(try UpstreamAgentInstaller.activeBridgeDirectory(engine: .openClaw, installed: root, resources: resources))
    }
}
