import AIMApplication
import Foundation
import PDFKit
import AppKit
import ImageIO
import Vision

public enum DocumentImportError: LocalizedError {
    case invalidPDF, invalidOffice, invalidImage, lockedPDF, copyingDenied, noText, sourceLimit, pageLimit, textLimit, timeLimit
    public var errorDescription: String? {
        switch self {
        case .invalidPDF: "This file could not be read as a PDF."
        case .invalidOffice: "This Office document could not be read. Use an unencrypted DOCX, PPTX or XLSX copy."
        case .invalidImage: "This image could not be decoded for local text recognition."
        case .lockedPDF: "This PDF is password-locked. Unlock a copy before attaching it."
        case .copyingDenied: "This PDF does not allow copying its text."
        case .noText: "No readable text was found, including local text recognition."
        case .sourceLimit: "Choose a regular document or image up to 20 MB."
        case .pageLimit: "This PDF exceeds the 2,000-page import limit. Attach a smaller excerpt."
        case .textLimit: "The extracted document text exceeds 4 MB. Attach a smaller excerpt; nothing was silently truncated."
        case .timeLimit: "PDF extraction took too long. Try a smaller excerpt."
        }
    }
}

public enum DocumentTextImporter {
    /// Returns a local text snapshot; never uploads, follows links, or executes document content.
    public static func read(_ url: URL) throws -> TextAttachment {
        let format = url.pathExtension.lowercased()
        guard ["pdf", "docx", "pptx", "xlsx", "png", "jpg", "jpeg", "tiff", "tif", "heic", "webp"].contains(format) else { return try TextAttachment.read(url) }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw DocumentImportError.sourceLimit }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 20_000_001) ?? Data()
        guard data.count <= 20_000_000 else { throw DocumentImportError.sourceLimit }
        try Task.checkCancellation()
        if ["docx", "pptx", "xlsx"].contains(format) {
            let attachment = TextAttachment(name: url.lastPathComponent, content: try OfficeDocumentReader.read(url, imageText: recognizeImageData))
            try TextAttachment.validate([attachment]); return attachment
        }
        if format != "pdf" {
            let text = try recognizeImageData(data)
            guard !text.isEmpty else { throw DocumentImportError.noText }
            let attachment = TextAttachment(name: url.lastPathComponent, content: "Local image OCR. Recognition can be imperfect; visual layout is not preserved.\n" + text)
            try TextAttachment.validate([attachment]); return attachment
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        guard let document = PDFDocument(data: data) else { throw DocumentImportError.invalidPDF }
        guard !document.isLocked else { throw DocumentImportError.lockedPDF }
        guard document.allowsCopying else { throw DocumentImportError.copyingDenied }
        guard document.pageCount > 0 else { throw DocumentImportError.noText }
        guard document.pageCount <= 2_000 else { throw DocumentImportError.pageLimit }
        var text = "PDF text snapshot. Pages without selectable text use local OCR; recognition can be imperfect and layout is not preserved.\n"
        var hasText = false
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw DocumentImportError.timeLimit }
            guard let page = document.page(at: index) else { throw DocumentImportError.invalidPDF }
            var pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if pageText.isEmpty {
                let bounds = page.bounds(for: .mediaBox)
                let scale = min(2, 1800 / max(1, max(bounds.width, bounds.height)))
                let rendered = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                if let image = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    pageText = try recognize(image)
                    if !pageText.isEmpty { pageText = "[Local OCR]\n" + pageText }
                }
            }
            if !pageText.isEmpty { hasText = true }
            text += "\n--- Page \(index + 1) ---\n" + (pageText.isEmpty ? "[No extractable text on this page; images are not included.]" : pageText) + "\n"
            guard text.utf8.count <= TextAttachment.maximumFileBytes else { throw DocumentImportError.textLimit }
        }
        guard ContinuousClock.now < deadline else { throw DocumentImportError.timeLimit }
        guard hasText else { throw DocumentImportError.noText }
        let attachment = TextAttachment(name: url.lastPathComponent, content: text)
        try TextAttachment.validate([attachment])
        return attachment
    }
    private static func recognizeImageData(_ data: Data) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2200, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw DocumentImportError.invalidImage }
        return try recognize(image)
    }
    private static func recognize(_ image: CGImage) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        try Task.checkCancellation()
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        guard text.utf8.count <= TextAttachment.maximumFileBytes else { throw DocumentImportError.textLimit }
        return text
    }
}
