import SwiftUI
import UIKit

/// The "Desktop" tab: XFCE in the guest, shown through VNC.
///
/// Touch model (direct, like a touchscreen laptop):
///  - tap                → left click where you tap
///  - drag (1 finger)    → left-button drag (move windows, select text)
///  - long press         → right click (context menus)
///  - 2-finger drag      → scroll wheel (pans the view instead when zoomed in)
///  - pinch              → zoom the whole desktop
///  - toolbar            → keyboard, Esc, Tab, sticky Ctrl/Alt, arrows
public final class DesktopViewController: UIViewController, UIScrollViewDelegate {
    private let vm = LinuxVMController.shared
    private var vnc: VNCClient?
    private var observers: [UUID] = []
    private var starting = false

    private let scrollView = UIScrollView()
    private let canvas = UIView()
    private let overlay = UIStackView()
    private let messageLabel = UILabel()
    private let logView = UITextView()
    private let actionButton = UIButton(type: .system)
    private let toolbar = UIToolbar()
    private let keyInput = KeyInputView()
    private var framebufferSize = CGSize.zero
    private var redrawPending = false
    private var wheelAccumulator: CGFloat = 0
    private var ctrlDown = false
    private var altDown = false
    private weak var ctrlItem: UIBarButtonItem?
    private weak var altItem: UIBarButtonItem?

