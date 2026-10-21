import Foundation

/// Reserves only a single, unambiguous provider SKU. Display prices are not zero-cost defaults.
public enum MediaCostPolicy {
    public static func upperBound(for job: MediaJob) -> Double? {
        guard job.model.route == .openRouter, job.options.references.isEmpty,
              job.model.fixedPrice == true, let price = job.model.priceUSD, price.isFinite, price >= 0 else { return nil }
        // Image discovery marks this unit only when every endpoint exposes one identical output-image charge.
        if job.model.kind == .image, job.model.priceUnit == "image" { return price }
        // A duration default is not a known maximum. Video variants/audio may add charges.
        if job.model.kind == .video, job.model.priceUnit == "second",
           let duration = job.options.durationSeconds, job.model.durations.contains(duration), (!job.model.supportsAudio || job.options.generateAudio == false) {
            return price * Double(duration)
        }
        return nil
    }
}
