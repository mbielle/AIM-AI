import AIMApplication
import AIMAgentKit
import Foundation
import Darwin

/// Reads only selected XML members. No extraction to disk, macros, links or formulas run.
enum OfficeDocumentReader {
    private static func unzip(_ arguments: [String], limit: Int, staging: ConfinedProcessStaging) throws -> Data {
        let command = ProcessCommand(executable: URL(fileURLWithPath: "/usr/bin/unzip"), arguments: arguments,
            workingDirectory: staging.root, environment: ["LANG": "C"], timeout: .seconds(15), inheritsEnvironment: false)
        let confined = try OSProcessConfinement.prepare(command, readRoots: [staging.root], writeRoots: [staging.home], privateHome: staging.home)
        do { return try ConfinedBinaryProcess.runSynchronously(confined, maximumOutputBytes: limit) }
        catch ConfinedBinaryProcessError.outputLimitExceeded { throw DocumentImportError.textLimit }
        catch ProcessExecutionError.timedOut { throw DocumentImportError.timeLimit }
        catch is CancellationError { throw CancellationError() }
        catch { throw DocumentImportError.invalidOffice }
    }
    static func read(_ url: URL, imageText: ((Data) throws -> String)? = nil) throws -> String {
        let staging = try ConfinedProcessStaging(source: url)
        guard let archive = staging.input else { throw DocumentImportError.invalidOffice }
        let list = try unzip(["-Z1", archive.path], limit: 1_000_000, staging: staging)
        guard let names = String(data: list, encoding: .utf8) else { throw DocumentImportError.invalidOffice }
        let members = names.split(whereSeparator: \.isNewline).map(String.init)
        guard members.count <= 4_000, members.contains("[Content_Types].xml") else { throw DocumentImportError.invalidOffice }
        var total = 0
        func xml(_ name: String) throws -> OfficeXMLNode {
            guard members.contains(name) else { throw DocumentImportError.invalidOffice }
            let data = try unzip(["-p", archive.path, name], limit: 4_000_000, staging: staging)
            total += data.count
            guard total <= 16_000_000 else { throw DocumentImportError.textLimit }
            return try OfficeXMLParser.read(data)
        }
        var result = "Office content snapshot. Formatting may differ; formulas and external links were not executed.\n"
        func append(_ value: String) throws {
            result += value
            guard result.utf8.count <= TextAttachment.maximumFileBytes else { throw DocumentImportError.textLimit }
        }
        switch url.pathExtension.lowercased() {
        case "docx":
            let document = try xml("word/document.xml")
            let body = document.descendants("body").first ?? document
            for node in body.children {
                if node.name == "tbl" {
                    try append("[Table]\n")
                    for row in node.children where row.name == "tr" {
                        let cells = row.children.filter { $0.name == "tc" }.map { cell in
                            cell.descendants("p").map(\.readableText).joined(separator: " / ")
                        }
                        try append(cells.joined(separator: "\t") + "\n")
                    }
                } else if node.name == "p" { try append(node.readableText + "\n") }
                else { for paragraph in node.descendants("p") { try append(paragraph.readableText + "\n") } }
            }
            for name in members.filter({ $0.range(of: "^word/(header|footer)[0-9]+\\.xml$", options: .regularExpression) != nil }).sorted() {
                try append("\n--- \(name) ---\n")
                for paragraph in try xml(name).descendants("p") { try append(paragraph.readableText + "\n") }
            }
        case "pptx":
            let slides = members.filter { $0.range(of: "^ppt/slides/slide[0-9]+\\.xml$", options: .regularExpression) != nil }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            guard !slides.isEmpty else { throw DocumentImportError.invalidOffice }
            for (index, name) in slides.enumerated() {
                try append("\n--- Slide \(index + 1) ---\n")
                for paragraph in try xml(name).descendants("p") { try append(paragraph.readableText + "\n") }
            }
        case "xlsx":
            let shared = members.contains("xl/sharedStrings.xml") ? try xml("xl/sharedStrings.xml").descendants("si").map(\.readableText) : []
            let sheets = members.filter { $0.range(of: "^xl/worksheets/sheet[0-9]+\\.xml$", options: .regularExpression) != nil }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            guard !sheets.isEmpty else { throw DocumentImportError.invalidOffice }
            for name in sheets {
                try append("\n--- \(name) ---\n")
                for row in try xml(name).descendants("row") {
                    var cells: [String] = []
                    for cell in row.descendants("c") {
                        let raw = cell.descendants("v").first?.text ?? ""
                        let value: String
                        switch cell.attributes["t"] {
                        case "s":
                            guard let index = Int(raw), shared.indices.contains(index) else { throw DocumentImportError.invalidOffice }
                            value = shared[index]
                        case "inlineStr": value = cell.readableText
                        case "b": value = raw == "1" ? "true" : "false"
                        default: value = raw
                        }
                        let formula = cell.descendants("f").first?.text
                        cells.append((cell.attributes["r"] ?? "?") + ": " + value + (formula.map { " [formula: \($0)]" } ?? ""))
                    }
                    try append(cells.joined(separator: "\t") + "\n")
                }
            }
        default: throw DocumentImportError.invalidOffice
        }
        let extraXML = members.filter {
            $0.range(of: "^(word|ppt|xl)/charts/chart[0-9]+\\.xml$", options: .regularExpression) != nil ||
            $0.range(of: "^ppt/notesSlides/notesSlide[0-9]+\\.xml$", options: .regularExpression) != nil
        }.sorted()
        for name in extraXML {
            let tree = try xml(name)
            try append("\n--- " + name + " (stored text/cached chart values, source not refreshed) ---\n")
            let texts = tree.descendants("p").map(\.readableText)
            let values = tree.descendants("v").map(\.text)
            try append((texts + values).filter { !$0.isEmpty }.joined(separator: "\n") + "\n")
        }
        if let imageText {
            let images = members.filter {
                $0.range(of: "^(word|ppt|xl)/media/[a-zA-Z0-9_-]+\\.(png|jpg|jpeg|tif|tiff|bmp)$", options: .regularExpression) != nil
            }.sorted()
            guard images.count <= 32 else { throw DocumentImportError.sourceLimit }
            for name in images {
                let bytes = try unzip(["-p", archive.path, name], limit: 6_000_000, staging: staging)
                total += bytes.count
                guard total <= 16_000_000 else { throw DocumentImportError.sourceLimit }
                let text = try imageText(bytes)
                try append("\n--- Embedded image " + name + " (local OCR, not visual understanding) ---\n" +
                           (text.isEmpty ? "[No recognized text]" : text) + "\n")
            }
        }
        guard result.split(whereSeparator: \.isNewline).count > 1 else { throw DocumentImportError.noText }
        return result
    }
}

