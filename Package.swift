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
        .library(name: "GitCommand", targets: ["GitCommand"]),
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

        // `git` command support. Upstream SwiftGit2/SwiftGit2 has no SPM
        // manifest at all (Carthage + git submodules only) — this fork
        // vendors prebuilt Clibgit2/Clibssh2/Clibcrypto/Clibssl xcframeworks
        // (real binaries committed to the repo, not Git LFS or a remote
        // checksum'd release asset, so it can't hit the same checksum-drift
        // failure we saw with network_ios below) and includes an ios-arm64
        // slice for real-device builds, not just the simulator. See
        // Docs/ROADMAP.md Track A.
        .package(url: "https://github.com/joehinkle11/SwiftGit3.git", exact: "1.2.2")
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

        .target(
            name: "GitCommand",
            dependencies: [
                .product(name: "SwiftGit2", package: "SwiftGit3"),
                .product(name: "ios_system", package: "ios_system")
            ]
        ),

        // dig/host/ifconfig/nc/nslookup/ping/ping6/rlogin/telnet/whois/wol —
        // not part of ios_system's own Package.swift targets.
        //
        // holzschu/network_ios's own Package.swift binary-target checksum
        // doesn't match its actual v0.2 release asset (verified directly:
        // `shasum -a 256` on the downloaded zip gives
        // 18e96112ae86ec39390487d850e7732d88e446f9f233b2792d633933d4606d46,
        // not the 89a465b3... the manifest declares) — an upstream bug we
        // can't fix by pinning a different version number. Vendoring the
        // xcframework locally (same pattern as SwiftGit3 above) sidesteps
        // the checksum mechanism entirely, since it only applies to remote
        // binaryTargets. Trimmed to the ios-arm64 device slice only (real
        // download included simulator + Mac Catalyst slices and dSYMs we
        // don't need, at ~7x the size) — matches this project's CI, which
        // already builds for generic iOS device, not the simulator.
        .binaryTarget(
            name: "network_ios",
            path: "Vendor/network_ios.xcframework"
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
                "network_ios",
                "SwiftTerm",
                "SysInfoCommand",
                "SSHClientCommand",
                "GitCommand"
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
