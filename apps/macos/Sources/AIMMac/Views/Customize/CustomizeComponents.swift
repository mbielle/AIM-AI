import AIMCore
import AIMApplication
import AppKit
import SwiftUI

/// A logo from a URL, decoded as a bitmap only (never SVG), cached for the session.
struct RemoteLogo: View {
    let url: String?
    var fallback = "puzzlepiece.extension"
    var size: CGFloat = 40
    @State private var image: NSImage?

    init(url: String?, fallback: String = "puzzlepiece.extension", size: CGFloat = 40) {
        self.url = url; self.fallback = fallback; self.size = size
        // Already loaded elsewhere (a card): shown from the first frame.
        _image = State(initialValue: RemoteLogoCache.shared.cached(url))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(Color.white)
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
                    .padding(size * 0.12)
            } else {
                Image(systemName: fallback).font(.system(size: size * 0.42)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(Color.black.opacity(0.08)))
        .task(id: url) {
            if image == nil, let loaded = await RemoteLogoCache.shared.image(url) {
                withAnimation(.easeOut(duration: 0.15)) { image = loaded }
            }
        }
    }
}

final class RemoteLogoCache: @unchecked Sendable {
    static let shared = RemoteLogoCache()
    private let lock = NSLock()
    private var images: [String: NSImage] = [:]

    func cached(_ address: String?) -> NSImage? {
        guard let address else { return nil }
        lock.lock(); defer { lock.unlock() }
        return images[address]
    }

    func image(_ address: String?) async -> NSImage? {
        guard let address, let url = URL(string: address) else { return nil }
        if let known = cached(address) { return known }
        guard let (data, _) = try? await RuntimeManagedNetworkSession.shared.data(from: url),
              let image = CreatorAvatarCache.bitmap(from: data) else { return nil }
        store(image, for: address)
        return image
    }

    private func store(_ image: NSImage, for address: String) {
        lock.lock(); defer { lock.unlock() }
        images[address] = image
    }
}

/// A store card, as in Claude's Customize: icon, title, two lines, origin, and a + / ✓ button.
struct StoreCard<Icon: View>: View {
    let title: String
    var verified = false
    let subtitle: String
    let footer: String
    let installed: Bool
    var soon = false
    var busy = false
    @ViewBuilder let icon: () -> Icon
    let open: () -> Void
    let install: () -> Void
    /// Starts loading the item's page while the pointer rests on the card.
    var prefetch: (() -> Void)?
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false
    @State private var plusHovered = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 16) {
                icon()
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                        if verified {
                            Image(systemName: "checkmark.seal").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(footer).font(.system(size: 12.5)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 44)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .background(AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            // Hover: only the outline darkens (no gray fill).
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hovered ? Color.primary.opacity(scheme == .dark ? 0.35 : 0.28) : AIMTheme.cardBorder(scheme)))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) { action.padding(16) }
        .onHover { inside in
            hovered = inside
            if inside { prefetch?() }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    @ViewBuilder private var action: some View {
        if soon {
            Text("Soon").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 9).padding(.vertical, 5).background(Color.primary.opacity(0.06), in: Capsule())
        } else if busy {
            ProgressView().controlSize(.small).frame(width: 34, height: 34)
        } else {
            Button(action: install) {
                Image(systemName: installed ? "checkmark" : "plus").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(installed ? Color.green : Color.primary)
                    .frame(width: 34, height: 34)
                    .background(installed ? Color.green.opacity(0.14) : AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(installed ? .clear : plusHovered ? Color.primary.opacity(0.35) : AIMTheme.cardBorder(scheme)))
            }
            .buttonStyle(.plain)
            .onHover { plusHovered = $0 }
            .help(installed ? "Installed" : "Add")
            .accessibilityLabel(installed ? "\(title) installed" : "Add \(title)")
        }
    }
}

/// The square icon of skills and plugins (SF Symbol in a bordered tile).
struct StoreIcon: View {
    let symbol: String
    var size: CGFloat = 48
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.4)).foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
    }
}

/// "New skills          View all →"
struct StoreSectionHeader: View {
    let title: String
    var count: Int?
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 17, weight: .semibold))
            if let count {
                Text(count.formatted()).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(Color.primary.opacity(0.06), in: Capsule())
            }
            Spacer()
            if let action {
                Button(action: action.run) {
                    HStack(spacing: 6) { Text(action.title); Image(systemName: "arrow.right") }.font(.system(size: 14))
                }
                .buttonStyle(TextLinkStyle())
            }
        }
    }
}