private final class OfficeXMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [OfficeXMLNode] = []
    init(_ name: String, attributes: [String: String] = [:]) { self.name = name; self.attributes = attributes }
    func descendants(_ name: String) -> [OfficeXMLNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }
    var readableText: String {
        if name == "t" { return text }
        if name == "tab" { return "\t" }
        if name == "br" || name == "cr" { return "\n" }
        return children.map(\.readableText).joined()
    }
}
private final class OfficeXMLParser: NSObject, XMLParserDelegate {
    let root = OfficeXMLNode("root")
    var stack: [OfficeXMLNode] = []
    var count = 0
    static func read(_ data: Data) throws -> OfficeXMLNode {
        guard !String(decoding: data, as: UTF8.self).uppercased().contains("<!DOCTYPE") else { throw DocumentImportError.invalidOffice }
        let delegate = OfficeXMLParser(), parser = XMLParser(data: data)
        delegate.stack = [delegate.root]; parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw DocumentImportError.invalidOffice }
        return delegate.root
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        count += 1
        guard count <= 100_000, stack.count < 128 else { parser.abortParsing(); return }
        let node = OfficeXMLNode(elementName.split(separator: ":").last.map(String.init) ?? elementName, attributes: attributeDict)
        stack.last?.children.append(node); stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if stack.count > 1 { stack.removeLast() } }
}
