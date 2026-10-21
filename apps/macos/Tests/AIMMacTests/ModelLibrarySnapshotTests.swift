import AppKit
import SwiftUI
import AIMApplication
import XCTest
@testable import AIMMac

/// An offscreen component render: never opens or controls the owner's app.
@MainActor
final class ModelLibrarySnapshotTests: XCTestCase {
    func testFirstLibraryWithoutProviderRendersInBothAppearances() async throws {
        guard let directory = ProcessInfo.processInfo.environment["AIM_LIBRARY_SNAPSHOT_DIRECTORY"] else {
            throw XCTSkip("Set a private output directory to render the library component")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, appearance) in [("light", ColorScheme.light), ("dark", .dark)] {
            let model = AppModel(database: try AIMDatabase(inMemory: true))
            XCTAssertTrue(model.connectedProviders.isEmpty)
            let host = NSHostingView(rootView: ModelPickerView().environment(model).environment(\.colorScheme, appearance)
                .background(appearance == .dark ? AIMTheme.sidebar(appearance) : .white))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
            // Give the view's metadata/cache-only task a chance to finish.
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 1_000)
            try png.write(to: output.appendingPathComponent("model-library-empty-\(name).png"))
            window.close()
            XCTAssertFalse(model.isSending)
            XCTAssertTrue(model.connectedProviders.isEmpty)
        }
    }
}
