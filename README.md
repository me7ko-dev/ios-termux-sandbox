# ios-termux-sandbox

Termux-style terminal for iOS with two tabs:

- **Ubuntu** — a full Ubuntu 22.04 arm64 VM (real kernel, systemd, apt,
  gcc…) running under QEMU inside the app: JIT-accelerated when JIT is
  enabled (SideStore/AltStore + StikDebug, or Xcode), interpreter (TCTI)
  otherwise. Serial console while booting, then SSH with a real PTY.
- **iOS shell** — in-process [ios_system](https://github.com/holzschu/ios_system)
  commands (no VM, instant start), with
  [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) and
  [Citadel](https://github.com/orlandos-nl/Citadel).

Build the installable app: `Scripts/fetch-qemu-frameworks.sh` (QEMU from
UTM's release IPAs), `xcodegen generate --spec App/project.yml` — or grab
the `UbuntuTerminal-ipa` artifact from CI. See `Docs/STATUS.md` for what is
verified and what isn't, and `Docs/NEXT_STEPS.md` for the plan.