    private var vncPassword: String {
        let key = "LinuxVM.vncPassword"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        // VNC auth uses at most 8 characters.
        let alphabet = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let generated = String((0..<8).map { _ in alphabet.randomElement()! })
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        canvas.layer.magnificationFilter = .linear
        canvas.layer.minificationFilter = .trilinear
        canvas.isHidden = true
        scrollView.addSubview(canvas)

        toolbar.barStyle = .black
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.items = makeToolbarItems()
        toolbar.isHidden = true
        view.addSubview(toolbar)

        keyInput.onText = { [weak self] text in self?.typeText(text) }
        keyInput.onBackspace = { [weak self] in self?.tapKey(0xFF08) }
        view.addSubview(keyInput)

        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.textColor = .white
        messageLabel.font = .preferredFont(forTextStyle: .body)
        logView.isEditable = false
        logView.backgroundColor = UIColor(white: 0.08, alpha: 1)
        logView.textColor = .lightGray
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.isHidden = true
        actionButton.configuration = .filled()
        actionButton.isHidden = true
        actionButton.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        overlay.axis = .vertical
        overlay.spacing = 16
        overlay.alignment = .fill
        overlay.translatesAutoresizingMaskIntoConstraints = false
        [messageLabel, actionButton, logView].forEach(overlay.addArrangedSubview)
        view.addSubview(overlay)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            overlay.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            overlay.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            logView.heightAnchor.constraint(equalToConstant: 260),
        ])

        installGestures()

        observers.append(vm.observeState { [weak self] state in self?.vmStateChanged(state) })
        vm.start()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutCanvas()
    }

    /// Fits the framebuffer into the visible area (aspect fit, centred).
    private func layoutCanvas() {
        guard framebufferSize.width > 0 else { return }
        let bounds = scrollView.bounds.size
        let scale = min(bounds.width / framebufferSize.width, bounds.height / framebufferSize.height)
        let fitted = CGSize(width: framebufferSize.width * scale, height: framebufferSize.height * scale)
        if scrollView.zoomScale == 1 {
            canvas.frame = CGRect(origin: .zero, size: fitted)
            scrollView.contentSize = fitted
        }
        centerCanvas()
    }

    private func centerCanvas() {
        let bounds = scrollView.bounds.size
        let content = scrollView.contentSize
        scrollView.contentInset = UIEdgeInsets(
            top: max(0, (bounds.height - content.height) / 2),
            left: max(0, (bounds.width - content.width) / 2),
            bottom: 0, right: 0
        )
    }

    public func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }
    public func scrollViewDidZoom(_ scrollView: UIScrollView) { centerCanvas() }

    // MARK: - State

    private func show(message: String, button: String? = nil, log: Bool = false) {
        overlay.isHidden = false
        messageLabel.text = message
        actionButton.isHidden = button == nil
        actionButton.configuration?.title = button
        logView.isHidden = !log
    }

    private func vmStateChanged(_ state: LinuxVMController.State) {
        switch state {
        case .idle, .installing, .booting, .restoring:
            show(message: "Ubuntu is starting…\nProgress is shown in the Ubuntu tab.")
        case .ready:
            if vnc == nil { Task { await connectDesktop() } }
        case .paused:
            break
        case .stopped:
            vnc?.stop()
            show(message: "The VM is not running. Reopen the app to start it.")
        }
    }

    private enum Action { case install, start, retry }
    private var pendingAction: Action?

    @objc private func actionTapped() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        Task {
            switch action {
            case .install: await installDesktop()
            case .start, .retry: await connectDesktop()
            }
        }
    }

    /// Connects straight away if the VNC server is already up (it survives
    /// in the snapshot), otherwise starts it, or offers to install.
    private func connectDesktop() async {
        guard !starting else { return }
        starting = true
        defer { starting = false }

        if await attach() { return }

        show(message: "Starting the desktop…")
        let installed = (try? await vm.shell.run("test -f ~/.ios-desktop-installed && echo yes"))?.contains("yes") == true
        guard installed else {
            pendingAction = .install
            show(message: """
            Install the Ubuntu desktop (XFCE)?

            About 250 MB of packages. Under emulation this takes roughly 15–40 minutes \
            (much faster with JIT enabled). You can keep using the Ubuntu tab meanwhile, \
            but keep the app open.
            """, button: "Install desktop")
            return
        }
        do {
            try await startServer()
            if await attach(retryFor: 60) { return }
            throw VNCClient.Error.closed
        } catch {
            pendingAction = .retry
            show(message: "Could not start the desktop: \(error.localizedDescription)", button: "Try again")
        }
    }

    private func installDesktop() async {
        guard let script = LinuxVMController.bundledScript("desktop-install") else { return }
        logView.text = ""
        show(message: "Installing the desktop… keep the app open.", log: true)
        do {
            try await vm.shell.stream(GuestShell.scriptCommand(script)) { [weak self] text in
                DispatchQueue.main.async { self?.appendLog(text) }
            }
            await connectDesktop()
        } catch {
            pendingAction = .install
            show(message: "Installation failed: \(error.localizedDescription)", button: "Try again", log: true)
        }
    }

    private func appendLog(_ text: String) {
        logView.text.append(text)
        if logView.text.count > 20_000 {
            logView.text = String(logView.text.suffix(15_000))
        }
        logView.scrollRangeToVisible(NSRange(location: (logView.text as NSString).length - 1, length: 1))
    }

    private func startServer() async throws {
        guard let script = LinuxVMController.bundledScript("desktop-start") else { return }
        try await vm.shell.run(GuestShell.scriptCommand(
            script,
            arguments: [vm.profile.desktopGeometry],
            environment: ["IOS_VNC_PASSWORD": vncPassword]
        ))
    }

    /// Tries to open a VNC session; true once the first frame arrived.
    private func attach(retryFor seconds: TimeInterval = 0) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if await attachOnce() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        } while Date() < deadline
        return false
    }

    private func attachOnce() async -> Bool {
        let client = VNCClient(port: vm.configuration.vncPort, password: vncPassword)
        // Only the first result matters; keep at most one buffered so every
        // later frame doesn't pile up in an unread stream.
        let firstFrame = AsyncStream<Bool>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            client.onUpdate = { [weak self, weak client] _, _ in
                continuation.yield(true)
                DispatchQueue.main.async {
                    guard let self, let client else { return }
                    self.scheduleRedraw(from: client)
                }
            }
            client.onClose = { [weak self, weak client] error in
                continuation.yield(false)
                continuation.finish()
                DispatchQueue.main.async {
                    guard let self, let client else { return }
                    self.vncClosed(client, error: error)
                }
            }
        }
        client.start()
        for await ok in firstFrame {
            if ok {
                vnc = client
                overlay.isHidden = true
                canvas.isHidden = false
                toolbar.isHidden = false
                return true
            }
            return false
        }
        return false
    }

    private func vncClosed(_ client: VNCClient, error: Error?) {
        guard vnc === client else { return }
        vnc = nil
        canvas.isHidden = true
        toolbar.isHidden = true
        if vm.state == .ready {
            // e.g. the socket died while suspended, or the user logged out.
            Task { await connectDesktop() }
        }
    }

    // MARK: - Rendering

    /// Coalesces bursts of framebuffer updates into one layer update per
    /// main-runloop turn.
    private func scheduleRedraw(from client: VNCClient) {
        guard !redrawPending else { return }
        redrawPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.redrawPending = false
            guard let image = client.withFramebuffer({ pixels, width, height in
                Self.makeImage(pixels, width: width, height: height)
            }) else { return }
            let size = CGSize(width: image.width, height: image.height)
            if size != self.framebufferSize {
                self.framebufferSize = size
                self.scrollView.zoomScale = 1
                self.layoutCanvas()
            }
            self.canvas.layer.contents = image
        }
    }

    private static func makeImage(_ pixels: UnsafeRawBufferPointer, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, let base = pixels.baseAddress,
              let provider = CGDataProvider(data: Data(bytes: base, count: width * height * 4) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    // MARK: - Pointer

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        drag.maximumNumberOfTouches = 1
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(handleWheel(_:)))
        wheel.minimumNumberOfTouches = 2
        wheel.maximumNumberOfTouches = 2
        tap.require(toFail: longPress)
        [tap, longPress, drag, wheel].forEach(canvas.addGestureRecognizer)
        canvas.isUserInteractionEnabled = true
    }

    private func framebufferPoint(_ location: CGPoint) -> (Int, Int) {
        guard canvas.bounds.width > 0 else { return (0, 0) }
        let scale = framebufferSize.width / canvas.bounds.width
        return (Int(location.x * scale), Int(location.y * scale))
    }

    private func click(at location: CGPoint, button: UInt8) {
        let (x, y) = framebufferPoint(location)
        vnc?.sendPointer(x: x, y: y, buttons: 0)
        vnc?.sendPointer(x: x, y: y, buttons: button)
        vnc?.sendPointer(x: x, y: y, buttons: 0)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        click(at: gesture.location(in: canvas), button: 1)
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        click(at: gesture.location(in: canvas), button: 4)
    }

    @objc private func handleDrag(_ gesture: UIPanGestureRecognizer) {
        let (x, y) = framebufferPoint(gesture.location(in: canvas))
        switch gesture.state {
        case .began:
            let start = gesture.location(in: canvas)
            let translation = gesture.translation(in: canvas)
            let (sx, sy) = framebufferPoint(CGPoint(x: start.x - translation.x, y: start.y - translation.y))
            vnc?.sendPointer(x: sx, y: sy, buttons: 0)
            vnc?.sendPointer(x: sx, y: sy, buttons: 1)
            vnc?.sendPointer(x: x, y: y, buttons: 1)
        case .changed:
            vnc?.sendPointer(x: x, y: y, buttons: 1)
        default:
            vnc?.sendPointer(x: x, y: y, buttons: 0)
        }
    }

    @objc private func handleWheel(_ gesture: UIPanGestureRecognizer) {
        // Zoomed in: two fingers pan the view (the scroll view does that).
        guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return }
        let (x, y) = framebufferPoint(gesture.location(in: canvas))
        wheelAccumulator += gesture.translation(in: canvas).y
        gesture.setTranslation(.zero, in: canvas)
        let step: CGFloat = 18
        while abs(wheelAccumulator) >= step {
            let button: UInt8 = wheelAccumulator > 0 ? 8 : 16 // natural scrolling
            vnc?.sendPointer(x: x, y: y, buttons: button)
            vnc?.sendPointer(x: x, y: y, buttons: 0)
            wheelAccumulator -= wheelAccumulator > 0 ? step : -step
        }
    }

    // MARK: - Keyboard

    private func makeToolbarItems() -> [UIBarButtonItem] {
        func key(_ title: String, _ keysym: UInt32) -> UIBarButtonItem {
            UIBarButtonItem(title: title, primaryAction: UIAction { [weak self] _ in self?.tapKey(keysym) })
        }
        let keyboard = UIBarButtonItem(image: UIImage(systemName: "keyboard"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            if self.keyInput.isFirstResponder {
                self.keyInput.resignFirstResponder()
            } else {
                self.keyInput.becomeFirstResponder()
            }
        })
        let ctrl = UIBarButtonItem(title: "Ctrl", primaryAction: UIAction { [weak self] _ in self?.toggleCtrl() })
        let alt = UIBarButtonItem(title: "Alt", primaryAction: UIAction { [weak self] _ in self?.toggleAlt() })
        ctrlItem = ctrl
        altItem = alt
        let flexible = UIBarButtonItem.flexibleSpace()
        return [keyboard, flexible, key("Esc", 0xFF1B), key("Tab", 0xFF09), ctrl, alt,
                key("←", 0xFF51), key("↑", 0xFF52), key("↓", 0xFF54), key("→", 0xFF53)]
    }

    private func toggleCtrl() {
        ctrlDown.toggle()
        vnc?.sendKey(0xFFE3, down: ctrlDown)
        ctrlItem?.tintColor = ctrlDown ? .systemOrange : nil
    }

    private func toggleAlt() {
        altDown.toggle()
        vnc?.sendKey(0xFFE9, down: altDown)
        altItem?.tintColor = altDown ? .systemOrange : nil
    }

    /// Sticky modifiers apply to the next key only, like Termux's extra keys.
    private func releaseModifiers() {
        if ctrlDown { toggleCtrl() }
        if altDown { toggleAlt() }
    }

    private func tapKey(_ keysym: UInt32) {
        vnc?.tapKey(keysym)
        releaseModifiers()
    }

    private func typeText(_ text: String) {
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": vnc?.tapKey(0xFF0D)
            case "\t": vnc?.tapKey(0xFF09)
            default:
                // Latin-1 keysyms equal the code point; everything else uses
                // the X11 Unicode keysym range (0x01000000 + code point).
                let value = scalar.value
                vnc?.tapKey(value < 0x100 ? value : 0x0100_0000 + value)
            }
        }
        releaseModifiers()
    }
}

/// Invisible view that brings up the iOS keyboard and forwards typing.
private final class KeyInputView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var keyboardType: UIKeyboardType = .asciiCapable

    func insertText(_ text: String) { onText?(text) }
    func deleteBackward() { onBackspace?() }
}

public struct DesktopScreen: UIViewControllerRepresentable {
    public init() {}

    public func makeUIViewController(context: Context) -> DesktopViewController {
        DesktopViewController()
    }

    public func updateUIViewController(_ uiViewController: DesktopViewController, context: Context) {}
}
