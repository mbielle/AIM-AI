import AIMCore
import Foundation

/// Presentation only: the full provider catalog remains available on request.
public enum ModelCatalogPresentation {
    public static func recent(_ models: [ChatModel], grouped: Bool = false) -> [ChatModel] {
        let groups = Dictionary(grouping: models) { grouped ? $0.provider : "" }
        return groups.keys.sorted().flatMap { key -> [ChatModel] in
            let candidates = (groups[key] ?? []).filter {
                // Prefer rolling model names to dated snapshots and specialized variants.
                $0.id.range(of: #"-\d{4}-\d{2}-\d{2}|-\d{8}$|:free$|:extended$"#, options: .regularExpression) == nil
            }
            return Array(candidates.sorted {
                let a = $0.created ?? 0, b = $1.created ?? 0
                if a != b { return a > b }
                return $0.id.compare($1.id, options: .numeric) == .orderedDescending
            }.prefix(4))
        }
    }
}
