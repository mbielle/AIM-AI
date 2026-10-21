import Foundation
import Supabase

actor SupabaseCloudContentService: CloudContentServicing {
    private let client: SupabaseClient

    init(client: SupabaseClient) { self.client = client }

    func loadProfile() async throws -> AIMUserProfile {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            let session = try await client.auth.session
            let rows: [ProfileRow] = try await client
                .from("profiles")
                .select("full_name,preferred_name,personal_preferences")
                .eq("id", value: session.user.id.uuidString.lowercased())
                .limit(1)
                .execute()
                .value
            return rows.first?.profile ?? .init(
                fullName: session.user.userMetadata["full_name"]?.stringValue ?? "",
                preferredName: "",
                personalPreferences: ""
            )
        } catch { throw CloudContentError.unavailable }
    }

    func saveProfile(_ profile: AIMUserProfile) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            let session = try await client.auth.session
            try await client
                .from("profiles")
                .update(ProfileUpdate(profile: profile))
                .eq("id", value: session.user.id.uuidString.lowercased())
                .execute()
        } catch { throw CloudContentError.unavailable }
    }

    func loadProjects() async throws -> [AIMProject] {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            let session = try await client.auth.session
            let rows: [ProjectRow] = try await client
                .from("projects")
                .select("id,name,description,custom_context,created_at,updated_at,last_active_at,is_starred")
                .eq("user_id", value: session.user.id.uuidString.lowercased())
                .eq("archived", value: false)
                .order("last_active_at", ascending: false)
                .execute()
                .value
            return rows.map(\.project)
        } catch { throw CloudContentError.unavailable }
    }

    func createProject(name: String, description: String?, customContext: String?) async throws -> AIMProject {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CloudContentError.invalidInput }
        do {
            let session = try await client.auth.session
            let row: ProjectRow = try await client
                .from("projects")
                .insert(ProjectInsert(
                    name: String(trimmed.prefix(120)),
                    description: description?.trimmingCharacters(in: .whitespacesAndNewlines),
                    customContext: customContext?.trimmingCharacters(in: .whitespacesAndNewlines),
                    userID: session.user.id.uuidString.lowercased()
                ))
                .select("id,name,description,custom_context,created_at,updated_at,last_active_at,is_starred")
                .single()
                .execute()
                .value
            return row.project
        } catch let error as CloudContentError { throw error }
        catch { throw CloudContentError.unavailable }
    }

    func archiveProject(id: String) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            let session = try await client.auth.session
            try await client.from("projects")
                .update(ProjectArchive(archived: true))
                .eq("id", value: id)
                .eq("user_id", value: session.user.id.uuidString.lowercased())
                .execute()
        } catch { throw CloudContentError.unavailable }
    }

    func renameProject(id: String, name: String) async throws -> AIMProject {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CloudContentError.invalidInput }
        do {
            let session = try await client.auth.session
            let row: ProjectRow = try await client.from("projects")
                .update(ProjectRename(name: String(trimmed.prefix(120)), updatedAt: ISO8601DateFormatter().string(from: Date())))
                .eq("id", value: id)
                .eq("user_id", value: session.user.id.uuidString.lowercased())
                .select("id,name,description,custom_context,created_at,updated_at,last_active_at,is_starred")
                .single()
                .execute().value
            return row.project
        } catch let error as CloudContentError { throw error }
        catch { throw CloudContentError.unavailable }
    }

    func setProjectFavorite(id: String, isFavorite: Bool) async throws -> AIMProject {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            let session = try await client.auth.session
            let row: ProjectRow = try await client.from("projects")
                .update(ProjectFavorite(isStarred: isFavorite, updatedAt: ISO8601DateFormatter().string(from: Date())))
                .eq("id", value: id)
                .eq("user_id", value: session.user.id.uuidString.lowercased())
                .select("id,name,description,custom_context,created_at,updated_at,last_active_at,is_starred")
                .single()
                .execute().value
            return row.project
        } catch { throw CloudContentError.unavailable }
    }

    func deleteProject(id: String) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            let session = try await client.auth.session
            let userID = session.user.id.uuidString.lowercased()
            let fileRows: [ProjectFileStorageRow] = try await client.from("project_files")
                .select("storage_path")
                .eq("project_id", value: id)
                .eq("user_id", value: userID)
                .execute().value
            let storagePaths = fileRows.compactMap(\.storagePath).filter { !$0.isEmpty }
            if !storagePaths.isEmpty {
                _ = try await client.storage.from("project-files-user").remove(paths: storagePaths)
            }
            try await client.from("conversations")
                .delete().eq("project_id", value: id).eq("user_id", value: userID).execute()
            try await client.from("project_files")
                .delete().eq("project_id", value: id).eq("user_id", value: userID).execute()
            try await client.from("projects")
                .delete().eq("id", value: id).eq("user_id", value: userID).execute()
        } catch { throw CloudContentError.unavailable }
    }

    func loadProjectConversations(projectID: String) async throws -> [AIMProjectConversation] {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            let session = try await client.auth.session
            let rows: [ProjectConversationRow] = try await client.from("conversations")
                .select("id,title,current_model,is_pinned,updated_at")
                .eq("project_id", value: projectID)
                .eq("user_id", value: session.user.id.uuidString.lowercased())
                .eq("archived", value: false)
                .order("updated_at", ascending: false)
                .execute().value
            return rows.map(\.conversation)
        } catch { throw CloudContentError.unavailable }
    }

    func loadProjectFiles(projectID: String) async throws -> [AIMProjectFile] {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            let session = try await client.auth.session
            let rows: [ProjectFileRow] = try await client.from("project_files")
                .select("id,name,mime_type,size_bytes,status,error_message,created_at")
                .eq("project_id", value: projectID)
                .eq("user_id", value: session.user.id.uuidString.lowercased())
                .order("created_at", ascending: false)
                .execute().value
            return rows.map(\.file)
        } catch { throw CloudContentError.unavailable }
    }

    func uploadProjectFile(projectID: String, data: Data, name: String, mimeType: String) async throws -> AIMProjectFile {
        try await uploadProjectFile(projectID: projectID, data: data, name: name, mimeType: mimeType, extractedText: nil)
    }

    func uploadProjectFile(projectID: String, data: Data, name: String, mimeType: String, extractedText: String?) async throws -> AIMProjectFile {
        if let extractedText {
            guard data.count <= 20_000_000, !extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudContentError.invalidInput }
            try NativeDocumentSnapshot.validate([.init(name: name, content: extractedText)])
        }
        try Task.checkCancellation()
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let safeName = URL(fileURLWithPath: name).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeName.isEmpty, !data.isEmpty, data.count <= 20 * 1_024 * 1_024 else {
            throw CloudContentError.invalidInput
        }

        do {
            let session = try await client.auth.session
            let userID = session.user.id.uuidString.lowercased()
            let record: ProjectFileRow = try await client.from("project_files")
                .insert(ProjectFileInsert(
                    projectID: projectID,
                    userID: userID,
                    name: String(safeName.prefix(255)),
                    mimeType: mimeType.isEmpty ? "application/octet-stream" : mimeType,
                    sizeBytes: data.count
                ))
                .select("id,name,mime_type,size_bytes,status,error_message,created_at")
                .single()
                .execute().value

            let storagePath = "\(userID)/\(projectID)/\(record.id)/\(safeName)"
            do {
                try await client.storage.from("project-files-user").upload(
                    storagePath,
                    data: data,
                    options: FileOptions(contentType: mimeType.isEmpty ? "application/octet-stream" : mimeType, upsert: false)
                )

                try Task.checkCancellation()
                let localContent = extractedText ?? (isPlainText(name: safeName, mimeType: mimeType) ? String(data: data, encoding: .utf8) : nil)
                if let content = localContent, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try await client.from("project_files")
                        .update(ProjectFileCompletedUpdate(
                            storagePath: storagePath,
                            extractedContent: content,
                            indexedAt: ISO8601DateFormatter().string(from: Date())
                        ))
                        .eq("id", value: record.id).eq("user_id", value: userID).execute()
                } else {
                    try await client.from("project_files")
                        .update(ProjectFileProcessingUpdate(storagePath: storagePath))
                        .eq("id", value: record.id).eq("user_id", value: userID).execute()
                    let response: RemoteJSONValue = try await client.functions.invoke(
                        "file-processor",
                        options: .init(body: ProjectFileProcessorRequest(
                            file: data.base64EncodedString(),
                            fileName: safeName,
                            fileType: mimeType,
                            forceOCR: false
                        ))
                    )
                    let object = response.objectValue ?? [:]
                    let extracted = object["extractedText"]?.stringValue
                    let succeeded = object["status"]?.stringValue == "ok" && extracted?.isEmpty == false
                    if succeeded, let extracted {
                        try await client.from("project_files")
                            .update(ProjectFileCompletedUpdate(
                                storagePath: storagePath,
                                extractedContent: extracted,
                                indexedAt: ISO8601DateFormatter().string(from: Date())
                            ))
                            .eq("id", value: record.id).eq("user_id", value: userID).execute()
                    } else {
                        try await client.from("project_files")
                            .update(ProjectFileFailedUpdate(
                                status: object["status"]?.stringValue == "needs_ocr" ? "needs_ocr" : "error",
                                errorMessage: object["errorCode"]?.stringValue ?? "processing_failed"
                            ))
                            .eq("id", value: record.id).eq("user_id", value: userID).execute()
                    }
                }

                let completed: ProjectFileRow = try await client.from("project_files")
                    .select("id,name,mime_type,size_bytes,status,error_message,created_at")
                    .eq("id", value: record.id).eq("user_id", value: userID)
                    .single().execute().value
                return completed.file
            } catch {
                _ = try? await client.from("project_files")
                    .update(ProjectFileFailedUpdate(status: "error", errorMessage: "upload_or_processing_failed"))
                    .eq("id", value: record.id).eq("user_id", value: userID).execute()
                throw error
            }
        } catch let error as CloudContentError { throw error }
        catch { throw CloudContentError.unavailable }
    }

    func deleteProjectFile(projectID: String, fileID: String) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            let session = try await client.auth.session
            let userID = session.user.id.uuidString.lowercased()
            let row: ProjectFileStorageRow? = try await client.from("project_files")
                .select("storage_path")
                .eq("id", value: fileID)
                .eq("project_id", value: projectID)
                .eq("user_id", value: userID)
                .maybeSingle().execute().value
            if let path = row?.storagePath, !path.isEmpty {
                _ = try await client.storage.from("project-files-user").remove(paths: [path])
            }
            try await client.from("project_files")
                .delete()
                .eq("id", value: fileID)
                .eq("project_id", value: projectID)
                .eq("user_id", value: userID)
                .execute()
        } catch { throw CloudContentError.unavailable }
    }

    private func isPlainText(name: String, mimeType: String) -> Bool {
        mimeType.hasPrefix("text/") || name.lowercased().hasSuffix(".md") || name.lowercased().hasSuffix(".txt")
    }

    func loadLegacyMessages(conversationID: String) async throws -> [AIMLegacyMessage] {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            let session = try await client.auth.session
            let ownedRows: [OwnedConversationRow] = try await client.from("conversations")
                .select("id")
                .eq("id", value: conversationID)
                .eq("user_id", value: session.user.id.uuidString.lowercased())
                .limit(1)
                .execute().value
            guard !ownedRows.isEmpty else { throw CloudContentError.unavailable }
            let rows: [LegacyMessageRow] = try await client.from("messages")
                .select("id,role,content,reasoning,model,created_at")
                .eq("conversation_id", value: conversationID)
                .order("created_at", ascending: true)
                .execute().value
            return rows.map(\.message)
        } catch { throw CloudContentError.unavailable }
    }

    func loadMedia(kind: AIMMediaKind) async throws -> [AIMMediaItem] {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            let session = try await client.auth.session
            let userID = session.user.id.uuidString.lowercased()
            switch kind {
            case .image:
                let rows: [ImageRow] = try await client
                    .from("generated_images")
                    .select("id,image_url,prompt,model_used,created_at,expires_at,storage_path")
                    .eq("user_id", value: userID)
                    .order("created_at", ascending: false)
                    .execute()
                    .value
                return rows.compactMap(\.item).filter { $0.expiresAt > Date() }
            case .video:
                let rows: [VideoRow] = try await client
                    .from("generated_videos")
                    .select("id,video_url,prompt,model_used,created_at,expires_at,storage_path,duration,resolution,status")
                    .eq("user_id", value: userID)
                    .eq("status", value: "completed")
                    .order("created_at", ascending: false)
                    .execute()
                    .value
                return rows.compactMap(\.item).filter { $0.expiresAt > Date() }
            }
        } catch { throw CloudContentError.unavailable }
    }

    func deleteMedia(_ item: AIMMediaItem) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            let session = try await client.auth.session
            let bucket = item.kind == .image ? "generated-images" : "generated-videos"
            let table = item.kind == .image ? "generated_images" : "generated_videos"
            if !item.storagePath.isEmpty {
                _ = try await client.storage.from(bucket).remove(paths: [item.storagePath])
            }
            try await client.from(table)
                .delete()
                .eq("id", value: item.id)
                .eq("user_id", value: session.user.id.uuidString.lowercased())
                .execute()
        } catch { throw CloudContentError.unavailable }
    }

    func loadConnectors() async throws -> [AIMConnector] {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            let session = try await client.auth.session
            let rows: [ConnectorRow] = try await client
                .from("user_connectors")
                .select("id,connector_type,display_name,server_url,config,is_active,last_connected_at,tools_cache,default_parent_id,default_parent_name,created_at")
                .eq("user_id", value: session.user.id.uuidString.lowercased())
                .order("created_at", ascending: false)
                .execute()
                .value
            return rows.map(\.connector)
        } catch { throw CloudContentError.unavailable }
    }

    func setConnectorActive(id: String, isActive: Bool) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            let session = try await client.auth.session
            try await client.from("user_connectors")
                .update(ConnectorActiveUpdate(isActive: isActive, updatedAt: ISO8601DateFormatter().string(from: Date())))
                .eq("id", value: id)
                .eq("user_id", value: session.user.id.uuidString.lowercased())
                .execute()
        } catch { throw CloudContentError.unavailable }
    }

    func setConnectorToolPermission(id: String, toolName: String, permission: ConnectorToolPermission) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        guard !toolName.isEmpty else { throw CloudContentError.invalidInput }
        do {
            let session = try await client.auth.session
            let userID = session.user.id.uuidString.lowercased()
            let row: ConnectorConfigRow = try await client.from("user_connectors")
                .select("config")
                .eq("id", value: id)
                .eq("user_id", value: userID)
                .single()
                .execute()
                .value
            var config = row.config?.objectValue ?? [:]
            var permissions = config["tool_permissions"]?.objectValue ?? [:]
            permissions[toolName] = .string(permission.rawValue)
            config["tool_permissions"] = .object(permissions)
            try await client.from("user_connectors")
                .update(ConnectorConfigUpdate(config: .object(config), updatedAt: ISO8601DateFormatter().string(from: Date())))
                .eq("id", value: id)
                .eq("user_id", value: userID)
                .execute()
        } catch let error as CloudContentError { throw error }
        catch { throw CloudContentError.unavailable }
    }

    func deleteConnector(id: String) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            let session = try await client.auth.session
            try await client.from("user_connectors")
                .delete()
                .eq("id", value: id)
                .eq("user_id", value: session.user.id.uuidString.lowercased())
                .execute()
        } catch { throw CloudContentError.unavailable }
    }

    func connectorAuthorizationURL(
        provider: AIMConnectorOAuthProvider,
        redirectURL: URL
    ) async throws -> URL {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            let response: ConnectorAuthorizationResponse = try await client.functions.invoke(
                "oauth-connector",
                options: .init(body: ConnectorAuthorizationRequest(
                    action: "initiate",
                    provider: provider.rawValue,
                    redirectURL: redirectURL.absoluteString
                ))
            )
            guard let url = URL(string: response.authorizationURL), url.scheme == "https" else {
                throw CloudContentError.unavailable
            }
            return url
        } catch let error as CloudContentError { throw error }
        catch { throw CloudContentError.unavailable }
    }

    func loadPreferences() async throws -> AIMUserPreferences {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            let session = try await client.auth.session
            let rows: [PreferenceRow] = try await client.from("user_preferences")
                .select("auto_model_selection,auto_title_generation,smart_context,haptic_feedback,tone,style,expertise,length_instruction,emojis,max_emojis,web_search_enabled,detailed_response_enabled,library_retention_days,share_profile_with_ai,memory_enabled")
                .eq("user_id", value: session.user.id.uuidString.lowercased())
                .limit(1)
                .execute()
                .value
            return rows.first?.preferences ?? .defaults
        } catch { throw CloudContentError.unavailable }
    }

    func savePreferences(_ preferences: AIMUserPreferences) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            let session = try await client.auth.session
            try await client.from("user_preferences")
                .upsert(
                    PreferenceUpsert(userID: session.user.id.uuidString.lowercased(), preferences: preferences),
                    onConflict: "user_id"
                )
                .execute()
        } catch { throw CloudContentError.unavailable }
    }

    func loadMemoryDocument() async throws -> AIMMemoryDocument {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            let session = try await client.auth.session
            let rows: [MemoryRow] = try await client.from("user_memory_documents")
                .select("content_md,version,updated_at")
                .eq("user_id", value: session.user.id.uuidString.lowercased())
                .limit(1)
                .execute()
                .value
            return rows.first?.document ?? .init(content: "", version: 0, updatedAt: nil)
        } catch { throw CloudContentError.unavailable }
    }

    func saveMemoryDocument(content: String, expectedVersion: Int) async throws -> AIMMemoryDocument {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            let session = try await client.auth.session
            let userID = session.user.id.uuidString.lowercased()
            if expectedVersion == 0 {
                let updatedRows: [MemoryRow] = try await client.from("user_memory_documents")
                    .update(MemoryUpdate(content: content, version: 1))
                    .eq("user_id", value: userID)
                    .eq("version", value: 0)
                    .select("content_md,version,updated_at")
                    .execute()
                    .value
                if let document = updatedRows.first?.document { return document }
                let rows: [MemoryRow] = try await client.from("user_memory_documents")
                    .insert(MemoryInsert(userID: userID, content: content, version: 1))
                    .select("content_md,version,updated_at")
                    .execute()
                    .value
                guard let document = rows.first?.document else { throw CloudContentError.unavailable }
                return document
            }
            let rows: [MemoryRow] = try await client.from("user_memory_documents")
                .update(MemoryUpdate(content: content, version: expectedVersion + 1))
                .eq("user_id", value: userID)
                .eq("version", value: expectedVersion)
                .select("content_md,version,updated_at")
                .execute()
                .value
            guard let document = rows.first?.document else { throw CloudContentError.conflict }
            return document
        } catch let error as CloudContentError { throw error }
        catch { throw CloudContentError.unavailable }
    }

    func exportUserData() async throws -> Data {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            let value: RemoteJSONValue = try await client.functions.invoke("export-user-data")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(value)
        } catch { throw CloudContentError.unavailable }
    }

    func deleteAccount(confirmEmail: String, confirmation: String) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let email = confirmEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, confirmation == "SUPPRIMER" else { throw CloudContentError.invalidInput }
        do {
            let response: AccountDeletionResponse = try await client.functions.invoke(
                "delete-account",
                options: .init(body: AccountDeletionRequest(
                    confirmEmail: email,
                    confirmText: confirmation
                ))
            )
            guard response.success else { throw CloudContentError.unavailable }
        } catch let error as CloudContentError { throw error }
        catch { throw CloudContentError.unavailable }
    }
}

