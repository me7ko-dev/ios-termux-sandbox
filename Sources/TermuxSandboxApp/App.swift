import SwiftUI
import UIKit

/// SwiftUI wrapper around the UIKit `TabbedTerminalViewController` (multi-tab,
/// Docs/NEXT_STEPS.md item 4). SwiftTerm is UIKit-only, so this is a thin
/// `UIViewControllerRepresentable` shim rather than a native SwiftUI screen.
public struct TerminalScreen: UIViewControllerRepresentable {
    public init() {}

    public func makeUIViewController(context: Context) -> TabbedTerminalViewController {
        TabbedTerminalViewController()
    }

    public func updateUIViewController(_ uiViewController: TabbedTerminalViewController, context: Context) {}
}

/// NOTE: not wired up as `@main` — this package builds as a library
/// (SwiftPM can't emit a signed .app bundle). On Mac, create an Xcode iOS App
/// target, add this package as a local dependency, and set that target's
/// `@main` App struct's body to `TerminalScreen().ignoresSafeArea()`.
/// See Docs/STATUS.md.
public struct TermuxSandboxRootView: View {
    public init() {}

    public var body: some View {
        TerminalScreen()
            .ignoresSafeArea()
            .preferredColorScheme(.dark)
    }
}