/// A category tile with an icon and a count (Skills) or a chip (Connectors).
struct StoreCategoryTile: View {
    let title: String
    let icon: String
    let count: Int
    let open: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 16) {
                StoreIcon(symbol: icon, size: 60)
                Text(title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                Spacer()
                Text(count.formatted()).font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(18)
            .background(AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hovered ? Color.primary.opacity(scheme == .dark ? 0.35 : 0.28) : AIMTheme.cardBorder(scheme)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

struct StoreChip: View {
    let title: String
    let count: Int
    var selected = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13.5))
                Text(count.formatted()).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).frame(height: 36)
            .background(selected ? Color.primary.opacity(0.08) : AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
        }
        .buttonStyle(.plain)
    }
}

enum StoreFormat {
    static func installs(_ value: Int?) -> String? {
        guard let value else { return nil }
        let text = value >= 1_000_000 ? (Double(value) / 1_000_000).formatted(.number.precision(.fractionLength(0...1))) + "M"
            : value >= 1_000 ? (Double(value) / 1_000).formatted(.number.precision(.fractionLength(0...1))) + "K" : "\(value)"
        return text + " installs"
    }

    /// "mattpocock/skills" → "mattpocock".
    static func publisher(_ source: String) -> String {
        let owner = String(source.split(separator: "/").first ?? Substring(source))
        return owner == "anthropics" ? "Anthropic" : owner == "openai" ? "OpenAI" : owner
    }

    static func skillIcon(_ name: String) -> String {
        let text = name.lowercased()
        switch true {
        case text.contains("pdf"), text.contains("doc"): return "doc.text"
        case text.contains("xlsx"), text.contains("sheet"), text.contains("data"): return "tablecells"
        case text.contains("ppt"), text.contains("slide"): return "rectangle.on.rectangle"
        case text.contains("design"), text.contains("ui"), text.contains("image"): return "photo"
        case text.contains("test"), text.contains("debug"): return "checklist"
        case text.contains("git"), text.contains("code"), text.contains("api"): return "chevron.left.forwardslash.chevron.right"
        case text.contains("write"), text.contains("copy"): return "text.quote"
        default: return "scroll"
        }
    }

    static func pluginIcon(_ category: String?) -> String {
        switch category ?? "" {
        case "development": "chevron.left.forwardslash.chevron.right"
        case "productivity": "checklist"
        case "database": "cylinder.split.1x2"
        case "monitoring": "waveform.path.ecg"
        case "security": "lock.shield"
        case "deployment": "shippingbox"
        case "design": "paintpalette"
        case "automation": "gearshape.2"
        default: "puzzlepiece.extension"
        }
    }
}


/// Skills · Connectors · Plugins: a soft box under the pointer, a filled one when selected.
struct CustomizeTabButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: selected ? .medium : .regular))
                .foregroundStyle(selected || hovered ? .primary : .secondary)
                .padding(.horizontal, 15).frame(height: 38)
                .background(Color.primary.opacity(selected ? (scheme == .dark ? 0.1 : 0.06) : hovered ? (scheme == .dark ? 0.06 : 0.035) : 0),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// A store skill card that fetches its own one-line description (only this card redraws).
struct SkillStoreCard: View, @MainActor Equatable {
    let skill: StoreSkill
    let installed: Bool
    let busy: Bool
    let open: (StoreSkill) -> Void
    let install: () -> Void
    @State private var description: String?

    static func == (lhs: SkillStoreCard, rhs: SkillStoreCard) -> Bool {
        lhs.skill == rhs.skill && lhs.installed == rhs.installed && lhs.busy == rhs.busy
    }

    var body: some View {
        let text = skill.description ?? description
        StoreCard(title: skill.name, subtitle: text ?? " ",
                  footer: (["by " + StoreFormat.publisher(skill.source), StoreFormat.installs(skill.installs)].compactMap { $0 }).joined(separator: " · "),
                  installed: installed, busy: busy,
                  icon: { RemoteLogo(url: CustomizeCatalog.ownerAvatar(skill.owner), fallback: StoreFormat.skillIcon(skill.name), size: 48) },
                  open: {
                      var described = skill
                      described.description = text
                      open(described)
                  }, install: install,
                  prefetch: { Task { await CustomizeStore.shared.prefetch(skill) } })
            .task(id: skill.id) {
                guard skill.description == nil, description == nil else { return }
                description = await CustomizeStore.shared.description(skill)
            }
    }
}


/// A soft placeholder of the content's size while it loads (the page does not jump).
struct LoadingBlock: View {
    var height: CGFloat
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(pulse ? 0.06 : 0.035))
            .frame(height: height)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
    }
}
