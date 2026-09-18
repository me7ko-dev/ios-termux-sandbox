# ios-termux-sandbox

Termux-style terminal for iOS, in-process only (no jailbreak, no fork/exec) —
built on [ios_system](https://github.com/holzschu/ios_system) (plus
[network_ios](https://github.com/holzschu/network_ios), vendored locally),
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm),
[Citadel](https://github.com/orlandos-nl/Citadel) (`sshc`, password or key
auth), [SwiftGit3](https://github.com/joehinkle11/SwiftGit3) (`git`), and an
embedded [CPython 3.13](https://github.com/beeware/Python-Apple-support)
(`python`/`python3`). Also ships `bc`/`dc` (a from-scratch Double-precision
Swift implementation, not a port of GNU bc).

Developed without a Mac — every change is verified through a GitHub Actions
CI build (`.github/workflows/ios-build.yml`) rather than a local `swift
build`/Xcode run, so it compiles but hasn't been run on a real device or
simulator. Start with `Docs/STATUS.md` for what exists and what's verified,
`Docs/NEXT_STEPS.md` for per-feature detail (including real, documented
scope cuts — e.g. `bc`/`dc` has no arbitrary-precision, Python's C-extension
modules have an unverified dlopen/code-signing question), and
`Docs/ROADMAP.md` for the overall plan, including a lower-priority
browser/WASM fallback track.
