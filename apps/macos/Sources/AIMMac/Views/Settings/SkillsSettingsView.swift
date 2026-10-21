import AIMApplication
import AppKit
import SwiftUI

/// Installed `SKILL.md` skills, the Agent's proposals awaiting review, and
/// import from Claude's skills folder. Skills are instructions only: AIM never
/// runs a script from a skill folder by itself.
struct SkillsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var skills: [Skill] = []
    @State private var proposals: [Skill] = []
    @State private var disabled = SkillPreferences.disabled
    @State private var expanded: Set<String> = []
    @State private var importCandidates: [Skill] = []
    @State private var importSelection: Set<String> = []
    @State private var message: String?
    @State private var level = SkillPreferences.learningLevel

    private static let claudeSkills = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/skills", isDirectory: true)

    @State private var usage: [String: SkillUsage.Record] = [:]
    @State private var archived: [(folder: String, name: String)] = []

    var body: some View {
        SettingsPage("Skills", subtitle: "A skill is a folder with a SKILL.md file (name, description, then instructions), the format used by Claude, OpenClaw and Hermes. The model sees each enabled skill's name and description and loads the full text only when needed. Skills never grant permissions and their scripts never run automatically.") {
            if let message { SettingsNotice(message) }
            SettingsGroup("Learning", footer: "After an Agent task with \(SkillLearning.minimumToolCalls) or more tool calls ends normally, AIM sends one extra request to the conversation's model (billed to your key) to check whether it taught something reusable. Every replaced version can be restored; project skills are never changed automatically.") {
                SettingsMenuRow("Learning level", description: levelSummary, selection: $level, options: [
                    (SkillLearningLevel.off, "Off"), (.suggest, "Suggest only"), (.autonomous, "Autonomous"), (.unrestricted, "Unrestricted")])
            }
            .onChange(of: level) { _, value in SkillPreferences.learningLevel = value }
            if !proposals.isEmpty {
                SettingsGroup("Proposed by the Agent") {
                    ForEach(proposals) { proposal in proposalRow(proposal) }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Installed").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Reload") { reload() }.buttonStyle(.settings)
                    Button("Open skills folder") { openGlobalFolder() }.buttonStyle(.settings)
                }
                SettingsCard {
                    if skills.isEmpty { SettingsRow("No skill installed yet", description: "Skills in the selected folder's .aim/skills or .claude/skills override AIM's own of the same name.") }
                    ForEach(skills) { skill in skillRow(skill) }
                }
            }
            if !archived.isEmpty {
                SettingsGroup("Archived", description: "Learned skills unused for 60 days.") {
                    ForEach(archived, id: \.folder) { item in
                        SettingsRow(item.name) {
                            Button("Restore") {
                                do { try SkillUsage.restore(folder: item.folder); reload() } catch { message = error.localizedDescription }
                            }.buttonStyle(.settings)
                        }
                    }
                }
            }
            SettingsGroup("Import from Claude") {
                if importCandidates.isEmpty {
                    SettingsRow("~/.claude/skills", description: "Copy skills you already use with Claude into AIM.") {
                        Button("Preview…") { previewImport() }.buttonStyle(.settings)
                    }
                } else {
                    ForEach(importCandidates) { candidate in
                        let files = SkillCatalog.supportingFiles(candidate)
                        SettingsRow(candidate.name, description: candidate.description
                                    + (files.isEmpty ? "" : "\nIncludes \(files.count) file(s): \(files.prefix(4).joined(separator: ", "))")) {
                            SettingsSwitch(isOn: Binding(get: { importSelection.contains(candidate.name) },
                                                         set: { if $0 { importSelection.insert(candidate.name) } else { importSelection.remove(candidate.name) } }),
                                           label: "Import \(candidate.name)")
                        }
                    }
                    SettingsRow("\(importSelection.count) selected") {
                        Button("Cancel") { importCandidates = []; importSelection = [] }.buttonStyle(.settings)
                        Button("Import") { performImport() }.buttonStyle(.settingsPrimary).disabled(importSelection.isEmpty)
                    }
                }
            }
        }
        .onAppear { reload() }
    }

    private var levelSummary: String {
        switch level {
        case .off: "No review after tasks; the Agent cannot save skills."
        case .suggest: "Every new or improved skill waits for your acceptance."
        case .autonomous: "New skills and improvements to skills the Agent learned apply automatically. Changes to your own skills, and rewrites that would drop much of a skill, wait for your acceptance."
        case .unrestricted: "The Agent may create or rewrite any skill in AIM's folder automatically, including yours (previous versions are kept)."
        }
    }

    private func skillRow(_ skill: Skill) -> some View {
        let location = skill.source == .workspace ? "From the selected folder" :
            (skill.modelInvocable ? "AIM skills folder" : "AIM skills folder · not offered to the model")
        return SettingsRow(skill.name, description: "\(skill.description)\n\(location) · \(provenance(skill.origin)) · \(usageText(skill.name))") {
            Menu {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([skill.directory]) }
                if skill.source == .global, let version = SkillCatalog.versions(name: skill.name).first {
                    Button("Restore previous version") {
                        do { try SkillCatalog.rollback(name: skill.name); message = "Restored \(skill.name) from \(version)."; reload() }
                        catch { message = error.localizedDescription }
                    }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium))
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Actions for \(skill.name)")
            SettingsSwitch(isOn: Binding(get: { !disabled.contains(skill.name) }, set: { enabled in
                if enabled { disabled.remove(skill.name) } else { disabled.insert(skill.name) }
                SkillPreferences.disabled = disabled
            }), label: "Enabled")
        }
    }

    private func proposalRow(_ proposal: Skill) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(proposal.name, description: proposal.description) {
                Button(expanded.contains(proposal.name) ? "Hide" : "Review") {
                    if expanded.contains(proposal.name) { expanded.remove(proposal.name) } else { expanded.insert(proposal.name) }
                }.buttonStyle(.settings)
                Button("Decline") {
                    do { try SkillCatalog.reject(proposal: proposal); message = "\(proposal.name) moved to the Trash."; reload() }
                    catch { message = error.localizedDescription }
                }.buttonStyle(.settingsDestructive)
                Button("Accept") {
                    do { try SkillCatalog.accept(proposal: proposal); message = "\(proposal.name) is now installed."; reload() }
                    catch { message = error.localizedDescription }
                }.buttonStyle(.settingsPrimary)
            }
            VStack(alignment: .leading, spacing: 8) {
                if proposal.origin != nil {
                    SettingsNotice(provenance(proposal.origin), tone: proposal.origin?.hasPrefix("hub:") == true ? .warning : .info)
                }
                if skills.contains(where: { $0.name == proposal.name && $0.source == .global }) {
                    SettingsNotice("Replaces the installed skill of the same name; the current version stays restorable.", tone: .warning)
                }
                if expanded.contains(proposal.name) {
                    ScrollView {
                        Text((try? SkillCatalog.readFile(proposal, relativePath: "SKILL.md")) ?? "")
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                    .frame(maxHeight: 220)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.horizontal, SettingsMetrics.rowHorizontal)
            .padding(.bottom, proposal.origin != nil || expanded.contains(proposal.name) ? 14 : 0)
        }
    }

    private func provenance(_ origin: String?) -> String {
        guard let origin else { return "Written by you" }
        if origin == "learned" { return "Learned from a finished Agent task" }
        if origin.hasPrefix("hub:") { return "Third-party, from \(origin.dropFirst(4)) — review before accepting" }
        return "Origin: \(origin)"
    }

    private func usageText(_ name: String) -> String {
        guard let record = usage[name], record.uses > 0, let last = record.lastUsed else { return "not used yet" }
        return "used \(record.uses)× · last \(last.formatted(.relative(presentation: .named)))"
    }

    private func reload() {
        usage = SkillUsage.records()
        archived = SkillUsage.archived()
        skills = SkillCatalog.discover(workspace: model.workspacePath)
        proposals = SkillCatalog.proposals()
        disabled = SkillPreferences.disabled
    }

    private func openGlobalFolder() {
        guard let folder = SkillCatalog.globalDirectory else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    private func previewImport() {
        let installed = Set(SkillCatalog.discover(workspace: nil).map(\.name))
        importCandidates = SkillCatalog.scan(Self.claudeSkills, source: .global).filter { !installed.contains($0.name) }
        importSelection = []
        message = importCandidates.isEmpty ? "No new skill found in ~/.claude/skills." : nil
    }

    private func performImport() {
        do {
            let imported = try SkillCatalog.importSkills(from: Self.claudeSkills, names: importSelection)
            message = imported.isEmpty ? "Nothing imported." : "Imported \(imported.joined(separator: ", "))."
            importCandidates = []
            importSelection = []
            reload()
        } catch { message = error.localizedDescription }
    }
}
