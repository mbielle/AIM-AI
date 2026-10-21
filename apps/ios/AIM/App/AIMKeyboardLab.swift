#if DEBUG
import SwiftUI
import UIKit

/// Development-only experiment. It deliberately does not share the production
/// presenter: failures here must not change the shipping chat's behavior.
struct AIMKeyboardLab: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        let lab = AIMKeyboardLabController()
        let navigation = UINavigationController(rootViewController: lab)
        let nativeGesture = ProcessInfo.processInfo.environment["AIM_KEYBOARD_NATIVE_GESTURE"] == "1"
        if nativeGesture {
            let previous = UIViewController()
            previous.view.backgroundColor = .secondarySystemBackground
            previous.title = "Previous screen"
            lab.title = "Native gesture probe"
            navigation.setViewControllers([previous, lab], animated: false)
        }
        navigation.setNavigationBarHidden(!nativeGesture, animated: false)
        return navigation
    }
    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

final class AIMKeyboardLabController: UIViewController, UIViewControllerTransitioningDelegate, UITextViewDelegate, UIPopoverPresentationControllerDelegate, UIContextMenuInteractionDelegate {
    let editor = AIMKeyboardLabEditor()
    private let status = UILabel()
    private let strategy = UISegmentedControl(items: ["UIKit", "Snapshot", "Retain", "Input", "Window", "Nav", "Popover", "Custom", "NonKey", "Acc"])
    private let accessory = AIMKeyboardLabAccessory(frame: CGRect(x: 0, y: 0, width: 390, height: 1))
    private let accessoryController = UIInputViewController()
    private var accessoryOverlay: AIMKeyboardLabOverlay?
    private var journal: [String] = []

    private func record(_ event: String) {
        let owner = editor.window
        let line = "\(ProcessInfo.processInfo.systemUptime) \(event) editor=\(ObjectIdentifier(editor)) first=\(editor.isFirstResponder) key=\(owner?.isKeyWindow ?? false) window=\(owner.map { String(describing: ObjectIdentifier($0)) } ?? "nil")"
        journal.append(line)
        status.accessibilityValue = journal.suffix(100).joined(separator: "\n")
    }

    @objc private func keyboardEvent(_ note: Notification) {
        record("\(note.name.rawValue) frame=\(String(describing: note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]))")
    }
    private var screenSnapshot: UIView?
    private var savedSelection = NSRange(location: 0, length: 0)
    private var wasEditing = false
    private var interaction: UIPercentDrivenInteractiveTransition?
    private var media = false
    private var captured = 0
    private var editingEnds = 0
    private var experimentWindow: UIWindow?
    private weak var sourceWindow: UIWindow?
    private var sourceWindowFrame: CGRect?
    private var sourceWindowTransform: CGAffineTransform?

    override var disablesAutomaticKeyboardDismissal: Bool { strategy.selectedSegmentIndex >= 2 }

