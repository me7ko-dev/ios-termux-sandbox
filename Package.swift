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
        .library(name: "LinuxVM", targets: ["LinuxVM"]),
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
        // Points at our own fork, not holzschu/network_ios directly: upstream's
        // Package.swift declares a binary-target checksum (89a465b3...) that no
        // longer matches the actual v0.2 release asset (real sha256 is
        // 18e96112..., verified by hand) — swift package resolve fails
        // regardless of what revision we pin there. The fork changes nothing
        // but that one checksum; the .zip itself is still fetched from
        // holzschu's original release URL. See Docs/STATUS.md.
        .package(url: "https://github.com/me7ko-dev/network_ios.git", branch: "master"),

        // Lua interpreter, precompiled for iOS. Tracks master: its only tag
        // (1.0) predates Package.swift, so `swift package resolve` can't use it.
        .package(url: "https://github.com/holzschu/lua_ios.git", branch: "master"),

        // Swift bindings to libgit2, for the "git" command below. Tracks the
        // `spm` branch, not a version tag: this fork's SPM support only
        // exists there — its own semver tags (0.4.0-0.6.0) are inherited
        // history from upstream SwiftGit2/SwiftGit2 predating the SPM/iOS
        // port and have no Package.swift at all. Transitively pulls in
        // Clibgit2 (a prebuilt libgit2 xcframework, checksum verified by
        // hand against the real release asset).
        .package(url: "https://github.com/light-tech/SwiftGit2.git", branch: "spm"),

        // Explicit for LinuxVM's SSH PTY session (PseudoTerminalRequest,
        // ByteBuffer). Same URL/range Citadel itself pins, so SwiftPM
        // resolves one copy — see Citadel's own Package.swift.
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4" ..< "0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0")
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

        // Deliberately partial `git` — see GitCommand.swift's header comment
        // for exactly what SwiftGit2's API does and doesn't cover.
        .target(
            name: "GitCommand",
            dependencies: [
                .product(name: "SwiftGit2", package: "SwiftGit2"),
                .product(name: "ios_system", package: "ios_system")
            ],
            // Clibgit2's static libgit2.a calls iconv_open/iconv/iconv_close
            // (path precomposition, NTLM) but doesn't declare the library —
            // only surfaced when the first real .app got linked (CI
            // package-ipa: "Undefined symbols: _iconv").
            linkerSettings: [.linkedLibrary("iconv")]
        ),

        // MARK: - Ubuntu 22.04 VM (full Linux, QEMU in-process)

        // dlopen()s QEMU and runs it on its own thread, in-process (iOS has
        // no fork/exec). C rather than Swift because it has to catch QEMU's
        // exit() calls with atexit + pthread_exit, like UTM does.
        .target(name: "CQEMUBootstrap"),

        // Downloads/verifies the pinned Ubuntu cloud image, boots it under
        // QEMU and gives a terminal into it (serial console while booting,
        // then SSH with a real PTY). The QEMU frameworks themselves are
        // embedded by the app target — see Scripts/fetch-qemu-frameworks.sh
        // and App/project.yml; SwiftPM has no way to ship them.
        .target(
            name: "LinuxVM",
            dependencies: [
                "CQEMUBootstrap",
                "Citadel",
                "SwiftTerm",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio")
            ],
            resources: [
                // cloud-init NoCloud seed built from Guest/cloud-init/ by
                // Scripts/make-seed-iso.py.
                .copy("Resources/seed.iso"),
                // Guest-side scripts the app runs over SSH: idempotent
                // tune-up on every connect, and the Desktop tab's XFCE +
                // TigerVNC install/start.
                .copy("Resources/guest-tune.sh"),
                .copy("Resources/desktop-install.sh"),
                .copy("Resources/desktop-start.sh"),
                // Claude Code (official native installer) for the guest
                // terminal, run detached on every start until installed.
                .copy("Resources/claude-code-install.sh")
            ]
        ),

        // Runtime deps of ios_system's curl_ios/ssh_cmd frameworks, same
        // author's prebuilt release (checksums computed from the real assets).
        .binaryTarget(
            name: "openssl",
            url: "https://github.com/holzschu/libssh2-for-iOS/releases/download/v1.2/openssl.xcframework.zip",
            checksum: "b13ab2943ebe5ced0048fb917dd36dd9756ab20da9c50b1f667eebac39c689ed"
        ),
        .binaryTarget(
            name: "libssh2",
            url: "https://github.com/holzschu/libssh2-for-iOS/releases/download/v1.2/libssh2.xcframework.zip",
            checksum: "47015c95d80a6e6b222698682ea09db1d97f9e7c4936481b4a53fae68fdc33f5"
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
                .product(name: "network_ios", package: "network_ios"),
                // ios_system's curl_ios and ssh_cmd link @rpath/openssl + libssh2
                // but its Package.swift doesn't ship them -> dyld abort at launch.
                "openssl",
                "libssh2",
                .product(name: "lua_ios", package: "lua_ios"),
                "SwiftTerm",
                "SysInfoCommand",
                "SSHClientCommand",
                "GitCommand",
                "LinuxVM"
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
