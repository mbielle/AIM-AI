import AIMAgentKit
import Contacts
import Foundation

/// Searching the person's contacts (names, emails, phone numbers) so the agent
/// can address a message or an invitation. Read-only; needs Contacts access.
public actor MacContactsToolService: ToolExecutor {
    public nonisolated let supportedTools: Set<String> = ["contacts_search"]
    public init() {}

    public func execute(_ request: ToolRequest) async -> ToolResult {
        guard let query = request.arguments["query"]?.trimmingCharacters(in: .whitespaces), query.count >= 2, query.count <= 100 else {
            return ToolResult(requestID: request.id, content: "Provide a name, email or phone fragment of at least 2 characters.", isError: true)
        }
        let store = CNContactStore()
        do {
            if CNContactStore.authorizationStatus(for: .contacts) != .authorized {
                guard try await store.requestAccess(for: .contacts) else {
                    return ToolResult(requestID: request.id, content: "Contacts access was not granted (System Settings → Privacy & Security → Contacts).", isError: true)
                }
            }
            let keys: [CNKeyDescriptor] = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                                           CNContactEmailAddressesKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
            var found: [CNContact] = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: keys)
            if query.contains("@") {
                found += (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingEmailAddress: query), keysToFetch: keys)) ?? []
            } else if query.filter(\.isNumber).count >= 4 {
                found += (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: query)), keysToFetch: keys)) ?? []
            }
            var seen: Set<String> = []
            let lines = found.filter { seen.insert($0.identifier).inserted }.prefix(25).map { contact -> String in
                let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                let emails = contact.emailAddresses.map { $0.value as String }
                let phones = contact.phoneNumbers.map { $0.value.stringValue }
                return "\(name.isEmpty ? contact.organizationName : name)" +
                    (emails.isEmpty ? "" : " — " + emails.joined(separator: ", ")) +
                    (phones.isEmpty ? "" : " — " + phones.joined(separator: ", "))
            }
            return ToolResult(requestID: request.id, content: lines.isEmpty ? "No contact matches “\(query)”." : lines.joined(separator: "\n"))
        } catch {
            return ToolResult(requestID: request.id, content: "Contacts: \(error.localizedDescription)", isError: true)
        }
    }

    public func cancel(requestID: String) async {}
}
