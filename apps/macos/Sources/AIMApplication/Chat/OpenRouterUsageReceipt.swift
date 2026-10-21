import Foundation

/// OpenRouter's opt-in `usage.cost` is a provider-reported USD receipt, not a
/// predicted upper bound. Decode directly to Decimal before accounting.
public enum OpenRouterUsageReceipt {
    private struct Envelope: Decodable {
        struct Usage: Decodable { let cost: Decimal? }
        let usage: Usage?
    }

    public static func costUSD(in data: Data) -> String? {
        guard let cost = try? JSONDecoder().decode(Envelope.self, from: data).usage?.cost,
              cost >= 0, cost <= 1_000_000_000 else { return nil }
        let text = NSDecimalNumber(decimal: cost).stringValue
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty, parts[0].count <= 10,
              parts[0].allSatisfy(\.isNumber),
              parts.count == 1 || (!parts[1].isEmpty && parts[1].count <= 18 && parts[1].allSatisfy(\.isNumber)) else {
            // A receipt too precise for the ledger stays unknown rather than
            // failing an otherwise successful provider response.
            return nil
        }
        return text
    }

    public static func costUSD(in payload: String) -> String? {
        costUSD(in: Data(payload.utf8))
    }
}
