import Foundation
import Supabase

enum SupabaseAuthStorageConfiguration {
    /// Must never equal Supabase Swift's legacy migration source
    /// (`supabase.session`), otherwise the SDK copies and then deletes the
    /// session at the same key on every read.
    static let sessionKey = "com.aimai.ios.supabase.session"
}

struct SupabaseAuthLocalStorage: AuthLocalStorage, Sendable {
    private let secureStore: any SecureStoring

    init(secureStore: any SecureStoring) {
        self.secureStore = secureStore
    }

    func store(key: String, value: Data) throws {
        try secureStore.store(value, forKey: key)
    }

    func retrieve(key: String) throws -> Data? {
        try secureStore.readData(forKey: key)
    }

    func remove(key: String) throws {
        try secureStore.removeData(forKey: key)
    }
}
