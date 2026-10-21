import AIMAgentKit
import AIMMacPlatform
import SwiftUI

struct WorkspaceSearchView: View {
    private enum SearchKind: String, CaseIterable { case content = "Text in files", filename = "File names" }
    @Environment(\.dismiss) private var dismiss
    let workspace: String
    let openFile: (WorkspaceEntry) -> Void
    @State private var query = ""
    @State private var filePattern = ""
    @State private var caseSensitive = false
    @State private var kind: SearchKind = .content
    @State private var searchedQuery = ""
    @State private var result: WorkspaceSearchResult?
    @State private var running = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var previewTask: Task<Void, Never>?
    @State private var selected: WorkspaceSearchMatch?
    @State private var preview = ""
    private let files = WorkspaceFileToolService()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Search workspace").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Search", selection: $kind) {
                ForEach(SearchKind.allCases, id: \.self) { item in Text(item.rawValue).tag(item) }
            }.pickerStyle(.segmented)
            HStack {
                TextField(kind == .content ? "Find text in files" : "Pattern, such as *.swift or Sources/**/*.swift", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                if running { Button("Stop") { task?.cancel(); running = false } }
                else { Button("Search") { search() }.disabled(query.isEmpty) }
            }
            if kind == .content {
                HStack(spacing: 12) {
                    TextField("Limit to files (optional), e.g. Sources/**/*.swift", text: $filePattern)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { search() }
                    Toggle("Match case", isOn: $caseSensitive)
                        .fixedSize()
                }
            }
            Text(kind == .content
                 ? "Local only · Literal text, optionally case-sensitive and file-scoped · UTF-8 files up to 1 MB · Hidden files, symlinks and common build/dependency folders excluded · No data sent to AI"
                 : "Local only · *, ? and [abc] match names; ** spans folders · Case-sensitive · Hidden files, symlinks and common build/dependency folders excluded · No data sent to AI")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            if let result {
                Text("\(result.matches.count) matches for “\(searchedQuery)”\(result.isTruncated ? " · Results incomplete — narrow your query" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HSplitView {
                List(result?.matches ?? []) { match in
                    Button { select(match) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(match.line > 0 ? "\(match.path):\(match.line)" : match.path)
                                .font(.system(size: 12, weight: .medium)).lineLimit(1)
                            if match.line > 0 {
                                Text(match.excerpt).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.listStyle(.plain).frame(minWidth: 250)
                VStack(alignment: .leading, spacing: 12) {
                    if let selected {
                        HStack {
                            Text(selected.line > 0 ? "Line \(selected.line)" : "File preview").font(.caption)
                            Spacer()
                            Button("Open full file") {
                                openFile(WorkspaceEntry(path: selected.path, name: (selected.path as NSString).lastPathComponent, isDirectory: false))
                                dismiss()
                            }
                        }
                        ScrollView([.horizontal, .vertical]) {
                            Text(preview).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        Text("Current file contents; line numbers may change if the file was edited after searching.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text(running ? "Searching…" : "Select a match to see nearby lines.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.padding(12).frame(minWidth: 300)
            }
        }.padding(22).frame(width: 850, height: 540)
            .onChange(of: kind) { _, _ in
                task?.cancel(); previewTask?.cancel(); result = nil; selected = nil; preview = ""; error = nil; running = false
            }
            .onDisappear { task?.cancel(); previewTask?.cancel() }
    }

    private func search() {
        guard !query.isEmpty else { return }
        task?.cancel(); previewTask?.cancel()
        let text = query
        let selectedKind = kind
        let pattern = filePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingCase = caseSensitive
        searchedQuery = text; result = nil; selected = nil; preview = ""; error = nil; running = true
        task = Task {
            do {
                let found = try await (selectedKind == .content
                    ? files.searchText(text, workspace: workspace, filePattern: pattern.isEmpty ? nil : pattern, caseSensitive: matchingCase)
                    : files.findFiles(matching: text, workspace: workspace))
                guard !Task.isCancelled else { return }
                result = found; running = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription; running = false
            }
        }
    }

    private func select(_ match: WorkspaceSearchMatch) {
        previewTask?.cancel(); selected = match; preview = "Loading…"
        previewTask = Task {
            let start = match.line > 0 ? max(1, match.line - 12) : 1
            let end = match.line > 0 ? match.line + 12 : 24
            let value = await files.execute(ToolRequest(name: "read_file",
                arguments: ["path": match.path, "start_line": String(start), "end_line": String(end)],
                risk: .readOnly, workspacePath: workspace))
            guard !Task.isCancelled else { return }
            if value.isError { preview = value.content; return }
            preview = value.content.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in "\(match.line > 0 && line.hasPrefix("\(match.line): ") ? "→ " : "  ")\(line)" }
                .joined(separator: "\n")
        }
    }
}
