import AIMCore
import AIMApplication
import SwiftUI

/// One model in the picker. The whole card is the main action (choose the model, or open
/// its sheet when browsing); small buttons on the card do the rest.
struct ModelCard: View {
    enum Mode: Equatable {
        /// My models: click chooses; pin and (i) appear on hover.
        case select(pinned: Bool)
        /// Add models: click opens the sheet; only + adds. `locked`: part of the default selection.
        case add(added: Bool, locked: Bool = false)
    }

    let name: String
    let creator: String
    let meta: String
    let capabilities: Set<ChatModel.Capability>
    let selected: Bool
    let mode: Mode
    let primary: () -> Void
    var info: () -> Void = {}
    var pin: () -> Void = {}
    var toggleAdded: () -> Void = {}
    /// Local models: opens their own settings (a third button beside (i) and the pin).
    var settings: (() -> Void)?
    var logo: AnyView?

    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    var body: some View {
        Button(action: primary) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    if let logo { logo } else { ModelCreatorLogo(creator: creator, size: 20) }
                    Text(name).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                    Spacer(minLength: accessoryWidth)
                }
                HStack(spacing: 6) {
                    Text(meta).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    // Cards show the three that matter most; the sheet lists them all.
                    CapabilityIcons(capabilities: capabilities.intersection([.vision, .tools, .reasoning]))
                }
                .padding(.leading, 29)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A constant base with a light layer on top: animating opaque white into a
            // translucent gray passed through a dark gray (the old flicker).
            .background(base, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .background(alignment: .center) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AIMTheme.card(scheme))
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AIMTheme.hover(scheme)).opacity(hovered && !selected ? 1 : 0).allowsHitTesting(false))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? AIMTheme.toggleOn : AIMTheme.cardBorder(scheme), lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(CardPressStyle())
        .overlay(alignment: .topTrailing) { accessories.padding(.top, 7).padding(.trailing, 8) }
        .onHover { inside in withAnimation(.easeOut(duration: 0.1)) { hovered = inside } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name), \(meta)")

        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var base: Color {
        selected ? AIMTheme.toggleOn.opacity(scheme == .dark ? 0.12 : 0.06) : .clear
    }

    private var accessoryWidth: CGFloat {
        switch mode { case .select: settings == nil ? 52 : 78; case .add: 28 }
    }

    /// Accessories keep their place in the layout (only their opacity changes), so moving
    /// the pointer over them never changes the card's hover area.
    @ViewBuilder private var accessories: some View {
        HStack(spacing: 2) {
            switch mode {
            case .select(let pinned):
                ZStack {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(AIMTheme.toggleOn)
                        .opacity(selected && !hovered ? 1 : 0)
                    smallButton("info.circle", help: "Model details", action: info)
                        .opacity(hovered ? 1 : 0).allowsHitTesting(hovered)
                }
                if let settings {
                    smallButton("slider.horizontal.3", help: "Model settings", action: settings)
                        .opacity(hovered ? 1 : 0).allowsHitTesting(hovered)
                }
                smallButton(pinned ? "pin.fill" : "pin", help: pinned ? "Unpin" : "Pin to the top", action: pin)
                    .foregroundStyle(pinned ? Color.primary : Color.secondary)
                    .opacity(pinned || hovered ? 1 : 0).allowsHitTesting(pinned || hovered)
            case .add(let added, let locked):
                smallButton(added ? "checkmark.circle.fill" : "plus.circle",
                            help: locked ? "Included in your models by default" : added ? "Remove from my models" : "Add to my models",
                            action: toggleAdded)
                    .foregroundStyle(added ? AIMTheme.toggleOn : Color.secondary)
                    .disabled(locked)
            }
        }
    }

    private func smallButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13)).frame(width: 24, height: 24)
        }
        .buttonStyle(.aimHover(radius: 6))
        .help(help)
        .accessibilityLabel(help)
    }
}

struct CapabilityIcons: View {
    let capabilities: Set<ChatModel.Capability>

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Self.order.filter(capabilities.contains), id: \.self) { capability in
                Image(systemName: Self.icon(capability)).font(.system(size: 10)).foregroundStyle(.tertiary)
                    .help(Self.title(capability))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.order.filter(capabilities.contains).map(Self.title).joined(separator: ", "))
    }

    static let order: [ChatModel.Capability] = [.vision, .tools, .reasoning, .files, .audio, .imageOutput]

    static func icon(_ capability: ChatModel.Capability) -> String {
        switch capability {
        case .vision: "eye"
        case .tools: "wrench.and.screwdriver"
        case .reasoning: "brain"
        case .files: "doc"
        case .audio: "waveform"
        case .imageOutput: "photo"
        }
    }

    static func title(_ capability: ChatModel.Capability) -> String {
        switch capability {
        case .vision: "Reads images"
        case .tools: "Uses tools"
        case .reasoning: "Reasoning"
        case .files: "Reads files"
        case .audio: "Hears audio"
        case .imageOutput: "Creates images"
        }
    }
}

private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.82 : 1)
    }
}

extension ModelCard: Equatable {
    /// Cards redraw only when what they show changes (closures are ignored).
    nonisolated static func == (lhs: ModelCard, rhs: ModelCard) -> Bool {
        lhs.name == rhs.name && lhs.creator == rhs.creator && lhs.meta == rhs.meta && lhs.capabilities == rhs.capabilities
            && lhs.selected == rhs.selected && lhs.mode == rhs.mode
    }
}
