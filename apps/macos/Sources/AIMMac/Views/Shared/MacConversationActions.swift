import AIMApplication
import AIMCore
import AVKit
import SwiftUI

/// Older summary of a run's actions; opens them in the Actions tab of the right panel.
struct MacConversationActions: View {
    @Environment(AppModel.self) private var model
    let actions: [ConversationAction]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MacToolGroupView(tools: actions, live: actions.contains { $0.state == .running || $0.state == .waiting }, turnTools: actions)
        }.frame(maxWidth: 760, alignment: .leading)
    }
}

/// Answer text with citation pills; a pill opens the Sources tab on the cited source.
struct MacSourceMarkdown: View {
    @Environment(AppModel.self) private var model
    let text: String
    var sources: [ConversationSource]?
    let appearance: ConversationAppearance
    var searchQuery: String = ""
    var messageID: UUID?
    var body: some View {
        let projection = ConversationSourceProjection(text: text, sources: sources)
        NativeMarkdownView(source: projection.citedText, appearance: appearance, searchQuery: searchQuery)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == SourceCitationLink.scheme else { return .systemAction }
                guard let source = SourceCitationLink.sources(url, in: projection.sources).first else { return .discarded }
                model.requestedWorkbench = .init(kind: .sources, messageID: messageID, focusID: source.id)
                return .handled
            })
    }
}

struct MacPreparedVideoPreview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let attachment: TextAttachment
    let video: PreparedVideoAttachment
    @State private var player: AVPlayer?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(video.name).font(.headline); Spacer(); Button("Close") { dismiss() } }
            if let player { MacVideoPlayer(player: player).frame(height: 320) }
            else { Text("Original remains on \(video.originDeviceName).").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                LazyVGrid(columns: [.init(.adaptive(minimum: 140))]) {
                    ForEach(video.frames) { frame in
                        VStack {
                            if let image = NSImage(data: frame.jpeg) { Image(nsImage: image).resizable().scaledToFit().frame(height: 120) }
                            Text("\(frame.seconds, specifier: "%.2f") s").font(.caption)
                        }
                    }
                }
                Text(video.transcript ?? video.audioNotice ?? "Local transcript unavailable").textSelection(.enabled).padding(.vertical)
            }
        }.padding(24).frame(width: 640, height: 640)
        .task {
            if let root = model.paths?.applicationSupport, let url = PrivateInputMedia.original(root: root, accountID: model.account.accessUser?.id, attachmentID: attachment.id) { player = AVPlayer(url: url) }
        }
        .onDisappear { player?.pause(); player = nil }
    }
}

/// Use AVKit's AppKit player directly. The SwiftUI VideoPlayer overlay crashes
/// while initializing its generic superclass on macOS 27 with this toolchain.
struct MacVideoPlayer: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