private struct ConnectorAuthorizationRequest: Encodable {
    let action: String
    let provider: String
    let redirectURL: String
    enum CodingKeys: String, CodingKey { case action, provider; case redirectURL = "redirect_url" }
}

private struct ConnectorAuthorizationResponse: Decodable {
    let authorizationURL: String
    enum CodingKeys: String, CodingKey { case authorizationURL = "authorize_url" }
}

private struct AccountDeletionRequest: Encodable {
    let confirmEmail: String
    let confirmText: String
}

private struct AccountDeletionResponse: Decodable {
    let success: Bool
}

private struct ProfileRow: Decodable {
    let fullName: String?
    let preferredName: String?
    let personalPreferences: String?

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case preferredName = "preferred_name"
        case personalPreferences = "personal_preferences"
    }

    var profile: AIMUserProfile {
        .init(
            fullName: fullName ?? "",
            preferredName: preferredName ?? "",
            personalPreferences: personalPreferences ?? ""
        )
    }
}

private struct ProfileUpdate: Encodable {
    let fullName: String
    let preferredName: String
    let personalPreferences: String

    init(profile: AIMUserProfile) {
        fullName = profile.fullName
        preferredName = profile.preferredName
        personalPreferences = profile.personalPreferences
    }

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case preferredName = "preferred_name"
        case personalPreferences = "personal_preferences"
    }
}

