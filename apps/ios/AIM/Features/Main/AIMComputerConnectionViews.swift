import AIMCore
@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// QR links contain a one-use pairing code, never a credential or a permission grant.
struct AIMPairingCode: Equatable, Sendable {
    let code: String
    let computerName: String?
    static let alphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    static func manual(_ text: String) -> Self? {
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 6, code.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return .init(code: code, computerName: nil)
    }

    static func qr(_ text: String) -> Self? {
        guard text.utf8.count <= 1024, let url = URLComponents(string: text),
              url.scheme == "aim", url.host == "remote", url.path == "/pair",
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let items = url.queryItems, Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ ["code", "name", "v"].contains($0.name) }),
              items.first(where: { $0.name == "v" })?.value == "1",
              let code = items.first(where: { $0.name == "code" })?.value,
              let parsed = manual(code), parsed.code == code else { return nil }
        let name = items.first(where: { $0.name == "name" })?.value
        guard name.map({ $0.count <= 60 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) ?? true else { return nil }
        return .init(code: parsed.code, computerName: name?.isEmpty == false ? name : nil)
    }
}

struct AIMConnectionSettingsView: View {
    let store: MainExperienceStore
    let onBack: () -> Void
    let addConnection: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: String(localized: "settings.connection"), back: onBack)
                .overlay(alignment: .trailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).aimGlassCircle() }
                        .buttonStyle(.plain).accessibilityLabel(Text("common.close")).accessibilityIdentifier("settings-close-button").padding(.trailing, 12)
                }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let success = store.pairingSuccessMessage {
                        Label(success, systemImage: "checkmark.circle.fill")
                            .font(.subheadline).foregroundStyle(.green).padding(.horizontal, 16)
                            .accessibilityIdentifier("pairing-success-message")
                    }
                    VStack(spacing: 0) {
                        ForEach(store.overview.machines) { machine in
                            computer(machine)
                            Divider().padding(.leading, 60)
                        }
                        Button(action: addConnection) {
                            Label("remote.connection.add", systemImage: "plus")
                                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).padding(.horizontal, 16)
                            .accessibilityIdentifier("add-computer-connection")
                    }
                    .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 22))
                    Text("remote.connection.suspension_help")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
                }.padding(16).padding(.bottom, 24)
            }.scrollIndicators(.hidden)
        }
        .font(.system(.body)).tint(.primary)
        .accessibilityElement(children: .contain).accessibilityIdentifier("settings-computer-connections")
    }

    private func computer(_ machine: RemoteMachine) -> some View {
        let suspended = store.isRemoteSuspended(machineID: machine.id)
        return HStack(spacing: 12) {
            Image(systemName: "desktopcomputer").font(.title3).foregroundStyle(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(machine.name).foregroundStyle(.primary)
                HStack(spacing: 5) {
                    Circle().fill(suspended ? Color.secondary : machine.isOnline() ? .green : .secondary).frame(width: 7, height: 7)
                    Text(LocalizedStringKey(suspended ? "remote.connection.suspended" : machine.isOnline() ? "settings.connection.online" : "main.offline"))
                }.font(.subheadline).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Toggle(machine.name, isOn: Binding(get: { !store.isRemoteSuspended(machineID: machine.id) }, set: { store.setRemoteEnabled($0, machineID: machine.id) }))
                .labelsHidden().tint(.green).accessibilityLabel(Text(machine.name))
                .accessibilityHint(Text("remote.connection.suspension_help"))
                .accessibilityIdentifier("computer-enabled-\(machine.id)")
        }.padding(16)
    }
}

