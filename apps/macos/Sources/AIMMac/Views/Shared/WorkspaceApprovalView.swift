import AIMAgentKit
import SwiftUI

/// Replaces the composer while an exact host action is awaiting consent.
/// The compact shell matches the question/composer width; the action's exact
/// parameters remain available and high-risk actions open them by default.
struct WorkspaceApprovalView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let approval: PendingToolApproval
    @State private var deciding = false
    @State private var detailsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: categorySymbol)
                Text(approval.category?.title ?? "Permission")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)

            Text(approvalTitle)
                .font(.system(size: 14, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)

            if let target = actionTarget {
                Text(target)
                    .font(.system(size: 12, design: approval.toolName == "delegate_task" ? .default : .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(approval.toolName == "delegate_task" ? 3 : nil)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let note = approval.safetyNote {
                Label {
                    Text("Safety check: ").fontWeight(.semibold) + Text(note)
                } icon: { Image(systemName: "shield.lefthalf.filled") }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("approval-safety-note")
            }

            if let warning = riskWarning {
                Text(warning)
                    .font(.system(size: 11))
                    .foregroundStyle(approval.risk == .computerAction || approval.risk == .destructive || approval.risk == .missionDefinition ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if approval.priorUncertainAction {
                Text("An identical action in this mission ended without a reliable tool result. Review the current target before allowing this new attempt; the previous effect may already have happened.")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }

            DisclosureGroup("Exact action and data sharing", isExpanded: $detailsExpanded) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("The result will be sent to \(model.toolRunProvider?.name ?? "the selected provider")\(model.toolRunModelID.isEmpty ? "" : " using " + model.toolRunModelID). \(scopeSentence)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(approval.toolName).fontWeight(.semibold)
                            if let path = approval.workspacePath { Text("workspace: \(path)") }
                            ForEach(approval.arguments.keys.sorted(), id: \.self) { key in
                                Text("\(key): \(approval.arguments[key] ?? "")")
                            }
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }
                    .frame(maxHeight: 140)
                    if let review = approval.review {
                        HStack(alignment: .top, spacing: 10) {
                            reviewColumn(review.beforeExists ? "Before" : "New file", review.before)
                            reviewColumn(review.afterExists ? "After" : "Move to Trash", review.after)
                        }
                        .frame(height: 125)
                    }
                    Text("The action and its returned result are recorded in this conversation's local history.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .padding(.top, 5)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if standing {
                    Button { decide(.allowAlways) } label: { Text("Always allow") }
                        .buttonStyle(.settings)
                        .help("Always allow \(approval.category?.scope ?? "this action type"), in every conversation. You can revoke it in Settings › Permissions.")
                        .accessibilityIdentifier("approval-always-allow")
                }
                Spacer()
                Button { decide(.deny) } label: {
                    HStack(spacing: 7) {
                        Text("Deny")
                        Text("Esc").foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.055), in: Capsule())
                    }
                }
                .buttonStyle(.settings)
                .keyboardShortcut(.escape, modifiers: [])
                Button { decide(standing ? .allowForSession : .allowOnce) } label: {
                    HStack(spacing: 7) {
                        Text(standing ? "Allow this conversation" : "Allow once")
                        Image(systemName: "return")
                    }
                }
                .buttonStyle(.settingsPrimary)
                .keyboardShortcut(.return, modifiers: [])
                .help(standing ? "Allow \(approval.category?.scope ?? "this action type") until this conversation ends." : "Allow only this exact action.")
                .accessibilityIdentifier(standing ? "approval-allow-conversation" : "approval-allow-once")
            }
            .controlSize(.small)
            .disabled(deciding)
        }
        .padding(.horizontal, 20).padding(.vertical, 17)
        .frame(maxWidth: 760, alignment: .leading)
        .background(AIMTheme.menuSurface(scheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
        .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.05), radius: 12, y: 3)
        .shadow(color: .black.opacity(0.045), radius: 14, y: 4)
        .onAppear { detailsExpanded = expandsByDefault }
        .onChange(of: approval.id) { _, _ in deciding = false; detailsExpanded = expandsByDefault }
        .onExitCommand { decide(.deny) }
        .accessibilityIdentifier("workspace-tool-approval")
    }

    private var expandsByDefault: Bool {
        approval.priorUncertainAction || approval.risk == .computerAction || approval.risk == .destructive || approval.risk == .missionDefinition || approval.toolName == "run_command" || approval.review != nil
    }

    /// "Always allow" and "Allow this conversation" cover the whole action type; actions that
    /// must be confirmed one by one only offer Deny and Allow once.
    private var standing: Bool { approval.accepts(.allowAlways) }

    private var scopeSentence: String {
        guard standing, let category = approval.category else { return "Allow once applies only to this action." }
        return "Allow this conversation covers \(category.scope) until this conversation ends; Always allow covers them everywhere."
    }

    private var categorySymbol: String {
        switch approval.category?.key.split(separator: ":").first.map(String.init) ?? "" {
        case "subagent": "person.2"
        case "command", "command-input": "terminal"
        case "files": "doc.badge.plus"
        case "web", "download", "open-url": "globe"
        case "browser": "safari"
        case "app", "computer", "applescript", "open": "macwindow"
        case "mcp": "puzzlepiece.extension"
        case "memory": "brain"
        case "mission": "checkmark.seal"
        case "checkpoint": "clock.arrow.circlepath"
        default: "hand.raised"
        }
    }

    private func decide(_ decision: ApprovalDecision) {
        guard !deciding else { return }
        deciding = true
        Task { await model.decideToolApproval(approval, decision: decision) }
    }

    private var actionTarget: String? {
        if approval.toolName == "delegate_task" {
            let title = approval.arguments["title"].map { "“\($0)”" }
            let route = [approval.arguments["model"] ?? "Parent's model", approval.arguments["effort"].map { $0.capitalized }]
                .compactMap { $0 }.joined(separator: " · ")
            return [title, route].compactMap { $0 }.joined(separator: " · ")
        }
        if approval.toolName == "message_subagent" { return approval.arguments["text"] }
        if ["run_command", "start_command"].contains(approval.toolName) { return approval.arguments["command"] }
        if let path = approval.arguments["path"] { return path }
        if let url = approval.arguments["url"] { return url }
        if let window = approval.arguments["window_id"] {
            let point = ["x", "y"].compactMap { approval.arguments[$0] }.joined(separator: ", ")
            return point.isEmpty ? "Window \(window)" : "Window \(window) · (\(point))"
        }
        return nil
    }

    private var riskWarning: String? {
        if ["run_command", "start_command"].contains(approval.toolName) {
            return "Runs as your macOS user outside a sandbox. It may affect files beyond the selected folder or contact the network; stopping will not undo its effects."
        }
        if ["write_command", "close_command_input"].contains(approval.toolName) {
            return "This input goes to a command running as your macOS user outside a sandbox. It may trigger file changes or network requests; check the exact handle and data."
        }
        if approval.risk == .computerAction {
            if approval.toolName == "desktop_focus_window" {
                return "AIM will activate this app window. macOS may switch Spaces or cover what you are doing. Check the window ID before allowing it."
            }
            return "AIM will control another app as your macOS user. A click or key press may submit data or cause irreversible changes; check the exact action below."
        }
        if approval.risk == .computerRead {
            return "This reads private on-screen information. Auto allows these reads after macOS permission is granted; this mode asks before sharing the result."
        }
        if approval.risk == .sensitiveRead {
            return "This reads private data that will be shared with the selected model."
        }
        if approval.risk == .missionDefinition {
            return "This check may determine whether AIM labels the mission verified. Make sure it covers the requested result; a file existing or containing text may not prove its quality."
        }
        if approval.risk == .destructive { return "This action may not be reversible. Review the exact target before continuing." }
        return nil
    }

    private var approvalTitle: String {
        switch approval.toolName {
        case "create_dir": "Allow AIM to create this directory?"
        case "copy_file": "Allow AIM to copy this file?"
        case "move_file": "Allow AIM to move this file?"
        case "trash_file": "Allow AIM to move this file to Trash?"
        case "desktop_screenshot": "Allow AIM to share this window screenshot with the model?"
        case "desktop_read_window": "Allow AIM to read this app window?"
        case "desktop_list_windows": "Allow AIM to list open app windows?"
        case "desktop_click", "desktop_move", "desktop_drag", "desktop_scroll", "desktop_type", "desktop_key", "desktop_focus_window", "desktop_press", "desktop_set_value": "Hand over your mouse and keyboard to AIM for this action?"
        case "browser_snapshot", "browser_find", "browser_take_screenshot": "Allow AIM to read this browser tab?"
        case "browser_console_messages", "browser_network_requests": "Allow AIM to inspect this tab's diagnostics?"
        case "browser_navigate", "browser_navigate_back", "browser_click", "browser_drag", "browser_hover", "browser_select_option", "browser_type", "browser_press_key", "browser_handle_dialog", "browser_tabs": "Allow AIM to control your browser?"
        case "browser_file_upload", "browser_drop": "Allow AIM to upload these workspace files?"
        case "mission_define_file_criterion": "Approve this mission success criterion?"
        case "web_fetch": "Allow AIM to retrieve this web page?"
        case "web_download": "Allow AIM to download this file into the workspace?"
        case "reminders_lists", "reminders_list", "reminders_get": "Allow AIM to read Apple Reminders?"
        case "reminders_create": "Allow AIM to create this reminder?"
        case "reminders_update": "Allow AIM to edit this reminder?"
        case "reminders_complete": "Allow AIM to change this reminder's completion status?"
        case "reminders_delete": "Permanently delete this reminder?"
        case "calendar_lists", "calendar_events", "calendar_get": "Allow AIM to read Apple Calendar?"
        case "calendar_create": "Allow AIM to create this calendar event?"
        case "calendar_update": "Allow AIM to edit this calendar event?"
        case "calendar_delete": "Permanently delete this calendar event?"
        case "notes_folders", "notes_list", "notes_search", "notes_get": "Allow AIM to read Apple Notes?"
        case "notes_create": "Allow AIM to create this Apple Note?"
        case "notes_replace": "Allow AIM to replace this Apple Note's text?"
        case "notes_append": "Allow AIM to append text to this Apple Note?"
        case "notes_delete": "Delete this Apple Note from its folder?"
        case "mail_accounts", "mail_mailboxes", "mail_messages", "mail_search", "mail_get":
            "Allow AIM to read Apple Mail?"
        case "mail_mark": "Allow AIM to change this message's read or flagged status?"
        case "mail_move": "Allow AIM to move this message to another mailbox?"
        case "mail_delete": "Delete this message from its mailbox?"
        case "mail_draft": "Allow AIM to save this Apple Mail draft?"
        case "mail_send": "Send this email to the listed recipients?"
        case "search_history": "Allow AIM to search your chat history?"
        case "search_memory": "Allow AIM to search your memory?"
        case "memory_save": "Allow AIM to save this to your memory?"
        case "search_activity": "Allow AIM to search your activity?"
        case "delegate_task": "Allow AIM to start a sub-agent?"
        case "message_subagent": "Allow AIM to message this sub-agent?"
        case "cancel_subagent": "Allow AIM to stop this sub-agent?"
        case "retry_subagent": "Allow AIM to restart this sub-agent?"
        case "run_command": "Allow AIM to run this command?"
        case "start_command": "Allow AIM to start this command?"
        case "write_command": "Allow AIM to send this input to the command?"
        case "close_command_input": "Allow AIM to close the command input?"
        case "stop_command": "Allow AIM to stop this command?"
        default: approval.review == nil ? "Allow this agent action?" : "Allow AIM to apply this file change?"
        }
    }

    private func reviewColumn(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold))
            ScrollView([.horizontal, .vertical]) {
                Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity)
    }
}
