import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import ImageIO
import Vision

public enum NativeDocumentImportError: LocalizedError {
    case invalidPDF, invalidOffice, invalidImage, lockedPDF, copyingDenied, noText, sourceLimit, pageLimit, textLimit, timeLimit
    public var errorDescription: String? {
        switch self {
        case .invalidPDF: "This file could not be read as a PDF."
        case .invalidOffice: "This Office document could not be read. Use an unencrypted DOCX, PPTX or XLSX copy."
        case .invalidImage: "This image could not be decoded for local text recognition."
        case .lockedPDF: "This PDF is password-locked. Unlock a copy before attaching it."
        case .copyingDenied: "This PDF does not allow copying its text."
        case .noText: "No readable text was found, including local text recognition."
        case .sourceLimit: "This document exceeds the selected import source limit (Chat: 20 MB; project: 100 MB), or contains an oversized Office archive member. Nothing was truncated."
        case .pageLimit: "This PDF exceeds the selected import page limit (Chat: 100; project: 1,000). Import a smaller document."
        case .textLimit: "This document exceeds the selected extraction limit (Chat: 64 KB; project: 8 MB), or the Office parsing safety budget. Nothing was truncated."
        case .timeLimit: "PDF extraction took too long. Try a smaller excerpt."
        }
    }
}

/// Project extraction is larger than a single message attachment; existing callers keep Chat limits.
public struct NativeDocumentImportLimits: Sendable {
    public let maximumSourceBytes: Int
    public let maximumTextBytes: Int
    public let maximumPDFPages: Int
    public let extractionSeconds: Int
    public static let chat = Self(maximumSourceBytes: 20_000_000, maximumTextBytes: 64_000, maximumPDFPages: 100, extractionSeconds: 30)
    public static let project = Self(maximumSourceBytes: 100_000_000, maximumTextBytes: 8_000_000, maximumPDFPages: 1_000, extractionSeconds: 120)
    fileprivate func validate(_ snapshot: NativeDocumentSnapshot) throws {
        guard !snapshot.name.isEmpty, snapshot.name.count <= 255, !snapshot.content.contains("\0") else { throw NativeDocumentError.invalidSelection }
        guard snapshot.content.utf8.count <= maximumTextBytes else { throw NativeDocumentImportError.textLimit }
    }
}

public enum NativeDocumentImporter {
    /// Returns a local text snapshot; never uploads, follows links, or executes document content.
    public static func read(_ url: URL, limits: NativeDocumentImportLimits = .chat) throws -> NativeDocumentSnapshot {
        try Task.checkCancellation()
        let format = url.pathExtension.lowercased()
        guard ["pdf", "docx", "pptx", "xlsx", "png", "jpg", "jpeg", "tiff", "tif", "heic", "webp"].contains(format) else {
            do { return try NativeDocumentSnapshot.read(url, maximumBytes: limits.maximumTextBytes) }
            catch NativeDocumentError.limit { throw NativeDocumentImportError.textLimit }
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw NativeDocumentImportError.sourceLimit }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: limits.maximumSourceBytes + 1) ?? Data()
        guard data.count <= limits.maximumSourceBytes else { throw NativeDocumentImportError.sourceLimit }
        try Task.checkCancellation()
        if ["docx", "pptx", "xlsx"].contains(format) {
            let attachment = NativeDocumentSnapshot(name: url.lastPathComponent, content: try NativeOfficeDocumentReader.read(url, maximumTextBytes: limits.maximumTextBytes, imageText: { try recognizeImageData($0, maximumTextBytes: limits.maximumTextBytes) }))
            try limits.validate(attachment); return attachment
        }
        if format != "pdf" {
            let text = try recognizeImageData(data, maximumTextBytes: limits.maximumTextBytes)
            guard !text.isEmpty else { throw NativeDocumentImportError.noText }
            let attachment = NativeDocumentSnapshot(name: url.lastPathComponent, content: "Local image OCR. Recognition can be imperfect; visual layout is not preserved.\n" + text)
            try limits.validate(attachment); return attachment
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(limits.extractionSeconds))
        guard let document = PDFDocument(data: data) else { throw NativeDocumentImportError.invalidPDF }
        guard !document.isLocked else { throw NativeDocumentImportError.lockedPDF }
        guard document.allowsCopying else { throw NativeDocumentImportError.copyingDenied }
        guard document.pageCount > 0 else { throw NativeDocumentImportError.noText }
        guard document.pageCount <= limits.maximumPDFPages else { throw NativeDocumentImportError.pageLimit }
        var text = "PDF text snapshot. Pages without selectable text use local OCR; recognition can be imperfect and layout is not preserved.\n"
        var hasText = false
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw NativeDocumentImportError.timeLimit }
            guard let page = document.page(at: index) else { throw NativeDocumentImportError.invalidPDF }
            var pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if pageText.isEmpty {
                let bounds = page.bounds(for: .mediaBox)
                let scale = min(2, 1800 / max(1, max(bounds.width, bounds.height)))
                let rendered = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                #if canImport(UIKit)
                let pixels = rendered.cgImage
                #else
                let pixels = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil)
                #endif
                if let image = pixels {
                    pageText = try recognize(image, maximumTextBytes: limits.maximumTextBytes)
                    if !pageText.isEmpty { pageText = "[Local OCR]\n" + pageText }
                }
            }
            if !pageText.isEmpty { hasText = true }
            text += "\n--- Page \(index + 1) ---\n" + (pageText.isEmpty ? "[No extractable text on this page; images are not included.]" : pageText) + "\n"
            guard text.utf8.count <= limits.maximumTextBytes else { throw NativeDocumentImportError.textLimit }
        }
        guard ContinuousClock.now < deadline else { throw NativeDocumentImportError.timeLimit }
        guard hasText else { throw NativeDocumentImportError.noText }
        let attachment = NativeDocumentSnapshot(name: url.lastPathComponent, content: text)
        try limits.validate(attachment)
        return attachment
    }
    private static func recognizeImageData(_ data: Data, maximumTextBytes: Int) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2200, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw NativeDocumentImportError.invalidImage }
        return try recognize(image, maximumTextBytes: maximumTextBytes)
    }
    private static func recognize(_ image: CGImage, maximumTextBytes: Int) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        try Task.checkCancellation()
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        guard text.utf8.count <= maximumTextBytes else { throw NativeDocumentImportError.textLimit }
        return text
    }
}