    func textViewDidEndEditing(_ textView: UITextView) { editingEnds += 1; record("didEndEditing") }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        record("willDisappear interactive=\(transitionCoordinator?.isInteractive ?? false)")
        transitionCoordinator?.notifyWhenInteractionChanges { [weak self] context in
            self?.record("interaction cancelled=\(context.isCancelled)")
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        record("didAppear")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardDidShowNotification,
                     UIResponder.keyboardWillHideNotification, UIResponder.keyboardDidHideNotification,
                     UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification,
                     UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardEvent(_:)), name: name, object: nil)
        }
        view.backgroundColor = .systemBackground
        strategy.selectedSegmentIndex = 0
        if ProcessInfo.processInfo.environment["AIM_KEYBOARD_NATIVE_RETAIN"] == "1" {
            strategy.selectedSegmentIndex = 2
            editor.retainResponder = true
        }
        if ProcessInfo.processInfo.environment["AIM_KEYBOARD_ACCESSORY_PROBE"] == "1" {
            strategy.selectedSegmentIndex = 9
            accessoryController.view = accessory
            editor.labAccessoryController = accessoryController
        }
        strategy.accessibilityIdentifier = "lab-strategy"
        let mediaButton = button("Media", id: "lab-media") { [weak self] in self?.show(media: true) }
        if ProcessInfo.processInfo.environment["AIM_KEYBOARD_CONTEXT_PROBE"] == "1" {
            mediaButton.addInteraction(UIContextMenuInteraction(delegate: self))
        }
        let controls = UIStackView(arrangedSubviews: [
            strategy,
            button("Keyboard", id: "lab-focus") { [weak self] in self?.editor.becomeFirstResponder() },
            button("Sidebar", id: "lab-sidebar") { [weak self] in self?.show(media: false) },
            mediaButton
        ])
        controls.axis = .vertical
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        status.text = "Public API keyboard laboratory"
        status.numberOfLines = 0
        status.accessibilityIdentifier = "lab-status"
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)
        editor.font = .preferredFont(forTextStyle: .body)
        editor.delegate = self
        editor.backgroundColor = .secondarySystemBackground
        editor.layer.cornerRadius = 16
        editor.text = "Keep this draft"
        editor.accessibilityIdentifier = "lab-editor"
        editor.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(editor)
        view.keyboardLayoutGuide.keyboardDismissPadding = 76
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            status.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12),
            status.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            editor.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            editor.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            editor.heightAnchor.constraint(equalToConstant: 72),
            editor.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -4)
        ])
        let pan = UIPanGestureRecognizer(target: self, action: #selector(reveal(_:)))
        if ProcessInfo.processInfo.environment["AIM_KEYBOARD_NATIVE_GESTURE"] != "1" {
            view.addGestureRecognizer(pan)
        }
    }

    @objc private func reveal(_ pan: UIPanGestureRecognizer) {
        // Window handoff is a button-only probe; it has no transition context
        // for UIPercentDrivenInteractiveTransition to drive or cancel.
        guard strategy.selectedSegmentIndex < 4 else { return }
        let delta = pan.translation(in: view)
        switch pan.state {
        case .began:
            guard abs(pan.velocity(in: view).x) > abs(pan.velocity(in: view).y),
                  pan.velocity(in: view).x > 0 else { return }
            interaction = UIPercentDrivenInteractiveTransition()
            show(media: false)
        case .changed:
            interaction?.update(min(1, max(0, delta.x / (view.bounds.width * 0.77))))
        case .ended, .cancelled:
            guard let interaction else { return }
            if pan.state == .ended && delta.x > view.bounds.width * 0.3 {
                interaction.finish()
            } else {
                interaction.cancel()
            }
            self.interaction = nil
        default: break
        }
    }

    private func show(media: Bool) {
        guard presentedViewController == nil, experimentWindow == nil, accessoryOverlay == nil, let window = view.window else { return }
        sourceWindow = window
        self.media = media
        wasEditing = editor.isFirstResponder
        savedSelection = editor.selectedRange
        if ProcessInfo.processInfo.environment["AIM_KEYBOARD_MODE_HINT"] == "1" {
            editor.rememberedInputMode = editor.textInputMode
        }
        record("begin presentation")
        // Read-only public scene inventory. No class-name lookup, hierarchy
        // traversal or mutation of system-owned windows.
        if let scene = window.windowScene {
            record("scene window levels=" + scene.windows.map {
                "level=\($0.windowLevel.rawValue),key=\($0.isKeyWindow),hidden=\($0.isHidden)"
            }.joined(separator: ";"))
        }
        editor.retainResponder = strategy.selectedSegmentIndex >= 2 && strategy.selectedSegmentIndex != 8
        if [1, 3, 4, 8].contains(strategy.selectedSegmentIndex) {
            // Public render-server snapshot, never converted to a file. Whether
            // it actually includes the remote keyboard is an acceptance test.
            let snapshot = window.screen.snapshotView(afterScreenUpdates: false)
            let screenOrigin = view.convert(CGPoint.zero, to: window.screen.coordinateSpace)
            snapshot.frame = CGRect(origin: CGPoint(x: -screenOrigin.x, y: -screenOrigin.y), size: window.screen.bounds.size)
            snapshot.isUserInteractionEnabled = false
            snapshot.accessibilityElementsHidden = true
            view.addSubview(snapshot)
            screenSnapshot = snapshot
            if strategy.selectedSegmentIndex == 3 {
                // Replace input without resigning. Preservation of the system
                // keyplane on restoration is deliberately not assumed.
                editor.inputView = UIInputView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 1), inputViewStyle: .default)
                editor.reloadInputViews()
            } else if strategy.selectedSegmentIndex == 1 {
                editor.resignFirstResponder()
            }
        }
        let overlay = AIMKeyboardLabOverlay(media: media)
        overlay.retainKeyboard = strategy.selectedSegmentIndex >= 2
        overlay.close = { [weak self] in self?.close() }
        overlay.capture = { [weak self] in
            guard let self else { return }
            self.captured += 1
            self.close()
        }
        if strategy.selectedSegmentIndex == 9,
           ProcessInfo.processInfo.environment["AIM_KEYBOARD_ACCESSORY_MODAL"] == "1" {
            // Present from OUR accessory controller, instead of inserting a
            // child view below its keyboard sibling or presenting from chat.
            overlay.modalPresentationStyle = .overFullScreen
            accessoryController.present(overlay, animated: true) { [weak self] in
                self?.record("accessory modal visible")
            }
            return
        }
        if let nativeStyle = ProcessInfo.processInfo.environment["AIM_KEYBOARD_NATIVE_MODAL"] {
            // Exercise UIKit's native presentation bookkeeping, not the custom
            // presentation controller used by the existing Retain probe.
            definesPresentationContext = true
            switch nativeStyle {
            case "OverFull": overlay.modalPresentationStyle = .overFullScreen
            case "OverCurrent": overlay.modalPresentationStyle = .overCurrentContext
            case "Form": overlay.modalPresentationStyle = .formSheet
            default: preconditionFailure("Unknown lab-only native style")
            }
            present(overlay, animated: true) { [weak self, weak overlay] in
                guard let self else { return }
                self.record("native \(nativeStyle) visible")
                overlay?.observation.text = "First responder: \(self.editor.isFirstResponder) · editing ends: \(self.editingEnds)"
            }
            return
        }
        if strategy.selectedSegmentIndex == 9 {
            // All mutations are to our own accessory and controller views.
            // Do not reach into the system-owned accessory host or keyboard.
            accessoryOverlay = overlay
            accessoryController.addChild(overlay)
            overlay.view.frame = accessory.convert(window.bounds, from: window)
            accessory.addSubview(overlay.view)
            overlay.didMove(toParent: accessoryController)
            overlay.view.layoutIfNeeded()
            record("accessory overlay visible")
            overlay.observation.text = "First responder: \(editor.isFirstResponder) · editing ends: \(editingEnds)"
            return
        }
        if strategy.selectedSegmentIndex == 5 {
            // Stock push/pop, no custom animator or keyboard-window access.
            navigationController?.pushViewController(overlay, animated: true)
            navigationController?.transitionCoordinator?.animate(alongsideTransition: nil) { [weak self, weak overlay] _ in
                guard let self else { return }
                overlay?.observation.text = "First responder: \(self.editor.isFirstResponder) · editing ends: \(self.editingEnds)"
            }
            return
        }
        if strategy.selectedSegmentIndex == 6 {
            overlay.modalPresentationStyle = .popover
            overlay.preferredContentSize = view.bounds.size
            let popover = overlay.popoverPresentationController!
            popover.delegate = self
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 8, width: 1, height: 1)
            popover.permittedArrowDirections = []
            if ProcessInfo.processInfo.environment["AIM_POPOVER_OVERLAP_PROBE"] == "1" {
                popover.canOverlapSourceViewRect = true
                popover.popoverLayoutMargins = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
                popover.sourceRect = view.bounds.insetBy(dx: 8, dy: 8)
            }
            present(overlay, animated: true) { [weak self, weak overlay] in
                guard let self else { return }
                overlay?.observation.text = "First responder: \(self.editor.isFirstResponder) · editing ends: \(self.editingEnds)"
            }
            return
        }
        if [4, 8].contains(strategy.selectedSegmentIndex), let scene = window.windowScene {
            // Ordinary app-owned key-window handoff, no access to keyboard
            // windows. Test whether the source responder retains its keyplane.
            let elevatedProbe = ProcessInfo.processInfo.environment["AIM_KEYBOARD_ELEVATED_PROBE"]
            let experiment: UIWindow
            if strategy.selectedSegmentIndex == 8 {
                experiment = elevatedProbe == "override"
                    ? AIMKeyboardLabElevatedWindow(windowScene: scene)
                    : AIMKeyboardLabNonKeyWindow(windowScene: scene)
            } else {
                experiment = UIWindow(windowScene: scene)
            }
            experiment.frame = window.frame
            experiment.windowLevel = strategy.selectedSegmentIndex == 8 ? .alert : UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
            // Explicitly user-authorized isolated probe. This value is an
            // experimental parameter, NOT a documented keyboard window level
            // and must never become a production layering assumption.
            if strategy.selectedSegmentIndex == 8, let elevatedProbe {
                let requested: CGFloat = elevatedProbe == "high" ? 1_000_000_000
                    : elevatedProbe == "override" ? 20_000_000 : 10_000_001
                experiment.windowLevel = UIWindow.Level(rawValue: requested)
                record("level requested=\(requested) getter=\(experiment.windowLevel.rawValue) base=\((experiment as? AIMKeyboardLabElevatedWindow)?.baseWindowLevel.rawValue ?? experiment.windowLevel.rawValue)")
            }
            experiment.backgroundColor = .clear
            experiment.rootViewController = overlay
            experimentWindow = experiment
            if strategy.selectedSegmentIndex == 8 { experiment.isHidden = false }
            else { experiment.makeKeyAndVisible() }
            record("overlay visible level=\(experiment.windowLevel.rawValue)")
            let windowMotion = ProcessInfo.processInfo.environment["AIM_KEYBOARD_WINDOW_MOTION"]
            if !media, windowMotion != nil {
                sourceWindowFrame = window.frame
                sourceWindowTransform = window.transform
            }
            UIView.animate(withDuration: 0.3) {
                let shift = self.view.bounds.width * 0.77
                if !media, windowMotion == "frame" {
                    window.frame = window.frame.offsetBy(dx: shift, dy: 0)
                } else if !media, windowMotion == "transform" {
                    window.transform = window.transform.translatedBy(x: shift, y: 0)
                } else {
                    self.view.transform = media ? .identity : CGAffineTransform(translationX: shift, y: 0)
                }
            } completion: { _ in
                self.record("window motion=\(windowMotion ?? "view") frame=\(window.frame) transform=\(window.transform)")
            }
            overlay.observation.text = "First responder: \(editor.isFirstResponder) · editing ends: \(editingEnds)"
            return
        }
        overlay.modalPresentationStyle = .custom
        overlay.transitioningDelegate = self
        present(overlay, animated: true) { [weak self, weak overlay] in
            guard let self else { return }
            overlay?.observation.text = "First responder: \(self.editor.isFirstResponder) · editing ends: \(self.editingEnds)"
        }
    }

    private func restore() {
        record("restore requested")
        editor.retainResponder = false
        if editor.inputView != nil {
            editor.inputView = nil
            editor.reloadInputViews()
        }
        if wasEditing && !editor.isFirstResponder { editor.becomeFirstResponder() }
        if editor.selectedRange != savedSelection { editor.selectedRange = savedSelection }
    }

    private func close() {
        if accessoryController.presentedViewController != nil {
            accessoryController.dismiss(animated: true) { [weak self] in
                self?.editor.retainResponder = false
                self?.finishExperiment()
            }
            return
        }
        if let overlay = accessoryOverlay {
            overlay.willMove(toParent: nil)
            overlay.view.removeFromSuperview()
            overlay.removeFromParent()
            accessoryOverlay = nil
            editor.retainResponder = false
            finishExperiment()
            return
        }
        if strategy.selectedSegmentIndex == 5 {
            navigationController?.popViewController(animated: true)
            navigationController?.transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in
                self?.restore()
                self?.finishExperiment()
            }
            return
        }
        if let experiment = experimentWindow {
            UIView.animate(withDuration: 0.3, animations: {
                self.view.transform = .identity
                if let transform = self.sourceWindowTransform { self.sourceWindow?.transform = transform }
                if let frame = self.sourceWindowFrame { self.sourceWindow?.frame = frame }
            }) { _ in
                self.sourceWindowFrame = nil
                self.sourceWindowTransform = nil
                if self.strategy.selectedSegmentIndex != 8 {
                    self.sourceWindow?.makeKey()
                    self.restore()
                }
                experiment.isHidden = true
                experiment.rootViewController = nil
                self.experimentWindow = nil
                self.finishExperiment()
            }
            return
        }
        restore()
        dismiss(animated: true) { [weak self] in self?.finishExperiment() }
    }

    private func finishExperiment() {
        screenSnapshot?.removeFromSuperview()
        screenSnapshot = nil
        view.transform = .identity
        record("presentation finished")
        status.text = "Captures: \(captured) · first responder: \(editor.isFirstResponder) · editing ends: \(editingEnds) · selection: \(editor.selectedRange.location):\(editor.selectedRange.length)"
    }

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        record("context preview requested")
        return UIContextMenuConfiguration(identifier: nil, previewProvider: { [weak self] in
            guard let self else { return nil }
            let preview = AIMKeyboardLabOverlay(media: true)
            preview.preferredContentSize = self.view.bounds.size
            preview.capture = { [weak self, weak interaction] in
                guard let self else { return }
                self.captured += 1
                self.record("context Capture action")
                interaction?.dismissMenu()
                self.finishExperiment()
            }
            preview.close = { [weak interaction] in interaction?.dismissMenu() }
            return preview
        }, actionProvider: { _ in UIMenu(children: [UIAction(title: "Close preview") { [weak interaction] _ in interaction?.dismissMenu() }]) })
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration, animator: any UIContextMenuInteractionCommitAnimating) {
        record("context preview commit (NOT Capture)")
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        restore()
        finishExperiment()
    }

    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
        if strategy.selectedSegmentIndex == 7 {
            let controller = AIMKeyboardLabCustomPopover(presentedViewController: presented, presenting: presenting)
            controller.sourceView = view
            controller.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 8, width: 1, height: 1)
            controller.permittedArrowDirections = []
            controller.delegate = self
            return controller
        }
        return AIMKeyboardLabPresentation(presentedViewController: presented, presenting: presenting)
    }
    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        AIMKeyboardLabAnimation(opening: true, media: media) { [weak self] cancelled in
            if cancelled { self?.restore(); self?.finishExperiment() }
        }
    }
    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        AIMKeyboardLabAnimation(opening: false, media: media, completion: { _ in })
    }
    func interactionControllerForPresentation(using animator: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? { interaction }
}