private struct ProjectRow: Decodable {
    let id: String; let name: String; let description: String?; let customContext: String?; let createdAt: String; let updatedAt: String; let lastActiveAt: String; let isStarred: Bool
    enum CodingKeys: String, CodingKey { case id, name, description; case customContext = "custom_context"; case createdAt = "created_at"; case updatedAt = "updated_at"; case lastActiveAt = "last_active_at"; case isStarred = "is_starred" }
    var project: AIMProject { .init(id: id, name: name, description: description, customContext: customContext, createdAt: parseDate(createdAt), updatedAt: parseDate(updatedAt), lastActiveAt: parseDate(lastActiveAt), isStarred: isStarred) }
}

private struct ProjectInsert: Encodable {
    let name: String; let description: String?; let customContext: String?; let userID: String
    let defaultLanguage = "auto"
    enum CodingKeys: String, CodingKey { case name, description; case customContext = "custom_context"; case userID = "user_id"; case defaultLanguage = "default_language" }
}
private struct ProjectArchive: Encodable { let archived: Bool }
private struct ProjectRename: Encodable {
    let name: String
    let updatedAt: String
    enum CodingKeys: String, CodingKey { case name; case updatedAt = "updated_at" }
}
private struct ProjectFavorite: Encodable {
    let isStarred: Bool
    let updatedAt: String
    enum CodingKeys: String, CodingKey { case isStarred = "is_starred"; case updatedAt = "updated_at" }
}

