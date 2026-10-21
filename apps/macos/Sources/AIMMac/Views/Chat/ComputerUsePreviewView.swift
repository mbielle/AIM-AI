import AIMMacPlatform
import SwiftUI

/// "AIM is using <App>": a live preview of the window the agent controls (even
/// on another desktop), its last action, and Stop. Like the screen-sharing chip
/// of other computer-use agents, the person always sees what the AI sees.
struct ComputerUsePreviewView: View {
    @State private var activity = ComputerUseActivity.shared
    @State private var expanded = false

    var body: some View {
        if let session = activity.session {
            HStack(alignment: .center, spacing: 12) {
                Button { expanded.toggle() } label: {
                    Group {
                        if let image = activity.preview {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            ZStack { Color.primary.opacity(0.06); ProgressView().controlSize(.small) }
                        }
                    }
                    .frame(width: 112, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .help("Show what AIM sees")
                .aimMenu(isPresented: $expanded, maxWidth: 740) {
                    if let image = activity.preview {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 720, maxHeight: 520)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Label("AIM is using \(session.appName)", systemImage: "rectangle.on.rectangle.angled")
                        .font(.system(size: 13, weight: .semibold))
                    Text(session.lastAction).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text("In the background: your pointer and keyboard stay yours. Its cursor appears on that window's desktop.")
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                }
                Spacer(minLength: 8)
                Button(role: .destructive) { activity.stop() } label: { Label("Stop", systemImage: "stop.circle.fill") }
                    .controlSize(.small)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.045)))
            .frame(maxWidth: 760)
            .padding(.horizontal, 26)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
