import AIMCore
import Foundation

/// A phone attachment, decrypted and verified (protocol v2 §6.9).
public struct RemoteHostAttachment: Equatable, Sendable {
    public let name: String
    public let mimeType: String
    public let data: Data
    public init(name: String, mimeType: String, data: Data) {
        self.name = name; self.mimeType = mimeType; self.data = data
    }
}

/// Fetches phone attachments all-or-nothing: each reference must be a `ready`
/// attachment of THIS machine and conversation according to its encrypted
/// manifest; blocks are verified (hashes, GCM tags, size, digest) before use.
public enum RemoteHostAttachments {
    public static let maximumCount = 4
    public static let maximumBytes = 20 * 1_024 * 1_024
    static let maximumBlocks = 21

    struct Reference: Equatable { let transferID: String; let name: String; let mime: String }

    static func references(_ payload: RemoteJSONValue) throws -> [Reference] {
        guard let items = payload.objectValue?["attachments"]?.arrayValue, !items.isEmpty else { return [] }
        guard items.count <= maximumCount else { throw RemoteHostCommandFailure("trop_de_pieces_jointes") }
        return try items.map { item in
            guard let object = item.objectValue, let id = object["transfer_id"]?.stringValue, UUID(uuidString: id) != nil else {
                throw RemoteHostCommandFailure("piece_jointe_invalide")
            }
            if let size = object["size"]?.numberValue, size <= 0 { throw RemoteHostCommandFailure("piece_jointe_invalide") }
            if let size = object["size"]?.numberValue, size > Double(maximumBytes) { throw RemoteHostCommandFailure("piece_jointe_trop_lourde") }
            return Reference(transferID: id.lowercased(), name: object["name"]?.stringValue ?? "attachment",
                             mime: object["mime"]?.stringValue ?? "application/octet-stream")
        }
    }

    /// Downloads and opens every attachment of a `user_message`; nothing is
    /// returned unless all of them are valid. The relay copies are then deleted.
    public static func fetch(payload: RemoteJSONValue, sessionID: String?, machineID: String, keys: [Int: Data],
                             backend: any RemoteHostBackend) async throws -> [RemoteHostAttachment] {
        let references = try references(payload)
        guard !references.isEmpty else { return [] }
        guard let sessionID else { throw RemoteHostCommandFailure("session_introuvable") }
        guard !keys.isEmpty else { throw RemoteHostCommandFailure("chiffrement_requis") }
        let userID = try await backend.userID()
        var files: [RemoteHostAttachment] = []
        var cleanup: [(String, [String])] = []
        for reference in references {
            guard let row = try await backend.transfer(id: reference.transferID), row.status == "ready" else {
                throw RemoteHostCommandFailure("piece_jointe_introuvable")
            }
            guard row.kind == "attachment", row.machine_id.lowercased() == machineID.lowercased(),
                  row.session_id.lowercased() == sessionID.lowercased() else { throw RemoteHostCommandFailure("piece_jointe_etrangere") }
            guard (1...maximumBlocks).contains(row.chunk_count) else { throw RemoteHostCommandFailure("piece_jointe_trop_lourde") }
            let manifest: RemoteTransferManifest
            do { manifest = try RemoteTransferCrypto.openManifest(row.manifest, transferID: row.id, keys: keys) }
            catch { throw RemoteHostCommandFailure("piece_jointe_illisible") }
            // The encrypted manifest decides, not the clear row.
            guard manifest.kind == .attachment, manifest.machineID.lowercased() == machineID.lowercased(),
                  manifest.sessionID.lowercased() == sessionID.lowercased() else { throw RemoteHostCommandFailure("piece_jointe_etrangere") }
            guard manifest.clearSize > 0 else { throw RemoteHostCommandFailure("piece_jointe_invalide") }
            guard manifest.clearSize <= maximumBytes else { throw RemoteHostCommandFailure("piece_jointe_trop_lourde") }
            guard let key = keys[manifest.keyVersion] else { throw RemoteHostCommandFailure("chiffrement_requis") }
            var blocks: [RemoteTransferBlock] = []
            var paths: [String] = []
            for index in 0..<manifest.chunkCount {
                let path = try RemoteTransferCrypto.storagePath(userID: userID, manifest: manifest, index: index)
                paths.append(path)
                var data: Data?
                for attempt in 0..<3 where data == nil {
                    data = try? await backend.downloadBlock(path: path)
                    if data == nil, attempt < 2 { try? await Task.sleep(for: .milliseconds(400 * (attempt + 1))) }
                }
                guard let data else { throw RemoteHostCommandFailure("piece_jointe_incomplete") }
                blocks.append(RemoteTransferBlock(index: index, encrypted: data))
            }
            let clear: Data
            do { clear = try RemoteTransferCrypto.assemble(manifest: manifest, blocks: blocks, key: key) }
            catch { throw RemoteHostCommandFailure("piece_jointe_illisible") }
            files.append(RemoteHostAttachment(name: manifest.filename ?? reference.name, mimeType: manifest.mimeType, data: clear))
            cleanup.append((row.id, paths))
        }
        for (id, paths) in cleanup { try? await backend.deleteTransfer(id: id, paths: paths) }
        return files
    }