private struct ProjectConversationRow: Decodable {
    let id: String; let title: String; let model: String?; let isPinned: Bool; let updatedAt: String
    enum CodingKeys: String, CodingKey { case id, title; case model = "current_model"; case isPinned = "is_pinned"; case updatedAt = "updated_at" }
    var conversation: AIMProjectConversation { .init(id: id, title: title, model: model, isPinned: isPinned, updatedAt: parseDate(updatedAt)) }
}
private struct OwnedConversationRow: Decodable { let id: String }
private struct ProjectFileRow: Decodable {
    let id: String; let name: String; let mimeType: String?; let sizeBytes: Int; let status: String; let errorMessage: String?; let createdAt: String
    enum CodingKeys: String, CodingKey { case id, name, status; case mimeType = "mime_type"; case sizeBytes = "size_bytes"; case errorMessage = "error_message"; case createdAt = "created_at" }
    var file: AIMProjectFile { .init(id: id, name: name, mimeType: mimeType, sizeBytes: sizeBytes, status: status, errorMessage: errorMessage, createdAt: parseDate(createdAt)) }
}
private struct ProjectFileStorageRow: Decodable {
    let storagePath: String?
    enum CodingKeys: String, CodingKey { case storagePath = "storage_path" }
}
private struct ProjectFileInsert: Encodable {
    let projectID: String
    let userID: String
    let name: String
    let mimeType: String
    let sizeBytes: Int
    let status = "uploading"
    let processingStatus = "pending"
    enum CodingKeys: String, CodingKey {
        case name, status
        case projectID = "project_id"
        case userID = "user_id"
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case processingStatus = "processing_status"
    }
}
private struct ProjectFileProcessingUpdate: Encodable {
    let storagePath: String
    let status = "processing"
    let processingStatus = "processing"
    enum CodingKeys: String, CodingKey {
        case status
        case storagePath = "storage_path"
        case processingStatus = "processing_status"
    }
}
private struct ProjectFileCompletedUpdate: Encodable {
    let storagePath: String
    let extractedContent: String
    let indexedAt: String
    let status = "completed"
    let processingStatus = "completed"
    enum CodingKeys: String, CodingKey {
        case status
        case storagePath = "storage_path"
        case extractedContent = "extracted_content"
        case indexedAt = "indexed_at"
        case processingStatus = "processing_status"
    }
}
private struct ProjectFileFailedUpdate: Encodable {
    let status: String
    let errorMessage: String
    let processingStatus: String
    init(status: String, errorMessage: String) {
        self.status = status
        self.errorMessage = errorMessage
        processingStatus = status
    }
    enum CodingKeys: String, CodingKey {
        case status
        case errorMessage = "error_message"
        case processingStatus = "processing_status"
    }
}
private struct ProjectFileProcessorRequest: Encodable {
    let file: String
    let fileName: String
    let fileType: String
    let forceOCR: Bool
    enum CodingKeys: String, CodingKey {
        case file, fileName, fileType, forceOCR
    }
}
private struct LegacyMessageRow: Decodable {
    let id: String; let role: String; let content: String; let reasoning: String?; let model: String?; let createdAt: String
    enum CodingKeys: String, CodingKey { case id, role, content, reasoning, model; case createdAt = "created_at" }
    var message: AIMLegacyMessage { .init(id: id, role: role, content: content, reasoning: reasoning, model: model, createdAt: parseDate(createdAt)) }
}

