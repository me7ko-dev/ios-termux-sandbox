import SwiftTerm
import SwiftUI
import UIKit

/// Full-screen terminal into the Ubuntu VM. Drives the whole lifecycle,
/// Termux-style, right in the terminal: first-run download → boot (serial
/// console shows the kernel/systemd output) → once the guest reports sshd is
/// up, switches to an SSH session with a real PTY.
public final class LinuxTerminalViewController: UIViewController, TerminalViewDelegate {
    private enum Phase {
        case idle, installing, booting, ssh, sshClosed, stopped
    }

    /// Guest login the seed ISO creates (Guest/cloud-init/user-data).
    public static let defaultUsername = "ubuntu"
    public static let defaultPasswordKey = "LinuxVM.password"

    private let terminalView = TerminalView(frame: .zero)
    private let store = ImageStore()
    private let configuration = VMConfiguration.recommended()
    private lazy var serial = SerialConsole(port: configuration.serialPort)
    private var ssh: SSHTerminalSession?
    private var phase = Phase.idle
    private var serialTail = ""

    private static let readyMarker = "IOS-VM-READY"

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        terminalView.frame = view.bounds
        terminalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        terminalView.terminalDelegate = self
        view.addSubview(terminalView)
        Task { await self.launch() }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        _ = terminalView.becomeFirstResponder()
    }

    // MARK: - Lifecycle

    private func status(_ text: String) {
        terminalView.feed(text: "\u{1B}[1;36m" + text.replacingOccurrences(of: "\n", with: "\r\n") + "\u{1B}[0m\r\n")
    }

    private func launch() async {
        status(UbuntuRelease.name)
        status("vCPUs: \(configuration.cpuCount)   RAM: \(configuration.memoryMiB) MiB   disk: \(configuration.diskSize >> 30) GiB")

        guard let selection = QEMURuntime.selectBackend() else {
            if QEMURuntime.framework(named: "qemu-aarch64-softmmu") != nil {
                status("""
                JIT is not enabled for this app, and no interpreter (TCTI) build of QEMU is bundled.
                Enable JIT (e.g. StikDebug / SideStore, or launch from Xcode) and reopen the app.
                """)
            } else {
                status(QEMURuntime.Error.notBundled.localizedDescription)
            }
            phase = .stopped
            return
        }
        let (backend, binary) = selection
        status("QEMU backend: \(backend.rawValue)")
        if backend == .interpreter {
            status("Tip: enable JIT for this app for several times more speed.")
        }

        if !store.isInstalled {
            phase = .installing
            status("First run: downloading Ubuntu (~750 MB), verifying SHA-256…")
            do {
                try await store.install(diskSize: configuration.diskSize) { [weak self] progress in
                    let percent = progress.totalBytes > 0 ? Int(progress.receivedBytes * 100 / progress.totalBytes) : 0
                    DispatchQueue.main.async { self?.showDownload(progress.fileName, percent: percent) }
                }
                terminalView.feed(text: "\r\n")
            } catch {
                status("\r\nInstall failed: \(error.localizedDescription)\nReopen the app to retry (finished files are kept).")
                phase = .stopped
                return
            }
        }

        boot(binary: binary)
    }

    private var lastProgressLine = ""

    private func showDownload(_ fileName: String, percent: Int) {
        let line = "  \(fileName): \(percent)%"
        guard line != lastProgressLine else { return }
        lastProgressLine = line
        terminalView.feed(text: "\r\u{1B}[K" + line)
    }

    private func boot(binary: URL) {
        guard let seed = Bundle.module.url(forResource: "seed", withExtension: "iso") else {
            status("seed.iso missing from the app bundle")
            return
        }
        phase = .booting
        status("Booting… (first boot runs cloud-init and takes a few minutes under emulation)")

        serial.onData = { [weak self] data in
            DispatchQueue.main.async { self?.handleSerial(data) }
        }
        serial.connect()

        let arguments = configuration.arguments(store: store, seedISO: seed, dataDirectory: QEMURuntime.dataDirectory)
        do {
            try QEMURuntime.start(binary: binary, arguments: arguments) { [weak self] status, fatal in
                DispatchQueue.main.async { self?.vmExited(status: status, fatal: fatal) }
            }
        } catch {
            status("Could not start QEMU: \(error.localizedDescription)")
            phase = .stopped
        }
    }

    private func handleSerial(_ data: Data) {
        // Serial output is the terminal until SSH takes over, and again if
        // the SSH session drops.
        if phase != .ssh {
            terminalView.feed(byteArray: Array(data)[...])
        }
        serialTail = String((serialTail + String(decoding: data, as: UTF8.self)).suffix(256))
        if serialTail.contains(Self.readyMarker) {
            serialTail = ""
            if phase == .booting {
                connectSSH()
            }
        }
    }

    private func connectSSH() {
        let password = UserDefaults.standard.string(forKey: Self.defaultPasswordKey) ?? "ubuntu"
        let session = SSHTerminalSession(
            port: Int(configuration.sshPort),
            username: Self.defaultUsername,
            password: password,
            cols: terminalView.getTerminal().cols,
            rows: terminalView.getTerminal().rows
        )
        session.onData = { [weak self] data in
            DispatchQueue.main.async { self?.terminalView.feed(byteArray: Array(data)[...]) }
        }
        session.onClose = { [weak self] error in
            DispatchQueue.main.async { self?.sshClosed(error) }
        }
        ssh = session
        phase = .ssh
        terminalView.feed(text: "\u{1B}[2J\u{1B}[H")
        session.start()
    }

    private func sshClosed(_ error: Error?) {
        ssh = nil
        guard phase == .ssh else { return }
        phase = .sshClosed
        if let error {
            status("\r\nSSH: \(error.localizedDescription)")
        }
        status("\r\n[SSH session ended — press Enter for a new one; other keys go to the serial console]")
    }

    private func vmExited(status code: Int32, fatal: Bool) {
        phase = .stopped
        ssh?.stop()
        serial.stop()
        status(fatal
            ? "\r\nQEMU stopped with an error (see output above)."
            : "\r\nThe VM has powered off.")
        status("Close and reopen the app to boot again — QEMU can only run once per app launch.")
    }

    // MARK: - TerminalViewDelegate

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        switch phase {
        case .ssh:
            ssh?.send(Data(data))
        case .sshClosed where data.contains(0x0D):
            phase = .booting
            connectSSH()
        case .booting, .sshClosed:
            serial.send(Data(data))
        case .idle, .installing, .stopped:
            break
        }
    }

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        ssh?.resize(cols: newCols, rows: newRows)
    }

    public func scrolled(source: TerminalView, position: Double) {}
    public func setTerminalTitle(source: TerminalView, title: String) {}
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) {
            UIApplication.shared.open(url)
        }
    }
    public func bell(source: TerminalView) {}
    public func clipboardCopy(source: TerminalView, content: Data) {
        UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
    }
    public func clipboardRead(source: TerminalView) -> Data? {
        UIPasteboard.general.string.map { Data($0.utf8) }
    }
    public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// SwiftUI wrapper, same pattern as TermuxSandboxApp's `TerminalScreen`.
public struct LinuxTerminalScreen: UIViewControllerRepresentable {
    public init() {}

    public func makeUIViewController(context: Context) -> LinuxTerminalViewController {
        LinuxTerminalViewController()
    }

    public func updateUIViewController(_ uiViewController: LinuxTerminalViewController, context: Context) {}
}