    // MARK: Saving into the workspace (Agent)

    /// Last path segment only, unsafe characters replaced, bounded length.
    public static func safeName(_ name: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? "attachment"
        var cleaned = String(last.map { "<>:\"|?*\0".contains($0) || $0.isNewline ? "_" : $0 })
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if cleaned.isEmpty { cleaned = "attachment" }
        return String(cleaned.prefix(120))
    }

    /// Writes the files to `<workspace>/.aim/pieces-jointes/` (never overwriting, with a
    /// `.gitignore`), and returns the note appended to the message.
    public static func save(_ files: [RemoteHostAttachment], workspace: String, now: Date = .now) throws -> (note: String, urls: [URL]) {
        let root = URL(fileURLWithPath: workspace, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { throw RemoteHostCommandFailure("dossier_introuvable") }
        let folder = root.appendingPathComponent(".aim/pieces-jointes", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let ignore = folder.appendingPathComponent(".gitignore")
            if !FileManager.default.fileExists(atPath: ignore.path) { try Data("*\n".utf8).write(to: ignore) }
        } catch { throw RemoteHostCommandFailure("piece_jointe_non_enregistree") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = formatter.string(from: now)
        var lines: [String] = []
        var urls: [URL] = []
        var written: [URL] = []
        do {
            for file in files {
                let base = "\(stamp)_\(safeName(file.name))"
                var target = folder.appendingPathComponent(base)
                var counter = 2
                while FileManager.default.fileExists(atPath: target.path) {
                    let ext = (base as NSString).pathExtension
                    let stem = (base as NSString).deletingPathExtension
                    target = folder.appendingPathComponent(ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)")
                    counter += 1
                }
                try file.data.write(to: target, options: .withoutOverwriting)
                written.append(target)
                urls.append(target)
                let size = ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file)
                    .replacingOccurrences(of: "KB", with: "Ko").replacingOccurrences(of: "MB", with: "Mo")
                lines.append("- \(safeName(file.name)) (\(file.mimeType), \(size)) : .aim/pieces-jointes/\(target.lastPathComponent)")
            }
        } catch {
            for url in written { try? FileManager.default.removeItem(at: url) }
            throw RemoteHostCommandFailure("piece_jointe_non_enregistree")
        }
        let header = files.count == 1
            ? "Pièce jointe envoyée depuis le téléphone, enregistrée dans le dossier de travail :"
            : "Pièces jointes envoyées depuis le téléphone, enregistrées dans le dossier de travail :"
        return (header + "\n" + lines.joined(separator: "\n"), urls)
    }
}
