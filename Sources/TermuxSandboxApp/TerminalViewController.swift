import LinuxVM
import UIKit
import SwiftTerm

/// Minimal terminal screen: a full-bleed `SwiftTerm.TerminalView` reading
/// keystrokes, feeding a line at a time into `ShellEngine`, and rendering
/// whatever bytes come back. No line-editing niceties yet (history, tab
/// completion) — see Docs/NEXT_STEPS.md.
public final class TerminalViewController: UIViewController, TerminalViewDelegate {

    private let terminalView = TerminalView(frame: .zero)
    private let shellEngine: ShellEngine
    private var lineBuffer = ""
    private var extraKeys: TerminalExtraKeys?

    public init() {
        let sandboxHome = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        shellEngine = ShellEngine(workingDirectory: sandboxHome)
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
            self?.handleInput(bytes[...])
        }

        shellEngine.onOutput = { [weak self] data in
            self?.terminalView.feed(byteArray: Array(data)[...])
        }
        shellEngine.start()

        writePrompt()
    }

    private func writePrompt() {
        terminalView.feed(text: "\r\n$ ")
    }

    // MARK: - TerminalViewDelegate

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        handleInput(extraKeys?.applyModifiers(data)[...] ?? data)
    }

    private func handleInput(_ data: ArraySlice<UInt8>) {
        // While a command is running, every keystroke goes straight to its
        // stdin instead of our own line buffer — that's what lets python3's
        // REPL, sshc in interactive mode, etc. read anything at all (their
        // reads used to hit the sandboxed app's real, never-written-to
        // stdin and just hang). See Docs/NEXT_STEPS.md item 2.
        //
        // There's still no real pty, so this is best-effort: we echo locally
        // ourselves (the command has no terminal to echo through) and
        // translate Enter to '\n' for line-buffered readers like fgets, but
        // a program doing its own raw-mode line editing (vim, a real
        // readline prompt) won't see backspace as anything but a literal
        // 0x7F byte — known limitation, not something fixable without a
        // real pty layer.
        if shellEngine.isRunning {
            forwardLiveInput(data)
            return
        }

        for byte in data {
            switch byte {
            case 0x0D: // Enter
                terminalView.feed(text: "\r\n")
                let command = lineBuffer
                lineBuffer = ""
                guard !command.trimmingCharacters(in: .whitespaces).isEmpty else {
                    writePrompt()
                    continue
                }
                shellEngine.run(command) { [weak self] _ in
                    self?.writePrompt()
                }
            case 0x7F: // Backspace
                if !lineBuffer.isEmpty {
                    lineBuffer.removeLast()
                    terminalView.feed(text: "\u{8} \u{8}")
                }
            default:
                // UnicodeScalar(UInt8) is non-failable — every byte 0...255
                // maps to a valid Latin-1 scalar, so there's no Optional to unwrap.
                let character = Character(UnicodeScalar(byte))
                lineBuffer.append(character)
                terminalView.feed(text: String(character))
            }
        }
    }

    private func forwardLiveInput(_ data: ArraySlice<UInt8>) {
        for byte in data {
            switch byte {
            case 0x0D: // Enter -> '\n' for fgets/readline-style readers
                terminalView.feed(text: "\r\n")
                shellEngine.sendInput(Data([0x0A]))
            case 0x7F: // Backspace — local echo only, see note above
                terminalView.feed(text: "\u{8} \u{8}")
                shellEngine.sendInput(Data([byte]))
            default:
                let character = Character(UnicodeScalar(byte))
                terminalView.feed(text: String(character))
                shellEngine.sendInput(Data([byte]))
            }
        }
    }

    public func scrolled(source: TerminalView, position: Double) {}
    public func setTerminalTitle(source: TerminalView, title: String) {}
    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    public func bell(source: TerminalView) {}
    public func clipboardCopy(source: TerminalView, content: Data) {}
    public func clipboardRead(source: TerminalView) -> Data? { nil }
    public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
