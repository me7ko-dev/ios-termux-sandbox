import SwiftTerm
import SwiftUI
import UIKit

/// Full-screen terminal into the Ubuntu VM. Shows the controller's console
/// (download progress, boot log on the serial line) until the guest is
/// ready, then an SSH session with a real PTY. After the app comes back
/// from the background (VM paused + snapshotted meanwhile), a dropped SSH
/// session reconnects on its own.
public final class LinuxTerminalViewController: UIViewController, TerminalViewDelegate {
    private enum Phase {
        case console, ssh, sshClosed
    }

    private let terminalView = TerminalView(frame: .zero)
    private let vm = LinuxVMController.shared
    private var ssh: SSHTerminalSession?
    private var phase = Phase.console
    private var observers: [UUID] = []
    private var extraKeys: TerminalExtraKeys?
    /// Consecutive automatic reconnects without any output in between —
    /// stops a tight loop if sshd is really gone.
    private var autoReconnects = 0

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
        extraKeys = TerminalExtraKeys(terminalView: terminalView) { [weak self] bytes in
            self?.route(bytes[...])
        }

        observers.append(vm.observeConsole { [weak self] data in
            guard let self, self.phase != .ssh else { return }
            self.terminalView.feed(byteArray: Array(data)[...])
        })
        observers.append(vm.observeState { [weak self] state in
            self?.vmStateChanged(state)
        })
        vm.start()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        _ = terminalView.becomeFirstResponder()
    }

    private func vmStateChanged(_ state: LinuxVMController.State) {
        switch state {
        case .ready where phase != .ssh:
            connectSSH()
        case .stopped:
            ssh?.stop()
        default:
            break
        }
    }

    private func connectSSH() {
        let session = SSHTerminalSession(
            port: Int(vm.configuration.sshPort),
            username: LinuxVMController.username,
            password: vm.password,
            cols: terminalView.getTerminal().cols,
            rows: terminalView.getTerminal().rows
        )
        session.onData = { [weak self] data in
            DispatchQueue.main.async {
                self?.autoReconnects = 0
                self?.terminalView.feed(byteArray: Array(data)[...])
            }
        }
        session.onClose = { [weak self] error in
            DispatchQueue.main.async { self?.sshClosed(error, session: session) }
        }
        ssh = session
        phase = .ssh
        terminalView.feed(text: "\u{1B}[2J\u{1B}[H")
        session.start()
    }

    private func sshClosed(_ error: Error?, session: SSHTerminalSession) {
        guard ssh === session else { return }
        ssh = nil
        phase = .sshClosed
        if vm.state == .paused {
            // The connection died while iOS had us suspended; the state
            // observer reconnects once the VM is running again.
            phase = .console
            return
        }
        if let error {
            vm.status("\r\nSSH: \(error.localizedDescription)")
            if vm.state == .ready, autoReconnects < 3 {
                // Not a clean `exit` — most likely the socket died while iOS
                // had the app suspended. Just get a new session.
                autoReconnects += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.phase == .sshClosed, self.vm.state == .ready else { return }
                    self.connectSSH()
                }
                return
            }
        }
        vm.status("\r\n[SSH session ended — press Enter for a new one; other keys go to the serial console]")
    }

    // MARK: - TerminalViewDelegate

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        route(extraKeys?.applyModifiers(data)[...] ?? data)
    }

    private func route(_ data: ArraySlice<UInt8>) {
        switch phase {
        case .ssh:
            ssh?.send(Data(data))
        case .sshClosed where data.contains(0x0D) && vm.state == .ready:
            connectSSH()
        case .console, .sshClosed:
            vm.sendToSerial(Data(data))
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
