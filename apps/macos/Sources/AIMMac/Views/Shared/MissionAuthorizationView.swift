import AIMApplication
import AppKit
import SwiftUI

private struct MissionAppChoice: Identifiable {
    let id: String
    let name: String
}

struct MissionAuthorizationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var bundleID = ""
    @State private var webOrigin = ""
    @State private var allowObservation = true
    @State private var allowTyping = false
    @State private var allowNavigation = false

    private var applications: [MissionAppChoice] {
        var seen: Set<String> = []
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, let id = app.bundleIdentifier, id != "com.aimai.macos",
                  seen.insert(id).inserted else { return nil }
            return MissionAppChoice(id: id, name: app.localizedName ?? id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var selectedOperations: Set<MissionOperation> {
        var values: Set<MissionOperation> = []
        if allowObservation { values.insert(.observe) }
        if allowTyping { values.insert(.input) }
        if allowNavigation { values.insert(.navigate) }
        return values
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Mission permissions").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
            }
            Text("Choose what AIM may do in an application during this mission. A scope takes effect only in Auto mode and can be revoked while AIM works.")
                .font(.subheadline).foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

            if let authorization = model.missionAuthorization {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(authorization.revokedAt == nil ? "Active scope" : "Scope revoked")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if authorization.revokedAt == nil {
                            Button("Revoke all") { Task { _ = await model.revokeMissionAuthorization() } }
                                .disabled(model.isSavingMissionAuthorization)
                        }
                    }
                    ForEach(authorization.rules, id: \.resource) { rule in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(rule.resource.identifier).font(.system(.body, design: .monospaced))
                                Text(rule.operations.map(\.rawValue).sorted().joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if authorization.revokedAt == nil {
                                Button("Remove") {
                                    Task { _ = await model.removeMissionAuthorizationRule(rule.resource) }
                                }.disabled(model.isSavingMissionAuthorization)
                            }
                        }
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Authorize an application").font(.subheadline.weight(.semibold))
                Picker("Application", selection: $bundleID) {
                    Text("Choose an open application").tag("")
                    ForEach(applications) { app in Text("\(app.name) · \(app.id)").tag(app.id) }
                }
                Toggle("Observe its windows", isOn: $allowObservation)
                Toggle("Enter text in a verified, non-secure field", isOn: $allowTyping)
                Toggle("Move or scroll in its focused window", isOn: $allowNavigation)
                Button("Save app scope") {
                    Task {
                        _ = await model.addMissionAuthorizationRule(kind: .application,
                            identifier: bundleID, operations: selectedOperations)
                    }
                }
                .disabled(bundleID.isEmpty || selectedOperations.isEmpty || model.isSavingMissionAuthorization)
            }

            if let workspace = model.workspacePath {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Current workspace").font(.subheadline.weight(.semibold))
                    Text(workspace).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Allow ordinary file work in this folder") {
                        Task {
                            _ = await model.addMissionAuthorizationRule(kind: .directory,
                                identifier: workspace, operations: [.observe, .edit])
                        }
                    }.disabled(model.isSavingMissionAuthorization)
                    Text("Covers reviewed edits, new folders, and copies or moves when both paths are covered. New files and sensitive paths still require their separate preview approval.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Authorize a website").font(.subheadline.weight(.semibold))
                TextField("https://example.com", text: $webOrigin)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Button("Allow navigation to this origin") {
                    Task {
                        _ = await model.addMissionAuthorizationRule(kind: .webOrigin,
                            identifier: webOrigin, operations: [.navigate])
                    }
                }
                .disabled(webOrigin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSavingMissionAuthorization)
                Text("Covers an explicit URL on this site. Browser clicks, form entries and submissions still ask for approval until AIM can verify the selected tab and its current URL.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Text("Generic clicks, key presses, drags and focus changes still ask because they can submit, purchase or interrupt your work. Payment, commitments, administrator rights and permanent deletion are never covered by a mission scope.")
                .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(22)
        .frame(width: 560, height: 520)
        .accessibilityIdentifier("mission-authorization-sheet")
    }
}
