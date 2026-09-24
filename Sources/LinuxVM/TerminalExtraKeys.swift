import SwiftTerm
import UIKit

/// Extra keys above the keyboard for a SwiftTerm `TerminalView`, replacing
/// SwiftTerm's own accessory, whose keyboard button swaps the iOS keyboard
/// for a Shift/F1/F2 panel instead of hiding it.
///
///  - pinned left: hide the keyboard (tap the terminal to bring it back)
///  - pinned right: ← ↓ ↑ → (hold to repeat)
///  - scrolling middle: Esc, sticky Ctrl/Alt, Tab, Home/End/PgUp/PgDn,
///    ~ | / -, F1–F12
///
/// Keys from the bar go to `output` as-is. Sticky Ctrl/Alt also apply to
/// the next key typed on the iOS keyboard: route the terminal delegate's
/// `send` through `applyModifiers(_:)` before handling it.
@MainActor
public final class TerminalExtraKeys {
    public private(set) var bar: ExtraKeysBar!
    private weak var terminalView: TerminalView?
    private let output: ([UInt8]) -> Void
    private var ctrl = false
    private var alt = false

    public init(terminalView: TerminalView, output: @escaping ([UInt8]) -> Void) {
        self.terminalView = terminalView
        self.output = output
        bar = makeBar()
        terminalView.inputAccessoryView = bar
    }

    /// Applies (and releases) armed Ctrl/Alt to keyboard input.
    public func applyModifiers(_ data: ArraySlice<UInt8>) -> [UInt8] {
        // Escape sequences are SwiftTerm's own (hardware arrows, terminal
        // replies) — pass them through and keep the modifiers armed.
        guard ctrl || alt, let first = data.first, first != 0x1B else { return Array(data) }
        var bytes = Array(data)
        if ctrl, bytes.count == 1 {
            bytes[0] = Self.control(bytes[0])
        }
        if alt {
            bytes.insert(0x1B, at: 0)
        }
        setModifiers(ctrl: false, alt: false)
        return bytes
    }

    private func makeBar() -> ExtraKeysBar {
        func send(_ title: String, _ bytes: [UInt8]) -> ExtraKeysBar.Key {
            ExtraKeysBar.Key(title) { [weak self] in self?.sendKey(bytes) }
        }
        func text(_ character: String) -> ExtraKeysBar.Key {
            ExtraKeysBar.Key(character) { [weak self] in
                guard let self else { return }
                var bytes = Array(character.utf8)
                if self.ctrl, bytes.count == 1 { bytes[0] = Self.control(bytes[0]) }
                self.sendKey(bytes)
            }
        }
        func cursor(_ title: String, _ symbol: String, _ final: UInt8) -> ExtraKeysBar.Key {
            ExtraKeysBar.Key(title, symbol: symbol, repeats: true) { [weak self] in self?.sendCursor(final) }
        }
        let hide = ExtraKeysBar.Key("Hide keyboard", symbol: "keyboard.chevron.compact.down") { [weak self] in
            _ = self?.terminalView?.resignFirstResponder()
        }
        let ctrlKey = ExtraKeysBar.Key("CTRL") { [weak self] in
            guard let self else { return }
            self.setModifiers(ctrl: !self.ctrl, alt: self.alt)
        }
        let altKey = ExtraKeysBar.Key("ALT") { [weak self] in
            guard let self else { return }
            self.setModifiers(ctrl: self.ctrl, alt: !self.alt)
        }
        var keys = [
            send("ESC", [0x1B]), ctrlKey, altKey, send("TAB", [0x09]),
            ExtraKeysBar.Key("HOME") { [weak self] in self?.sendCursor(UInt8(ascii: "H")) },
            ExtraKeysBar.Key("END") { [weak self] in self?.sendCursor(UInt8(ascii: "F")) },
            ExtraKeysBar.Key("PGUP") { [weak self] in self?.sendTilde(5) },
            ExtraKeysBar.Key("PGDN") { [weak self] in self?.sendTilde(6) },
            text("~"), text("|"), text("/"), text("-"),
        ]
        keys += EscapeSequences.cmdF.enumerated().map { index, bytes in send("F\(index + 1)", bytes) }
        return ExtraKeysBar(
            leading: [hide],
            keys: keys,
            trailing: [
                cursor("Left", "arrow.left", UInt8(ascii: "D")),
                cursor("Down", "arrow.down", UInt8(ascii: "B")),
                cursor("Up", "arrow.up", UInt8(ascii: "A")),
                cursor("Right", "arrow.right", UInt8(ascii: "C")),
            ]
        )
    }

    private func setModifiers(ctrl: Bool, alt: Bool) {
        self.ctrl = ctrl
        self.alt = alt
        bar.setActive(ctrl, forKey: "CTRL")
        bar.setActive(alt, forKey: "ALT")
    }

    /// xterm modifier parameter: 1 + Alt(2) + Ctrl(4).
    private var modifierParameter: Int { 1 + (alt ? 2 : 0) + (ctrl ? 4 : 0) }

    private func sendKey(_ bytes: [UInt8]) {
        output(alt && bytes.first != 0x1B ? [0x1B] + bytes : bytes)
        setModifiers(ctrl: false, alt: false)
    }

    /// Arrows, Home, End: `ESC [ 1 ; m X` with modifiers, else normal or
    /// application-cursor form depending on what the program asked for.
    private func sendCursor(_ final: UInt8) {
        let bytes: [UInt8]
        if modifierParameter > 1 {
            bytes = Array("\u{1B}[1;\(modifierParameter)".utf8) + [final]
        } else if terminalView?.getTerminal().applicationCursor == true {
            bytes = [0x1B, UInt8(ascii: "O"), final]
        } else {
            bytes = [0x1B, UInt8(ascii: "["), final]
        }
        output(bytes)
        setModifiers(ctrl: false, alt: false)
    }

    /// PgUp (5) / PgDn (6): `ESC [ n ~`, or `ESC [ n ; m ~` with modifiers.
    private func sendTilde(_ number: Int) {
        let modifiers = modifierParameter > 1 ? ";\(modifierParameter)" : ""
        output(Array("\u{1B}[\(number)\(modifiers)~".utf8))
        setModifiers(ctrl: false, alt: false)
    }

    /// Ctrl+key as a terminal sends it: letters and @[\]^_ → 0x00–0x1F,
    /// space → NUL, / → ^_, ? → DEL; anything else unchanged.
    static func control(_ byte: UInt8) -> UInt8 {
        switch byte {
        case 0x40...0x5F, 0x61...0x7A: return byte & 0x1F
        case UInt8(ascii: " "): return 0
        case UInt8(ascii: "/"): return 0x1F
        case UInt8(ascii: "?"): return 0x7F
        default: return byte
        }
    }
}