private struct ConnectorRow: Decodable {
    let id: String
    let connectorType: String
    let displayName: String
    let serverURL: String
    let config: RemoteJSONValue?
    let isActive: Bool
    let lastConnectedAt: String?
    let toolsCache: [AIMConnectorTool]?
    let defaultParentID: String?
    let defaultParentName: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, config
        case connectorType = "connector_type"
        case displayName = "display_name"
        case serverURL = "server_url"
        case isActive = "is_active"
        case lastConnectedAt = "last_connected_at"
        case toolsCache = "tools_cache"
        case defaultParentID = "default_parent_id"
        case defaultParentName = "default_parent_name"
        case createdAt = "created_at"
    }

    var connector: AIMConnector {
        let rawPermissions = config?.objectValue?["tool_permissions"]?.objectValue ?? [:]
        let permissions = rawPermissions.reduce(into: [String: ConnectorToolPermission]()) { result, entry in
            if case let .string(value) = entry.value, let permission = ConnectorToolPermission(rawValue: value) {
                result[entry.key] = permission
            }
        }
        return .init(
            id: id,
            type: connectorType,
            displayName: displayName,
            serverURL: serverURL,
            isActive: isActive,
            lastConnectedAt: lastConnectedAt.map(parseDate),
            tools: toolsCache ?? [],
            toolPermissions: permissions,
            defaultParentID: defaultParentID,
            defaultParentName: defaultParentName,
            createdAt: parseDate(createdAt)
        )
    }
}

