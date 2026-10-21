import AIMAgentKit
import AppKit
import SwiftUI

/// Bundled marks, available offline in both the selector and its chat-bar chip.
struct AgentEngineLogo: View {
    let engine: AgentEngineID
    var size: CGFloat = 24

    var body: some View {
        Group {
            switch engine {
            case .aim:
                AIMLogoView(size: size)
            case .openClaw:
                bundledLogo("openclaw-logo")
            case .hermes:
                bundledLogo("hermesagent", template: true)
            case .externalStdio:
                Image(systemName: "terminal").resizable().scaledToFit()
                    .padding(3).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // SwiftPM ships these as PNG files, not asset-catalog named images.
    // Resolve the resource URL explicitly so packaged apps render the marks too.
    @MainActor private static var images: [String: NSImage] = [:]

    @ViewBuilder private func bundledLogo(_ name: String, template: Bool = false) -> some View {
        if let image = Self.bitmap(named: name) {
            Image(nsImage: image).resizable()
                .renderingMode(template ? .template : .original)
                .scaledToFit().foregroundStyle(.primary)
        } else {
            Image(systemName: "cpu").resizable().scaledToFit()
                .foregroundStyle(.secondary)
        }
    }

    @MainActor private static func bitmap(named name: String) -> NSImage? {
        if let image = images[name] { return image }
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        images[name] = image
        return image
    }
}

struct AgentEngineMenuRow: View {
    let status: EngineStatus
    let title: String
    @Environment(AppModel.self) private var model
    @Environment(\.aimMenuDismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var selected: Bool { model.selectedAgentEngineID == status.id }

    var body: some View {
        Group {
            if status.isInstalled && model.agentInstallProgress[status.id] == nil {
                HStack(spacing: 6) {
                    Button {
                        dismiss()
                        model.selectAgentEngine(status.id)
                    } label: {
                        HStack(spacing: 10) {
                            name
                            Spacer(minLength: 12)
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .padding(.horizontal, 9).padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.aimHover(radius: 7))
                    .disabled(model.selectedConversationID != nil)
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    if let version = model.agentUpdateAvailable[status.id] {
                        actionButton("Mettre à jour", icon: "arrow.down.circle") { model.downloadAgent(status.id, select: false) }
                            .aimTooltip("Version vérifiée \(version) disponible. L’ancienne reste utilisable pendant la mise à jour.")
                            .padding(.trailing, 6)
                    }
                }
                .contextMenu {
                    if status.id != .aim {
                        if model.agentUpdateAvailable[status.id] != nil {
                            Button("Mettre à jour") { model.downloadAgent(status.id, select: false) }
                        }
                        Button("Désinstaller", role: .destructive) { model.uninstallAgent(status.id) }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    name
                    Spacer(minLength: 12)
                    if let progress = model.agentInstallProgress[status.id] {
                        Text("\(progress.percent) %")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .aimTooltip(progress.message)
                        actionButton("Annuler", icon: "xmark") {
                            model.cancelAgentDownload(status.id)
                        }
                    } else {
                        if let error = model.agentInstallErrors[status.id] {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(.red)
                                .aimTooltip(error)
                                .accessibilityLabel("Échec du téléchargement : \(error)")
                        }
                        actionButton(model.agentInstallErrors[status.id] == nil ? "Télécharger" : "Réessayer",
                                     icon: "arrow.down") {
                            model.downloadAgent(status.id)
                        }
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 8)
            }
        }
        .frame(width: 316, alignment: .leading)
    }

    private var name: some View {
        HStack(spacing: 10) {
            AgentEngineLogo(engine: status.id)
            Text(title).font(.system(size: 13)).foregroundStyle(.primary)
        }
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .medium))
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(AIMTheme.cardBorder(scheme)))
        }
        .buttonStyle(.aimHover(radius: 7))
        .accessibilityLabel("\(title) \(self.title)")
    }
}
