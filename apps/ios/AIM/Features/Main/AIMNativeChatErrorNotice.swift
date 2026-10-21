import SwiftUI
import UIKit

/// A floating error outside composer layout. Expanding dismisses the keyboard; no action submits a request.
struct AIMNativeChatErrorNotice: View {
    let chat: NativeChatStore
    @State private var saving = false
    @State private var saveFailed = false
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if let message = chat.errorMessage {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        if !expanded {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { expanded.toggle() }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.circle").font(.body).padding(.top, 2)
                            Text(message).font(.subheadline).lineLimit(expanded ? nil : 2)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold)).padding(.top, 4)
                        }.frame(minHeight: 44, alignment: .top).contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("native-chat-error-expand")
                    .accessibilityValue(Text(expanded ? LocalizedStringKey("notice.expanded") : LocalizedStringKey("notice.collapsed")))
                    .accessibilityHint(Text(expanded ? LocalizedStringKey("notice.collapse_hint") : LocalizedStringKey("notice.expand_hint")))
                    Button { chat.errorMessage = nil } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }.accessibilityLabel("Dismiss").accessibilityIdentifier("native-chat-error-dismiss")
                }
                if chat.errorNoticeKind == .webSearchBudget {
                    Button {
                        saving = true
                        saveFailed = false
                        Task { @MainActor in
                            let saved = await chat.disableAutomaticWebSearch()
                            saving = false
                            saveFailed = !saved
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if saving { ProgressView().controlSize(.small) }
                            Text(saving ? LocalizedStringKey("chat.error.web_budget.saving") : LocalizedStringKey("chat.error.web_budget.action"))
                        }
                    }
                    .font(.footnote.weight(.semibold))
                    .disabled(saving)
                    .accessibilityIdentifier("native-chat-disable-web-search")
                    if saveFailed {
                        Text("chat.error.web_budget.save_failed").font(.footnote)
                    }
                }
            }
            .foregroundStyle(.primary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { surface }
            .buttonStyle(.plain)
            .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
            .onChange(of: message) { _, _ in expanded = false }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("native-chat-error-notice")
        }
    }

    @ViewBuilder private var surface: some View {
        if reduceTransparency {
            RoundedRectangle(cornerRadius: 22).fill(Color(uiColor: .secondarySystemBackground))
        } else if #available(iOS 26.0, *) {
            RoundedRectangle(cornerRadius: 22).fill(.clear).glassEffect(.regular, in: .rect(cornerRadius: 22))
        } else {
            RoundedRectangle(cornerRadius: 22).fill(.regularMaterial)
        }
    }
}
