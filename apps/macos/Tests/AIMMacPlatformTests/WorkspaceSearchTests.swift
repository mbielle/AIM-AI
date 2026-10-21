import AIMMacPlatform
import AIMAgentKit
import XCTest

final class WorkspaceSearchTests: XCTestCase {
    func testLineRangeReadAndScopedCaseSensitiveSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-search-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("first\nNeedle here\nneedle again\nfourth".utf8).write(to: root.appendingPathComponent("Sources/Main.swift"))
        try Data("Needle in notes".utf8).write(to: root.appendingPathComponent("notes.txt"))
        let service = WorkspaceFileToolService()
        let read = await service.execute(ToolRequest(name: "read_file",
            arguments: ["path": "Sources/Main.swift", "start_line": "2", "end_line": "3"],
            risk: .readOnly, workspacePath: root.path))
        XCTAssertFalse(read.isError)
        XCTAssertEqual(read.content, "2: Needle here\n3: needle again\n")
        let full = await service.execute(ToolRequest(name: "read_file", arguments: ["path": "Sources/Main.swift"],
                                                     risk: .readOnly, workspacePath: root.path))
        XCTAssertTrue(full.content.hasPrefix("first\nNeedle"))
        let scoped = try await service.searchText("Needle", workspace: root.path,
                                                  filePattern: "Sources/**/*.swift", caseSensitive: true)
        XCTAssertEqual(scoped.matches.map(\.line), [2])
        XCTAssertEqual(scoped.matches.map(\.path), ["Sources/Main.swift"])
        let insensitive = try await service.searchText("Needle", workspace: root.path, filePattern: "*.swift")
        XCTAssertEqual(insensitive.matches.map(\.line), [2, 3])
        let tool = await service.execute(ToolRequest(name: "search_files",
            arguments: ["query": "Needle", "file_pattern": "Sources/**/*.swift", "case_sensitive": "true"],
            risk: .readOnly, workspacePath: root.path))
        XCTAssertEqual(tool.content, "Sources/Main.swift:2:Needle here")
        XCTAssertFalse(tool.isError)
        XCTAssertTrue(WorkspaceToolRegistry.fileTools().contains {
            $0.name == "read_file" && $0.optionalArguments == ["start_line", "end_line"]
        })
    }

    func testLineRangeCanReadPastTheWholeFilePreviewLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-large-read-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = String(repeating: "x", count: 1_100_000) + "\nimportant target\n"
        try Data(source.utf8).write(to: root.appendingPathComponent("large.txt"))
        let service = WorkspaceFileToolService()
        let full = await service.execute(ToolRequest(name: "read_file", arguments: ["path": "large.txt"],
                                                     risk: .readOnly, workspacePath: root.path))
        XCTAssertTrue(full.isError)
        let ranged = await service.execute(ToolRequest(name: "read_file",
            arguments: ["path": "large.txt", "start_line": "2", "end_line": "2"],
            risk: .readOnly, workspacePath: root.path))
        XCTAssertFalse(ranged.isError)
        XCTAssertEqual(ranged.content, "2: important target\n")
        let oversizedLine = await service.execute(ToolRequest(name: "read_file",
            arguments: ["path": "large.txt", "start_line": "1", "end_line": "1"],
            risk: .readOnly, workspacePath: root.path))
        XCTAssertFalse(oversizedLine.isError)
        XCTAssertTrue(oversizedLine.content.contains("exceeds the preview limit"))
        XCTAssertLessThan(oversizedLine.content.utf8.count, 1_000)
    }

    func testInvalidRangesPatternsAndSearchOptionsFailWithoutReadingOutsideWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-search-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("safe".utf8).write(to: root.appendingPathComponent("safe.txt"))
        let service = WorkspaceFileToolService()
        for arguments in [
            ["path": "safe.txt", "start_line": "0"],
            ["path": "safe.txt", "start_line": "2", "end_line": "1"],
            ["path": "safe.txt", "end_line": "not-a-number"],
            ["path": "../outside.txt", "start_line": "1"]
        ] {
            let result = await service.execute(ToolRequest(name: "read_file", arguments: arguments,
                                                           risk: .readOnly, workspacePath: root.path))
            XCTAssertTrue(result.isError, "\(arguments)")
        }
        for arguments in [
            ["query": "safe", "file_pattern": "../*.txt"],
            ["query": "safe", "case_sensitive": "yes"],
            ["query": String(repeating: "x", count: 513)]
        ] {
            let result = await service.execute(ToolRequest(name: "search_files", arguments: arguments,
                                                           risk: .readOnly, workspacePath: root.path))
            XCTAssertTrue(result.isError)
        }
    }

    func testSearchFindsLinesButSkipsBinaryHiddenDependenciesAndSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("first\nNeedle here\nlast".utf8).write(to: root.appendingPathComponent("source.txt"))
        try Data("needle".utf8).write(to: root.appendingPathComponent(".secret"))
        try Data("needle\0binary".utf8).write(to: root.appendingPathComponent("binary"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try Data("needle".utf8).write(to: root.appendingPathComponent("node_modules/dependency"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.txt"), withDestinationURL: root.appendingPathComponent("source.txt"))
        let result = try await WorkspaceFileToolService().searchText("needle", workspace: root.path)
        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.matches.first?.path, "source.txt")
        XCTAssertEqual(result.matches.first?.line, 2)
        XCTAssertEqual(result.matches.first?.excerpt, "Needle here")
        XCTAssertFalse(result.isTruncated)
        let entries = try await WorkspaceFileToolService().entries(workspace: root.path)
        XCTAssertEqual(entries.first(where: { $0.name == "source.txt" })?.path, "source.txt")
        XCTAssertEqual(Set(entries.map(\.path)).count, entries.count)
    }

    func testBoundedSearchReportsPartialResultsAndToolSharesBehavior() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(String(repeating: "match\n", count: 201).utf8).write(to: root.appendingPathComponent("many.txt"))
        let service = WorkspaceFileToolService()
        let partial = try await service.searchText("match", workspace: root.path, maximumMatches: 2)
        XCTAssertEqual(partial.matches.count, 2)
        XCTAssertTrue(partial.isTruncated)
        let tool = await service.execute(ToolRequest(name: "search_files", arguments: ["query": "match"], risk: .readOnly, workspacePath: root.path))
        XCTAssertFalse(tool.isError)
        XCTAssertTrue(tool.content.contains("results are incomplete"))
        XCTAssertTrue(tool.content.contains("many.txt:1:match"))
        do { _ = try await service.searchText("", workspace: root.path); XCTFail() } catch {}
    }

    func testFilePatternSearchFindsNamesAndPathsWithoutEscapingWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/Views"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Main.swift", "Sources/App.swift", "Sources/Views/ChatView.swift", "Sources/Views/chatview2.swift", ".hidden.swift", "node_modules/Mock.swift"] {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.swift"), withDestinationURL: root.appendingPathComponent("Main.swift"))
        let service = WorkspaceFileToolService()
        let allSwift = try await service.findFiles(matching: "*.swift", workspace: root.path)
        XCTAssertEqual(Set(allSwift.matches.map(\.path)), ["Main.swift", "Sources/App.swift", "Sources/Views/ChatView.swift", "Sources/Views/chatview2.swift"])
        XCTAssertFalse(allSwift.isTruncated)
        let views = try await service.findFiles(matching: "Sources/Views/*View.swift", workspace: root.path)
        XCTAssertEqual(views.matches.map(\.path), ["Sources/Views/ChatView.swift"])
        let tool = await service.execute(ToolRequest(name: "find_files", arguments: ["pattern": "Sources/Views/*View.swift"], risk: .readOnly, workspacePath: root.path))
        XCTAssertEqual(tool.content, "Sources/Views/ChatView.swift")
        XCTAssertFalse(tool.isError)
        XCTAssertTrue(WorkspaceToolRegistry.fileTools().contains { $0.name == "find_files" && $0.risk == .readOnly })
        let partial = try await service.findFiles(matching: "*.swift", workspace: root.path, maximumMatches: 1)
        XCTAssertEqual(partial.matches.count, 1)
        XCTAssertTrue(partial.isTruncated)
        do { _ = try await service.findFiles(matching: "", workspace: root.path); XCTFail() } catch {}
    }

    func testGlobstarAndBracketClassesMatchRelativePathsAtEveryDepth() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-glob-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Root.swift", "Sources/App.swift", "Sources/é.swift", "Sources/Views/ChatView.swift",
                     "Sources/Views/CodeView.swift", "Sources/Views/Detail/Panel1.swift",
                     "Tests/ChatView.swift"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
        }
        let service = WorkspaceFileToolService()
        let allSwift = try await service.findFiles(matching: "**/*.swift", workspace: root.path)
        XCTAssertEqual(allSwift.matches.count, 7)
        let sources = try await service.findFiles(matching: "Sources/**/*.swift", workspace: root.path)
        XCTAssertEqual(Set(sources.matches.map(\.path)), ["Sources/App.swift", "Sources/é.swift", "Sources/Views/ChatView.swift",
                                                        "Sources/Views/CodeView.swift", "Sources/Views/Detail/Panel1.swift"])
        let unicode = try await service.findFiles(matching: "Sources/?.swift", workspace: root.path)
        XCTAssertEqual(unicode.matches.map(\.path), ["Sources/é.swift"])
        let direct = try await service.findFiles(matching: "Sources/*/[C][a-o]??View.swift", workspace: root.path)
        XCTAssertEqual(direct.matches.map(\.path), ["Sources/Views/ChatView.swift", "Sources/Views/CodeView.swift"])
        let deep = try await service.findFiles(matching: "Sources/**/Panel[0-9].swift", workspace: root.path)
        XCTAssertEqual(deep.matches.map(\.path), ["Sources/Views/Detail/Panel1.swift"])
        let shallow = try await service.findFiles(matching: "Sources/*/*.swift", workspace: root.path)
        XCTAssertEqual(Set(shallow.matches.map(\.path)), ["Sources/Views/ChatView.swift", "Sources/Views/CodeView.swift"])
        for invalid in ["../*.swift", "/Sources/*.swift", "Sources//*.swift", "Sources/./*.swift"] {
            do { _ = try await service.findFiles(matching: invalid, workspace: root.path); XCTFail(invalid) } catch {}
        }
    }
}