private final class AIMKeyboardLabAccessory: UIView {
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 1) }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        subviews.contains { !$0.isHidden && $0.frame.contains(point) }
    }
}

private final class AIMKeyboardLabNonKeyWindow: UIWindow {
    override var canBecomeKey: Bool { false }
}

/// Isolated getter-override experiment on OUR window, not a keyboard window.
/// Reading this getter is not evidence of compositor ordering: verify pixels
/// and physical button actions. No production guarantee is implied.
private final class AIMKeyboardLabElevatedWindow: UIWindow {
    override var canBecomeKey: Bool { false }
    var baseWindowLevel: UIWindow.Level { super.windowLevel }
    override var windowLevel: UIWindow.Level {
        get { UIWindow.Level(rawValue: 20_000_000) }
        set { super.windowLevel = newValue }
    }
}

/// Experimental subclass using inherited public presentation hooks only.
/// A successful frame override does not imply keyboard continuity or hit testing.
private final class AIMKeyboardLabCustomPopover: UIPopoverPresentationController {
    override var shouldRemovePresentersView: Bool { false }
    override var frameOfPresentedViewInContainerView: CGRect { containerView?.bounds ?? .zero }
}

final class AIMKeyboardLabEditor: UITextView {
    var rememberedInputMode: UITextInputMode?
    override var textInputMode: UITextInputMode? { rememberedInputMode ?? super.textInputMode }
    // Public input-mode restoration hint, not a promise to preserve the active
    // numeric/emoji keyplane. The lab tests that distinction on a real device.
    override var textInputContextIdentifier: String? {
        ProcessInfo.processInfo.environment["AIM_KEYBOARD_CONTEXT_ID"] == "1"
            ? "com.aimai.keyboard-lab.editor" : super.textInputContextIdentifier
    }
    var labAccessoryController: UIInputViewController?
    override var inputAccessoryViewController: UIInputViewController? { labAccessoryController ?? super.inputAccessoryViewController }
    var retainResponder = false
    override var canResignFirstResponder: Bool { !retainResponder && super.canResignFirstResponder }
}