struct AIMPairComputerView: View {
    let store: MainExperienceStore
    let back: () -> Void
    let paired: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var camera = AIMPairingCameraState()
    @State private var pending: AIMPairingCode?
    @State private var lastScannedValue: String?
    @State private var pageActive = true
    @State private var manual = false
    @State private var showingAlert = false
    @State private var manualCode = ""
    @State private var validationError: String?

    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: String(localized: "remote.pair.title"), back: back)
            ScrollView {
                VStack(spacing: 24) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 30).fill(Color.primary.opacity(0.05))
                        if camera.permission == .authorized {
                            AIMPairingCameraPreview(active: scenePhase == .active && !showingAlert && !store.isPairing) { value in
                                guard let value else { lastScannedValue = nil; return }
                                guard pending == nil, !showingAlert, !store.isPairing, value != lastScannedValue else { return }
                                lastScannedValue = value
                                guard let scanned = AIMPairingCode.qr(value) else {
                                    validationError = String(localized: "remote.pair.invalid_qr")
                                    return
                                }
                                pending = scanned; manual = false; showingAlert = true
                            } failure: { validationError = $0 }
                        } else if camera.permission == .checking { ProgressView() }
                        else {
                            VStack(spacing: 14) {
                                Image(systemName: "camera.fill").font(.largeTitle)
                                Text("remote.pair.camera_unavailable").multilineTextAlignment(.center)
                                if camera.permission == .denied {
                                    Button("remote.pair.open_settings") {
                                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                                    }.buttonStyle(.plain).fontWeight(.semibold)
                                }
                            }.padding(24)
                        }
                        RoundedRectangle(cornerRadius: 30).stroke(Color.primary.opacity(0.14), lineWidth: 1).allowsHitTesting(false)
                    }.aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 30))
                        .padding(.horizontal, 24).accessibilityLabel(Text("remote.pair.scan"))
                    Text("remote.pair.scan").font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                    Text("settings.connection.instructions").accessibilityIdentifier("pairing-instructions").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if store.isPairing { ProgressView("settings.connection.pairing") }
                    if let error = validationError ?? store.errorMessage {
                        Text(error).font(.subheadline).foregroundStyle(.red).accessibilityIdentifier("pairing-error")
                    }
                    Button {
                        pending = nil; manual = true; manualCode = ""; validationError = nil; store.clearError(); showingAlert = true
                    } label: {
                        Text("remote.pair.manual").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 52)
                    }.buttonStyle(.plain)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
                        .disabled(store.isPairing).accessibilityIdentifier("pair-computer-manually")
                }.padding(24).padding(.top, 16).padding(.bottom, 28)
            }.scrollIndicators(.hidden)
        }.font(.system(.body)).tint(.primary)
            .accessibilityElement(children: .contain).accessibilityIdentifier("pair-computer-screen")
            .onAppear { pageActive = true }
            .onDisappear { pageActive = false }
            .task { await camera.request() }
            .onChange(of: scenePhase) { _, value in if value == .active { Task { await camera.request() } } }
            .alert(manual ? String(localized: "remote.pair.manual") : String(localized: "remote.pair.confirm"), isPresented: $showingAlert) {
                if manual {
                    TextField("main.pair.code", text: $manualCode)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled().keyboardType(.asciiCapable)
                        .textContentType(.oneTimeCode).accessibilityIdentifier("pairing-code-field")
                }
                Button("common.cancel", role: .cancel) { pending = nil }
                Button("remote.pair.action") {
                    let value = manual ? AIMPairingCode.manual(manualCode) : pending
                    pending = nil
                    guard let value else { validationError = String(localized: "main.pair.invalid"); return }
                    Task {
                        validationError = nil
                        let succeeded = await store.pair(code: value.code, name: UIDevice.current.name)
                        if succeeded, pageActive { paired() }
                    }
                }
            } message: {
                Text(manual ? String(localized: "remote.pair.manual_help") : pending?.computerName.map { String(localized: "remote.pair.confirm_help") + "\n" + $0 } ?? String(localized: "remote.pair.confirm_help"))
            }
    }
}

