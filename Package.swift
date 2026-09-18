// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TermuxSandbox",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(name: "SysInfoCommand", targets: ["SysInfoCommand"]),
        .library(name: "SSHClientCommand", targets: ["SSHClientCommand"])
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
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.7.0")
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
                "SwiftTerm",
                "SysInfoCommand",
                "SSHClientCommand"
            ]
        )
    ]
)