private final class AIMKeyboardLabPresentation: UIPresentationController {
    override var shouldRemovePresentersView: Bool { false }
    override var frameOfPresentedViewInContainerView: CGRect { containerView?.bounds ?? .zero }
}

private final class AIMKeyboardLabAnimation: NSObject, UIViewControllerAnimatedTransitioning {
    let opening: Bool
    let media: Bool
    let completion: (Bool) -> Void
    init(opening: Bool, media: Bool, completion: @escaping (Bool) -> Void) {
        self.opening = opening; self.media = media; self.completion = completion
    }
    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval { 0.3 }
    func animateTransition(using context: UIViewControllerContextTransitioning) {
        guard let from = context.viewController(forKey: .from), let to = context.viewController(forKey: .to) else { return }
        let card = opening ? from.view! : to.view!
        let overlay = opening ? to.view! : from.view!
        if opening {
            overlay.frame = context.containerView.bounds
            context.containerView.addSubview(overlay)
            overlay.alpha = 0
        }
        UIView.animate(withDuration: 0.3, animations: {
            card.transform = self.opening && !self.media
                ? CGAffineTransform(translationX: context.containerView.bounds.width * 0.77, y: 0) : .identity
            overlay.alpha = self.opening ? 1 : 0
        }, completion: { _ in
            let cancelled = context.transitionWasCancelled
            if cancelled { card.transform = .identity; overlay.removeFromSuperview() }
            context.completeTransition(!cancelled)
            self.completion(cancelled)
        })
    }
}

