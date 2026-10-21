import AIMCore
import Foundation
import Observation

@MainActor @Observable
final class AIMSkillsStore {
    static let shared = AIMSkillsStore()
    var attachedInstructions: String?
    var installed: [NativeSkill] = []
    var catalog: [NativeStoreSkill] = []
    var preview: NativeSkill?
    var versions: [NativeSkill] = []
    var macSkills: [NativeSkillManifest] = []
    var selectedMacSkills = Set<String>()
    var isLoading = false
    var error: String?
    var accountID: UUID?
    private var macID: String?
    var importWrite: ((NativeSkill) async throws -> Void)?
    var importRead: ((String?) async throws -> RemoteJSONValue)?
    private let repository: NativeSkillsRepository
    private let service: NativeSkillCatalogService
    private var page = 0
    private var accountGeneration = UUID()
    private var catalogGeneration = UUID()
    init(repository: NativeSkillsRepository = .init(), service: NativeSkillCatalogService = .init()) { self.repository = repository; self.service = service }
    func configure(account: UUID?) async {
        guard accountID != account else { return }
        accountGeneration = UUID()
        accountID = account; macID = nil; attachedInstructions = nil; installed = []; preview = nil; versions = []; macSkills = []; selectedMacSkills = []; error = nil
        await reload()
    }
    func selectMac(_ id: String?) {
        guard macID != id else { return }
        macID = id; accountGeneration = UUID(); macSkills = []; selectedMacSkills = []
    }
    func attachInstructions(_ skill: NativeSkill) {
        guard accountID != nil else { error = "Sign in to attach instructions."; return }
        attachedInstructions = "User explicitly attached skill \(skill.name) (\(skill.origin), version \(skill.version)). These are guidance only and grant no tool or script permissions.\n\n" + skill.instructions
        error = "Instructions attached to the next Chat message. Return to your conversation to send it."
    }
    func reload() async {
        guard let accountID else { installed = []; return }
        do { let rows = try await repository.all(account: accountID); if self.accountID == accountID { installed = rows } } catch { self.error = error.localizedDescription }
    }
    func loadCatalog(query: String = "", more: Bool = false) async {
        isLoading = true; error = nil; defer { isLoading = false }
        let generation = UUID(); catalogGeneration = generation
        if !more { page = 0; if query.isEmpty { catalog = await service.cached() } }
        else { page += 1 }
        do {
            let rows = try await service.catalog(page: page, query: query)
            guard catalogGeneration == generation else { return }
            if more { let ids = Set(catalog.map(\.id)); catalog += rows.filter { !ids.contains($0.id) } }
            else { catalog = rows }
        } catch { self.error = error.localizedDescription }
    }
    func show(_ item: NativeStoreSkill) async {
        isLoading = true; error = nil; defer { isLoading = false }
        let generation = accountGeneration
        do { let skill = try await service.preview(item); guard generation == accountGeneration else { return }; preview = skill }
        catch { if generation == accountGeneration { self.error = error.localizedDescription } }
    }
    func acceptPreview(replace: Bool) async {
        guard let accountID, var preview else { error = "Sign in to install skills for this account."; return }
        preview.enabled = false
        do { try await repository.install(preview, account: accountID, replace: replace); self.preview = nil; await reload() }
        catch { self.error = error.localizedDescription }
    }
    func toggle(_ skill: NativeSkill, enabled: Bool) async {
        guard let accountID else { return }
        do { try await repository.setEnabled(skill.name, enabled: enabled, account: accountID); await reload() }
        catch { self.error = error.localizedDescription }
    }
    func remove(_ skill: NativeSkill) async {
        guard let accountID else { return }
        do { try await repository.remove(skill.name, account: accountID); preview = nil; await reload() }
        catch { self.error = error.localizedDescription }
    }
    func loadVersions(_ skill: NativeSkill) async {
        guard let accountID else { return }
        let generation = accountGeneration
        let rows = (try? await repository.versions(skill.name, account: accountID)) ?? []
        guard generation == accountGeneration else { return }; versions = rows
    }
    /// Reconnection refresh updates the index only. Activation and replacement
    /// still require review; this never downloads files or runs a model.
    func refreshMac() async {
        guard let importRead else { return }
        let generation = accountGeneration
        do {
            let rows = try NativeSkillImportContract.manifests(await importRead(nil))
            guard generation == accountGeneration else { return }
            macSkills = rows
        } catch { /* Keep the last index while the selected Mac is offline. */ }
    }
    func loadMac() async {
        guard let importRead else { error = "Select an authorized, connected Mac to preview its installed global skills."; return }
        isLoading = true; error = nil; defer { isLoading = false }
        let generation = accountGeneration
        do { let rows = try NativeSkillImportContract.manifests(await importRead(nil)); guard generation == accountGeneration else { return }; macSkills = rows; selectedMacSkills = [] }
        catch { if generation == accountGeneration { self.error = "The Mac could not provide skills. Check its connection, authorization and version. " + error.localizedDescription } }
    }
    func previewMac(_ name: String) async {
        guard let importRead else { return }
        isLoading = true; defer { isLoading = false }
        let generation = accountGeneration
        do { let skill = try NativeSkillImportContract.skill(await importRead(name)); guard generation == accountGeneration else { return }; preview = skill }
        catch { if generation == accountGeneration { self.error = error.localizedDescription } }
    }
    func installOnMac(_ skill: NativeSkill) async {
        guard let importWrite else { error = "Select an authorized, connected Mac to install this skill."; return }
        isLoading = true; error = nil; defer { isLoading = false }
        do { try await importWrite(skill); error = "Installed on the Mac, disabled. Enable it there after reviewing dependencies." }
        catch { self.error = error.localizedDescription }
    }
    /// Batch copies do not overwrite conflicts. They remain explicit previews.
    func importSelected() async {
        guard let accountID, let importRead else { return }
        isLoading = true; error = nil; defer { isLoading = false }
        let generation = accountGeneration
        do {
            for name in selectedMacSkills.sorted() {
                let skill = try NativeSkillImportContract.skill(await importRead(name))
                guard generation == accountGeneration else { return }
                do { try await repository.install(skill, account: accountID) }
                catch NativeSkillError.conflict { preview = skill; error = "A different version of \(name) is installed. Review Replace or keep the existing version."; break }
            }
            await reload()
        } catch { self.error = error.localizedDescription }
    }
}
