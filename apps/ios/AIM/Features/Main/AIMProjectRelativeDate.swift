import Foundation
import SwiftUI

/// A single coarse unit keeps project history readable instead of counting seconds.
/// Values refresh when the surrounding view updates; no per-row timer is scheduled.
enum AIMProjectRelativeDate {
    static func string(for date: Date, relativeTo now: Date = .now, locale: Locale = .current) -> String {
        let interval = date.timeIntervalSince(now)
        let elapsed = abs(interval)
        let sign = interval < 0 ? -1 : 1
        var components = DateComponents()
        if !elapsed.isFinite || elapsed < 60 {
            components.second = 0
        } else if elapsed < 3_600 {
            components.minute = sign * Int(elapsed / 60)
        } else if elapsed < 86_400 {
            components.hour = sign * Int(elapsed / 3_600)
        } else {
            // Clamping also makes malformed dates safe to present.
            components.day = sign * Int(min(elapsed / 86_400, 3_650_000))
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = elapsed < 60 ? .named : .numeric
        return formatter.localizedString(from: components)
    }
}

struct AIMProjectRelativeDateLabel: View {
    let date: Date
    @Environment(\.locale) private var locale
    var body: some View {
        Text(AIMProjectRelativeDate.string(for: date, locale: locale))
    }
}
