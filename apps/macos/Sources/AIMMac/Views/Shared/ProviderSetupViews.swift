import AIMCore
import AIMApplication
import SwiftUI

struct ProviderDiagnosticsView: View {
    var initialProvider: ChatProvider?
    var embedded = false
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var error: String?
    @State private var provider: ChatProvider = .openRouter
    @State private var saved = false
    @State private var checking = false
    @State private var checkMessage: String?
    @State private var checkTask: Task<Void, Never>?
    @State private var testModelID = ""
    @State private var testing = false
    @State private var testMessage: String?
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                if !embedded { Text("AI providers").font(.title2.weight(.medium)) }
                Spacer()
                if !embedded { Button("Done") { dismiss() } }
            }
            Text("Connect your models").font(.system(size: 22, weight: .semibold))
            Text("Choose a provider and add your API key. You control which models you use.")
                .font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(ChatProvider.allCases.filter { $0 != .local }) { item in
                    Button { provider = item } label: {
                        HStack(spacing: 10) {
                            Text(String(item.name.prefix(1))).font(.system(size: 14, weight: .semibold))
                                .frame(width: 30, height: 30).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                            Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 0)
                            if model.connectedProviders.contains(item) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(provider == item ? 0.075 : 0.025), in: RoundedRectangle(cornerRadius: 13))
                            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(provider == item ? 0.18 : 0), lineWidth: 1))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            Text(provider.name).font(.system(size: 17, weight: .semibold)).padding(.top, 12)
            Text("Messages go directly to \(provider.host) and are billed to your \(provider.name) API account. A consumer chat subscription does not supply an API key.")
                .foregroundStyle(.secondary)
            if provider == .perplexity {
                Text("Agent API research uses your Perplexity key and may run hosted web searches. Legacy Sonar is not silently substituted. This provider cannot run local Mac tools yet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Label(model.connectedProviders.contains(provider) ? "Key stored on this Mac · access not yet checked" : "No key stored", systemImage: model.connectedProviders.contains(provider) ? "checkmark.circle" : "key")
            SecureField(model.connectedProviders.contains(provider) ? "Replace API key" : "API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            if let checkMessage { Text(checkMessage).foregroundStyle(.secondary).font(.callout) }
            if saved { Text("Key saved. Choose a model before sending your first message.").font(.callout).foregroundStyle(.secondary) }
            Text("Your key stays in this Mac’s Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Link("Get an API key", destination: provider.keyURL)
                Spacer()
                if model.connectedProviders.contains(provider), model.selectedProvider != provider {
                    Button("Use \(provider.name)") {
                        useProvider(provider)
                    }
                }
                if model.connectedProviders.contains(provider) {
                    Button("Disconnect") {
                        checkTask?.cancel(); checking = false; checkMessage = nil
                        testTask?.cancel(); testing = false; testMessage = nil
                        model.removeProviderKey(provider); saved = false
                    }
                }
            }
            HStack {
                if checking { ProgressView().controlSize(.small) }
                Button(apiKey.isEmpty ? "Check saved key" : "Check entered key", action: check)
                    .disabled(checking || (apiKey.isEmpty && !model.connectedProviders.contains(provider)))
                Spacer()
                Button("Save key", action: save)
                    .buttonStyle(.settingsPrimary)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            DisclosureGroup("Advanced connection diagnostics") {
            Text("This sends only a short test prompt to \(provider.name) and may use billable API tokens. No conversation or project file is sent or saved; Perplexity web search is off for this test.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Model ID", text: $testModelID)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("provider-test-model")
                if testing { ProgressView().controlSize(.small) }
                Button("Test answer", action: testInference)
                    .disabled(testing || testModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (apiKey.isEmpty && !model.connectedProviders.contains(provider)))
            }
            if let testMessage { Text(testMessage).font(.callout).textSelection(.enabled) }
            }
        }
        .padding(28).frame(maxWidth: embedded ? 700 : 490)
        .onAppear {
            provider = initialProvider ?? model.selectedProvider
            testModelID = provider == model.selectedProvider ? model.selectedModelID : ""
        }
        .onChange(of: provider) { _, _ in
            checkTask?.cancel(); checking = false; checkMessage = nil
            testTask?.cancel(); testing = false; testMessage = nil
            testModelID = provider == model.selectedProvider ? model.selectedModelID : ""
            apiKey = ""; error = nil; saved = false
        }
        .onChange(of: apiKey) { _, _ in checkMessage = nil }
        .onChange(of: testModelID) { _, _ in testMessage = nil }
        .onDisappear { checkTask?.cancel(); checking = false; testTask?.cancel(); testing = false }

    }

    private func useProvider(_ candidate: ChatProvider) {
        model.selectProvider(candidate)
        testModelID = ""
        testMessage = nil
    }

    private func save() {
        do { try model.saveProviderKey(apiKey, provider: provider); apiKey = ""; saved = true; error = nil; checkMessage = nil }
        catch { self.error = "The key could not be saved. Check the value and allow Keychain access if requested." }
    }

    private func check() {
        let checkedProvider = provider
        let enteredKey = apiKey
        checking = true; error = nil; checkMessage = nil
        checkTask = Task {
            do {
                let result = try await model.checkProviderKey(enteredKey, provider: checkedProvider)
                guard !Task.isCancelled, provider == checkedProvider else { return }
                let detail = result == .keyAccepted
                    ? "OpenRouter accepted this key. Model access and billing were not tested."
                    : checkedProvider == .perplexity
                        ? "Perplexity’s Router catalog accepted this key. Agent API inference was not tested."
                        : "The provider’s model catalog accepted this key. Inference was not tested."
                checkMessage = enteredKey.isEmpty ? detail : detail + " Save the entered key to use it."
            } catch {
                guard !Task.isCancelled, provider == checkedProvider else { return }
                self.error = (error as? ChatServiceError)?.localizedDescription
                    ?? "Could not check access. Verify the network connection and try again."
            }
            if provider == checkedProvider { checking = false }
        }
    }

    private func testInference() {
        let checkedProvider = provider
        let checkedModel = testModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let enteredKey = apiKey
        testMessage = nil; error = nil; testing = true
        testTask = Task {
            do {
                let answer = try await model.testProviderInference(enteredKey, provider: checkedProvider, modelID: checkedModel)
                guard !Task.isCancelled, provider == checkedProvider else { return }
                testMessage = "Real answer received from \(checkedProvider.name) · \(checkedModel): \(answer)"
            } catch {
                guard !Task.isCancelled, provider == checkedProvider else { return }
                self.error = (error as? ChatServiceError)?.localizedDescription
                    ?? "The test request failed. Check this model’s availability and your provider account."
            }
            if provider == checkedProvider { testing = false }
        }
    }
}