private struct ConnectorConfigRow: Decodable { let config: RemoteJSONValue? }
private struct ConnectorActiveUpdate: Encodable {
    let isActive: Bool; let updatedAt: String
    enum CodingKeys: String, CodingKey { case isActive = "is_active"; case updatedAt = "updated_at" }
}
private struct ConnectorConfigUpdate: Encodable {
    let config: RemoteJSONValue; let updatedAt: String
    enum CodingKeys: String, CodingKey { case config; case updatedAt = "updated_at" }
}

private struct PreferenceRow: Decodable {
    let autoModelSelection: Bool?
    let autoTitleGeneration: Bool?
    let smartContext: Bool?
    let hapticFeedback: Bool?
    let tone: String?
    let style: String?
    let expertise: String?
    let responseLength: String?
    let emojis: Bool?
    let maxEmojis: Int?
    let webSearchEnabled: Bool?
    let detailedResponseEnabled: Bool?
    let libraryRetentionDays: Int?
    let shareProfileWithAI: Bool?
    let memoryEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case autoModelSelection = "auto_model_selection"
        case autoTitleGeneration = "auto_title_generation"
        case smartContext = "smart_context"
        case hapticFeedback = "haptic_feedback"
        case tone, style, expertise, emojis
        case responseLength = "length_instruction"
        case maxEmojis = "max_emojis"
        case webSearchEnabled = "web_search_enabled"
        case detailedResponseEnabled = "detailed_response_enabled"
        case libraryRetentionDays = "library_retention_days"
        case shareProfileWithAI = "share_profile_with_ai"
        case memoryEnabled = "memory_enabled"
    }

    var preferences: AIMUserPreferences {
        let fallback = AIMUserPreferences.defaults
        return .init(
            autoModelSelection: autoModelSelection ?? fallback.autoModelSelection,
            autoTitleGeneration: autoTitleGeneration ?? fallback.autoTitleGeneration,
            smartContext: smartContext ?? fallback.smartContext,
            hapticFeedback: hapticFeedback ?? fallback.hapticFeedback,
            tone: tone.flatMap(AIMTone.init(rawValue:)) ?? fallback.tone,
            style: style.flatMap(AIMResponseStyle.init(rawValue:)) ?? fallback.style,
            expertise: expertise.flatMap(AIMExpertise.init(rawValue:)) ?? fallback.expertise,
            responseLength: responseLength.flatMap(AIMResponseLength.init(rawValue:)) ?? fallback.responseLength,
            emojis: emojis ?? fallback.emojis,
            maxEmojis: maxEmojis ?? fallback.maxEmojis,
            webSearchEnabled: webSearchEnabled ?? fallback.webSearchEnabled,
            detailedResponseEnabled: detailedResponseEnabled ?? fallback.detailedResponseEnabled,
            libraryRetentionDays: libraryRetentionDays ?? fallback.libraryRetentionDays,
            shareProfileWithAI: shareProfileWithAI ?? fallback.shareProfileWithAI,
            memoryEnabled: memoryEnabled ?? fallback.memoryEnabled
        )
    }
}

