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

        // Python 3.7.13 interpreter, precompiled for iOS — see
        // Docs/STATUS.md for how PYTHONHOME is wired up (bundled stdlib
        // resource, since these binary targets ship no .py files at all).
        //
        // branch, not a version tag: the only tag this repo has (v1.0)
        // predates Package.swift being added at all — `swift package
        // resolve` fails outright trying to read it ("/Package.swift
        // doesn't exist"). Only `master` has SPM support.
        .package(url: "https://github.com/holzschu/python3_ios.git", branch: "master"),

        // Lua interpreter, precompiled for iOS. Same story as python3_ios
        // above: its only tag (1.0) has no Package.swift, master does.
        .package(url: "https://github.com/holzschu/lua_ios.git", branch: "master"),

        // Swift bindings to libgit2, for the "git" command below. Tracks the
        // `spm` branch, not a version tag: this fork's SPM support only
        // exists there — its own semver tags (0.4.0-0.6.0) are inherited
        // history from upstream SwiftGit2/SwiftGit2 predating the SPM/iOS
        // port and have no Package.swift at all. Transitively pulls in
        // Clibgit2 (a prebuilt libgit2 xcframework, checksum verified by
        // hand against the real release asset).
        .package(url: "https://github.com/light-tech/SwiftGit2.git", branch: "spm")
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
                .product(name: "network_ios", package: "network_ios"),
                .product(name: "Python", package: "python3_ios"),
                .product(name: "lua_ios", package: "lua_ios"),
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
                .copy("Resources/commandDictionary.plist"),

                // python3_ios ships zero .py files — the interpreter binary
                // alone has no standard library to import os/json/etc. from.
                // This is a trimmed (no test/idlelib/turtledemo) copy of
                // CPython v3.7.13's own Lib/ directory — the exact version
                // python3_ios embeds — laid out as PYTHONHOME expects:
                // <PYTHONHOME>/lib/python3.7/*.py. See ShellEngine.start()
                // for where PYTHONHOME actually gets pointed at this bundle,
                // and Docs/STATUS.md for provenance/licensing (PSF license
                // included alongside).
                .copy("Resources/PythonHome")
            ]
        )
    ]
)
