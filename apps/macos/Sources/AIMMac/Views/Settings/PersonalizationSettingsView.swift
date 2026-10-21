import AIMApplication
import AppKit
import SwiftUI

struct PersonalizationSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false
    @State private var agentText = ""
    @State private var agentSaved = ""
    @State private var agentError: String?

    var body: some View {
        SettingsPage("Personalization", subtitle: "Your instructions and what AIM remembers about you.") {
            SettingsGroup("Personal instructions", footer: "Changes apply to future requests, including existing conversations. They do not change project instructions, tool approvals or past messages.") {
                SettingsRow("Instructions", description: "Saved on this Mac. When on, they are sent to the selected AI provider with every new request in Chat, Code and Agent. Do not put passwords or API keys here.") {
                    SettingsStatus(text: model.settings.personalization?.isEnabled == true ? "On" : "Off",
                                   color: model.settings.personalization?.isEnabled == true ? .green : .secondary)
                    Button("Edit…") { editing = true }.buttonStyle(.settings)
                }
            }
            SettingsGroup("Agent instructions (AGENTS.md)",
                          description: "Read by every Agent and Code task, before the project's own AGENTS.md or CLAUDE.md. Use it for your conventions: tools, style, what to avoid.") {
                SettingsBlock {
                    TextEditor(text: $agentText)
                        .font(.system(size: 13, design: .monospaced)).frame(height: 160)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    HStack {
                        Text("\(agentText.count) / 16,000 characters").font(.caption).foregroundStyle(.secondary)
                        if let agentError { Text(agentError).font(.caption).foregroundStyle(.red) }
                        Spacer()
                        Button("Show file") {
                            NSWorkspace.shared.activateFileViewerSelecting([ProjectInstructionsContext.globalFile])
                        }.buttonStyle(.settings).disabled(agentSaved.isEmpty)
                        Button("Save") {
                            do { try model.saveAgentInstructions(agentText); agentSaved = agentText; agentError = nil }
                            catch { agentError = error.localizedDescription }
                        }.buttonStyle(.settingsPrimary).disabled(agentText == agentSaved)
                    }
                }
            }
            CustomAgentsSettingsView()
            NativePluginsSettingsView()
            SettingsGroup("Memory") {
                SettingsToggleRow("Memories from Agent and Code", description: "Let AIM suggest memories from conversations that used tools (files, browser, connectors).",
                                  isOn: Binding(get: { model.preferences.memoriesFromToolChats },
                                                set: { value in model.updatePreferences { $0.memoriesFromToolChats = value } }))
            }
            MemorySettingsView(embedded: true)
        }
        .sheet(isPresented: $editing) { PersonalizationEditor() }
        .onAppear { agentText = model.agentInstructions; agentSaved = agentText }
    }
}

private struct PersonalizationEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = Personalization()
    @State private var original = Personalization()
    @State private var owner: AccountMemoryOwner = .local
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDiscard = false
    private var dirty: Bool { draft != original }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Personal instructions").font(.title2)
            Toggle("Send these preferences with future requests", isOn: $draft.isEnabled)
            Text("For example: preferred language, response length, explanation style or coding conventions. Project-specific instructions and the current task take precedence.")
                .foregroundStyle(.secondary).font(.callout)
            TextEditor(text: $draft.instructions).font(.body).border(.quaternary)
                .accessibilityLabel("Personal instructions text")
            Text("\(draft.instructions.count) / 8,000 characters").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Clear text") { draft.instructions = ""; draft.isEnabled = false }
                Spacer()
                Button("Cancel") { if dirty { confirmDiscard = true } else { dismiss() } }
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    Task {
                        do { try await model.savePersonalization(draft, expectedOwner: owner); dismiss() }
                        catch { self.error = error.localizedDescription }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).disabled(!dirty)
            }
        }.padding(24).frame(width: 600, height: 450).disabled(saving)
            .interactiveDismissDisabled(dirty || saving)
            .onAppear { draft = model.settings.personalization ?? .init(); original = draft; owner = model.chatPreferenceOwner }
            .confirmationDialog("Discard unsaved changes?", isPresented: $confirmDiscard) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) { }
            }
    }
}