private struct PreferenceUpsert: Encodable {
    let userID: String
    let autoModelSelection: Bool
    let autoTitleGeneration: Bool
    let smartContext: Bool
    let hapticFeedback: Bool
    let tone: String
    let style: String
    let expertise: String
    let responseLength: String
    let emojis: Bool
    let maxEmojis: Int
    let webSearchEnabled: Bool
    let detailedResponseEnabled: Bool
    let libraryRetentionDays: Int
    let shareProfileWithAI: Bool
    let memoryEnabled: Bool

    init(userID: String, preferences: AIMUserPreferences) {
        self.userID = userID
        autoModelSelection = preferences.autoModelSelection
        autoTitleGeneration = preferences.autoTitleGeneration
        smartContext = preferences.smartContext
        hapticFeedback = preferences.hapticFeedback
        tone = preferences.tone.rawValue
        style = preferences.style.rawValue
        expertise = preferences.expertise.rawValue
        responseLength = preferences.responseLength.rawValue
        emojis = preferences.emojis
        maxEmojis = preferences.maxEmojis
        webSearchEnabled = preferences.webSearchEnabled
        detailedResponseEnabled = preferences.detailedResponseEnabled
        libraryRetentionDays = preferences.libraryRetentionDays
        shareProfileWithAI = preferences.shareProfileWithAI
        memoryEnabled = preferences.memoryEnabled
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case autoModelSelection = "auto_model_selection"
        case autoTitleGeneration = "auto_title_generation"
        case smartContext = "smart_context"
        case hapticFeedback = "haptic_feedback"
        case tone, style, expertise, emojis
        case responseLength = "length_instruction"
        case maxEmojis = "max_emojis"
        case webSearchEnabled = "web_search_enabled"
        case detailedResponseEnabled = "detailed_response_enabled"
        case libraryRetentionDays = "library_retention_days"
        case shareProfileWithAI = "share_profile_with_ai"
        case memoryEnabled = "memory_enabled"
    }
}