@MainActor @Observable final class AIMPairingCameraState {
    enum Permission { case checking, authorized, denied, unavailable }
    var permission = Permission.checking
    func request() async {
        let available = await Task.detached(priority: .userInitiated) { AVCaptureDevice.default(for: .video) != nil }.value
        guard available else { permission = .unavailable; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: permission = .authorized
        case .notDetermined: permission = await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
        default: permission = .denied
        }
    }
}

struct AIMPairingCameraPreview: UIViewRepresentable {
    let active: Bool
    let detected: (String?) -> Void
    let failure: (String) -> Void
    func makeCoordinator() -> AIMPairingCapture { .init(detected: detected, failure: failure) }
    func makeUIView(context: Context) -> AIMPairingPreviewView {
        let view = AIMPairingPreviewView()
        view.preview.session = context.coordinator.session
        view.preview.videoGravity = .resizeAspectFill
        context.coordinator.setActive(active)
        return view
    }
    func updateUIView(_ view: AIMPairingPreviewView, context: Context) { context.coordinator.setActive(active) }
    static func dismantleUIView(_ view: AIMPairingPreviewView, coordinator: AIMPairingCapture) {
        coordinator.close { view.preview.session = nil }
    }
}

final class AIMPairingPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

/// Capture and decoding only: no photo/movie outputs or stored frames.
final class AIMPairingCapture: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private static let captureQueue = DispatchQueue(label: "aim.pairing.capture")
    private let queue = AIMPairingCapture.captureQueue
    private var configured = false
    private let intent = AIMPairingCaptureIntent()
    private let detected: (String?) -> Void
    private let failure: (String) -> Void
    init(detected: @escaping (String?) -> Void, failure: @escaping (String) -> Void) {
        self.detected = detected; self.failure = failure
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(stopForPrivacy), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(stopForPrivacy), name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func stopForPrivacy() { setActive(false) }
    func setActive(_ active: Bool) {
        guard intent.request(active) else { return }
        queue.async { [self] in
            if intent.isActive {
                if !configured {
                    do {
                        session.beginConfiguration(); defer { session.commitConfiguration() }
                        guard let camera = AVCaptureDevice.default(for: .video) else { throw CaptureFailure.unavailable }
                        let input = try AVCaptureDeviceInput(device: camera)
                        guard session.canAddInput(input) else { throw CaptureFailure.unavailable }
                        session.addInput(input)
                        let output = AVCaptureMetadataOutput()
                        guard session.canAddOutput(output) else { session.removeInput(input); throw CaptureFailure.unavailable }
                        session.addOutput(output)
                        output.setMetadataObjectsDelegate(self, queue: .main)
                        guard output.availableMetadataObjectTypes.contains(.qr) else { session.removeInput(input); session.removeOutput(output); throw CaptureFailure.unavailable }
                        output.metadataObjectTypes = [.qr]
                        configured = true
                    } catch {
                        DispatchQueue.main.async { if self.intent.isActive { self.failure(String(localized: "remote.pair.camera_unavailable")) } }
                        return
                    }
                }
                guard intent.isActive else { return }
                if !session.isRunning { session.startRunning() }
                if !intent.isActive, session.isRunning { session.stopRunning() }
            } else if session.isRunning { session.stopRunning() }
        }
    }
    /// Never make SwiftUI's main-thread teardown wait for capture locks. Keep the
    /// preview alive until serialized stop completes, then detach it on main.
    func close(detach: @escaping @MainActor @Sendable () -> Void) {
        intent.close()
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            for output in session.outputs {
                (output as? AVCaptureMetadataOutput)?.setMetadataObjectsDelegate(nil, queue: nil)
            }
            DispatchQueue.main.async { detach() }
        }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard intent.isActive else { return }
        detected(metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first)
    }
    private enum CaptureFailure: Error { case unavailable }
}

/// Serial capture work observes the latest intent rather than queued stale starts.
final class AIMPairingCaptureIntent: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var closed = false
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active && !closed }
    func request(_ value: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, active != value else { return false }
        active = value
        return true
    }
    func close() { lock.lock(); closed = true; active = false; lock.unlock() }
}