private final class AIMKeyboardLabOverlay: UIViewController {
    let media: Bool
    var retainKeyboard = false
    let observation = UILabel()
    override var disablesAutomaticKeyboardDismissal: Bool { retainKeyboard }
    var close: (() -> Void)?
    var capture: (() -> Void)?
    init(media: Bool) { self.media = media; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let outside = UIButton(type: .custom)
        outside.accessibilityIdentifier = "lab-return"
        outside.accessibilityLabel = "Return to editor"
        outside.addAction(UIAction { [weak self] _ in self?.close?() }, for: .touchUpInside)
        outside.frame = view.bounds
        outside.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(outside)
        let panel = UIView()
        panel.backgroundColor = media ? .systemBlue : .secondarySystemBackground
        panel.accessibilityIdentifier = "lab-panel"
        panel.layer.cornerRadius = media ? 40 : 0
        panel.layer.cornerCurve = .continuous
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        let back = button("Back", id: "lab-back") { [weak self] in self?.close?() }
        back.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(back)
        if media {
            let capture = button("Capture", id: "lab-capture") { [weak self] in self?.capture?() }
            capture.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(capture)
            let height = min(600, (view.bounds.height * 0.7).rounded())
            NSLayoutConstraint.activate([
                panel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
                panel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
                panel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
                panel.heightAnchor.constraint(equalToConstant: height),
                back.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 24),
                back.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -24),
                capture.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
                capture.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -24)
            ])
        } else {
            NSLayoutConstraint.activate([
                panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                panel.topAnchor.constraint(equalTo: view.topAnchor),
                panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                panel.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.77),
                back.topAnchor.constraint(equalTo: panel.safeAreaLayoutGuide.topAnchor, constant: 24),
                back.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 24)
            ])
        }
        observation.numberOfLines = 0
        observation.textColor = .label
        observation.accessibilityIdentifier = "lab-observation"
        observation.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(observation)
        NSLayoutConstraint.activate([
            observation.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            observation.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            observation.topAnchor.constraint(equalTo: panel.safeAreaLayoutGuide.topAnchor, constant: 84)
        ])
    }
}

@MainActor
private func button(_ title: String, id: String, action: @escaping @MainActor () -> Void) -> UIButton {
    var configuration = UIButton.Configuration.filled()
    configuration.title = title
    configuration.contentInsets = .init(top: 12, leading: 12, bottom: 12, trailing: 12)
    let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
    button.accessibilityIdentifier = id
    return button
}
#endif
