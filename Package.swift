// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TermuxSandbox",
    platforms: [
        // Citadel requires iOS 17+ (see Docs/STATUS.md) — v16 built but
        // failed to link with "requires minimum platform version 17.0".
        .iOS(.v17)
    ],
    products: [
        .library(name: "SysInfoCommand", targets: ["SysInfoCommand"]),
        .library(name: "SSHClientCommand", targets: ["SSHClientCommand"]),
        // Was missing — without this, an Xcode App target can't `import
        // TermuxSandboxApp` to get `TermuxSandboxRootView` at all.
        .library(name: "TermuxSandboxApp", targets: ["TermuxSandboxApp"])
    ],
    dependencies: [
        // Core Unix command layer — compiles ls/cat/grep/tar/curl/ssh/python-less
        // shell tools as static libraries, dispatched in-process (no fork/exec).
        .package(url: "https://github.com/holzschu/ios_system.git", branch: "master"),

        // ANSI/VT100 terminal view for the app's UIKit front-end.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),

        // Pure-Swift SSH2 client (NIO-based). Chosen over ios_system's bundled
        // ssh_cmd (libssh2) for the "sshc" command below because it needs no C
        // cross-compilation step and officially targets iOS 17+ — see Docs/NEXT_STEPS.md.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.7.0"),

        // dig/host/ifconfig/nc/nslookup/ping/rlogin/telnet/whois/wol — not part
        // of ios_system's own Package.swift targets, needs its own dependency.
        //
        // TEMPORARILY DISABLED (2026-09-18): network_ios's own Package.swift
        // declares a binary-target checksum that no longer matches the actual
        // release asset at holzschu/network_ios — `swift package resolve`
        // fails with a checksum mismatch regardless of what we pin here (an
        // upstream bug, not something under our control). Re-enable once
        // holzschu fixes the release, or fork and patch the checksum
        // ourselves. See Docs/NEXT_STEPS.md.
        // .package(url: "https://github.com/holzschu/network_ios.git", branch: "master")
    ],
    targets: [
        // MARK: - New commands (this session's deliverable)

        .target(
            name: "SysInfoCommand",
            dependencies: [
                .product(name: "ios_system", package: "ios_system")
            ]
        ),

        .target(
            name: "SSHClientCommand",
            dependencies: [
                "Citadel",
                .product(name: "ios_system", package: "ios_system")
            ]
        ),

        // MARK: - App shell (terminal UI + command registry)
        // NOTE: this is a library target, not an .app product, because SwiftPM
        // cannot itself produce a signed iOS .app bundle. On Mac, wrap this in
        // an Xcode App target (File > New > Project > iOS App) and add
        // TermuxSandbox as a local Swift Package dependency of that target,
        // or convert this package to an Xcode project once the command set
        // stabilizes. See Docs/STATUS.md "Как да отвориш в Xcode".
        .target(
            name: "TermuxSandboxApp",
            dependencies: [
                .product(name: "ios_system", package: "ios_system"),
                // network_ios temporarily disabled — see dependencies list above.
                "SwiftTerm",
                "SysInfoCommand",
                "SSHClientCommand"
            ],
            resources: [
                // Command→framework/function map, filtered from a-Shell's own
                // shipped commandDictionary.plist down to exactly the
                // frameworks this project links — see Docs/NEXT_STEPS.md
                // item 1. Loaded explicitly via addCommandList() in
                // ShellEngine.start(); not something ios_system registers on
                // its own from a plain `initializeEnvironment()` call.
                .copy("Resources/commandDictionary.plist")
            ]
        )
    ]
)
