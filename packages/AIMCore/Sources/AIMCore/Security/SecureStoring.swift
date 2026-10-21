import Foundation

public protocol SecureStoring: Sendable {
    func store(_ data: Data, forKey key: String) throws
    func readData(forKey key: String) throws -> Data?
    func removeData(forKey key: String) throws
}
