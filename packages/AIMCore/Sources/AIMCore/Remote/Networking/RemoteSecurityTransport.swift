import Foundation

/// Separates gateway/auth failures from domain failures. Bodies stay in memory
/// and only allowlisted domain codes can cross into UI diagnostics.
enum RemoteSecurityTransport {
    private static let domainCodes: Set<String> = [
        "wrong_pin", "pin_invalide", "invalid_pin", "locked", "no_pin",
        "deverrouillage_requis", "origine_refusee", "erreur_serveur", "action_inconnue",
        "unlock_required", "device_not_paired", "not_authenticated",
        "pairing_too_old", "invalid_action", "pin_not_configured",
        "pin_already_set", "passkey_required", "unauthorized"
    ]

    static func decode(data: Data, status: Int) throws -> UnlockFunctionResponse {
        let response = try? JSONDecoder().decode(UnlockFunctionResponse.self, from: data)
        if (200..<300).contains(status) {
            guard let response else { throw RemoteSecurityServiceError.invalidResponse }
            return response
        }
        if let response, !response.ok, let code = response.error, domainCodes.contains(code) {
            return response
        }
        // Some Edge auth validators return {success:false,error:...}; gateway
        // errors return {code,message}. Never mistake either for a network loss.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = object["error"] as? String, domainCodes.contains(code),
           object["ok"] as? Bool != true, object["success"] as? Bool != true {
            throw RemoteSecurityServiceError.server(code: code)
        }
        throw RemoteSecurityServiceError.transport(code: "edge_http_\(status)")
    }
}
