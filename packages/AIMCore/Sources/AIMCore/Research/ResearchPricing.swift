import Foundation

/// Admission estimate only, never a receipt or a guaranteed provider-enforced price ceiling.
/// Reviewed 2026-10-17: https://exa.ai/pricing and https://exa.ai/docs/contents/quickstart
/// (Fast, three results, highlights included); https://brave.com/search/api/ (Search plan).
/// A stale estimate becomes unavailable rather than silently retaining an old rate.
public enum AIMResearchPricing {
    public static let reviewedAt = Date(timeIntervalSince1970: 1_792_195_200) // 2026-10-17 UTC
    public static func searchEstimateUSD(mode: AIMResearchMode, at date: Date = .now) -> Double? {
        guard date >= reviewedAt, date.timeIntervalSince(reviewedAt) <= 30 * 86_400 else { return nil }
        switch mode { case .exa: return 0.007; case .brave: return 0.005; case .hosted: return nil }
    }
}