private struct MemoryRow: Decodable {
    let content: String
    let version: Int
    let updatedAt: String
    enum CodingKeys: String, CodingKey { case content = "content_md"; case version; case updatedAt = "updated_at" }
    var document: AIMMemoryDocument { .init(content: content, version: version, updatedAt: parseDate(updatedAt)) }
}
private struct MemoryInsert: Encodable {
    let userID: String; let content: String; let version: Int
    enum CodingKeys: String, CodingKey { case userID = "user_id"; case content = "content_md"; case version }
}
private struct MemoryUpdate: Encodable {
    let content: String; let version: Int
    enum CodingKeys: String, CodingKey { case content = "content_md"; case version }
}

private struct ImageRow: Decodable {
    let id: String; let imageURL: String; let prompt: String; let model: String; let createdAt: String; let expiresAt: String; let storagePath: String
    enum CodingKeys: String, CodingKey { case id, prompt; case imageURL = "image_url"; case model = "model_used"; case createdAt = "created_at"; case expiresAt = "expires_at"; case storagePath = "storage_path" }
    var item: AIMMediaItem? { guard let url = URL(string: imageURL) else { return nil }; return .init(id: id, kind: .image, url: url, prompt: prompt, model: model, createdAt: parseDate(createdAt), expiresAt: parseDate(expiresAt), storagePath: storagePath) }
}

private struct VideoRow: Decodable {
    let id: String; let videoURL: String; let prompt: String; let model: String; let createdAt: String; let expiresAt: String; let storagePath: String; let duration: Double?; let resolution: String?; let status: String
    enum CodingKeys: String, CodingKey { case id, prompt, duration, resolution, status; case videoURL = "video_url"; case model = "model_used"; case createdAt = "created_at"; case expiresAt = "expires_at"; case storagePath = "storage_path" }
    var item: AIMMediaItem? { guard let url = URL(string: videoURL) else { return nil }; return .init(id: id, kind: .video, url: url, prompt: prompt, model: model, createdAt: parseDate(createdAt), expiresAt: parseDate(expiresAt), storagePath: storagePath, duration: duration, resolution: resolution) }
}

private func parseDate(_ value: String) -> Date {
    let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) ?? .distantPast
}
