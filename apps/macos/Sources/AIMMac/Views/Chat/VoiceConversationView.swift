import AIMMacPlatform
import SwiftUI

/// The live voice conversation above the composer: state, recent lines, end button.
struct VoiceConversationView: View {
    let session: any VoiceConversation
    let end: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon).symbolEffect(.pulse, isActive: session.state == .listening || session.state == .speaking)
                    .foregroundStyle(Color.accentColor)
                Text(status).font(.system(size: 13, weight: .medium))
                Spacer()
                if session.state == .speaking {
                    Button("Stop speaking") { session.interrupt() }.buttonStyle(.settings).controlSize(.small)
                }
                Button("End", action: end).buttonStyle(.settings).controlSize(.small)
            }
            ForEach(session.lines.suffix(4)) { line in
                Text((line.speaker == .person ? "You: " : line.speaker == .aim ? "AIM: " : "Agent: ") + line.text)
                    .font(.caption).foregroundStyle(line.speaker == .person ? .primary : .secondary).lineLimit(3)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }

    private var icon: String {
        switch session.state {
        case .speaking: "speaker.wave.2.fill"
        case .working: "gearshape.2"
        case .failed: "exclamationmark.triangle"
        default: "waveform"
        }
    }

    private var status: String {
        switch session.state {
        case .idle: "Voice ended"
        case .connecting: "Connecting…"
        case .listening: "Listening — speak any time"
        case .thinking: "Thinking…"
        case .speaking: session is RealtimeVoiceSession ? "Speaking — talk to interrupt" : "Speaking"
        case .working(let request): "AIM is working: \(request.prefix(60))"
        case .failed(let message): message
        }
    }
}