struct ProviderSetupView: View {
    var initialProvider: ChatProvider?
    var embedded = false
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var connection = OpenRouterConnection()
    @State private var diagnostics: ChatProvider?
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            if !embedded { HStack { Text("Providers").font(.title2); Spacer(); Button("Done") { dismiss() } } }
            Text("Connect your models").font(.system(size: 24, weight: .semibold))
            Text("Your keys stay in this Mac’s Keychain. Usage is billed by your providers.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ProviderLogo(provider: .openRouter)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("OpenRouter").font(.headline)
                        Text(model.connectedProviders.contains(.openRouter) ? "Connected" : "Sign in in your browser, without copying a key.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if connection.connecting {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { connection.cancel() }
                    } else if model.connectedProviders.contains(.openRouter) {
                        Button("Disconnect") { model.removeProviderKey(.openRouter) }
                    } else {
                        Button("Connect") { let scope = model.captureCredentialScope(); connection.start { try model.saveProviderKey($0, provider: .openRouter, expectedScope: scope) } }
                            .buttonStyle(.settingsPrimary)
                    }
                }
                if let status = connection.status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }.padding(20).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 18))
            Text("Your API keys").font(.headline)
            VStack(spacing: 0) {
                ForEach(ChatProvider.allCases.filter { $0 != .local }) { provider in
                    ProviderKeyRow(provider: provider) { diagnostics = provider }
                    if provider != .perplexity { Divider().padding(.leading, 54) }
                }
            }.background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 18))
        }.padding(24).frame(maxWidth: 820, alignment: .leading)
            .onDisappear { connection.cancel() }
            .sheet(item: $diagnostics) { provider in ProviderDiagnosticsView(initialProvider: provider) }
    }
}

private struct ProviderKeyRow: View {
    let provider: ChatProvider
    let diagnostics: () -> Void
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ProviderLogo(provider: provider, size: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.name).font(.system(size: 14, weight: .medium))
                    if model.connectedProviders.contains(provider) {
                        Text("Key saved").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(width: 100, alignment: .leading)
                SecureField(model.connectedProviders.contains(provider) ? "Replace key" : "API key", text: $key)
                    .textFieldStyle(.plain).padding(10)
                    .background(.background, in: RoundedRectangle(cornerRadius: 10))
                    .onSubmit(save)
                Button("Save", action: save).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.connectedProviders.contains(provider) {
                    Button { model.removeProviderKey(provider) } label: { Image(systemName: "trash") }.help("Remove this key from this Mac")
                }
                Menu {
                    Link("Get an API key", destination: provider.keyURL)
                    Button("Connection diagnostics…", action: diagnostics)
                } label: { Image(systemName: "info.circle") }.menuStyle(.borderlessButton).fixedSize()
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(16)
    }
    private func save() {
        do { try model.saveProviderKey(key, provider: provider); key = ""; error = nil }
        catch { self.error = "Could not save the key. Check the value and Keychain access." }
    }
}
