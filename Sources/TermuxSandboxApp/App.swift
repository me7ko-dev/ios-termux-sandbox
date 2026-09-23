import LinuxVM
import SwiftUI
import UIKit

/// SwiftUI wrapper around the UIKit `TerminalViewController`. SwiftTerm is
/// UIKit-only, so this is a thin `UIViewControllerRepresentable` shim rather
/// than a native SwiftUI screen.
public struct TerminalScreen: UIViewControllerRepresentable {
    public init() {}

    public func makeUIViewController(context: Context) -> TerminalViewController {
        TerminalViewController()
    }

    public func updateUIViewController(_ uiViewController: TerminalViewController, context: Context) {}
}

/// Three tabs over one Ubuntu 22.04 VM plus the lightweight shell:
///  - Ubuntu: terminal into the VM (real Linux, apt, everything)
///  - Desktop: the same VM's XFCE desktop over VNC
///  - iOS shell: in-process ios_system commands, starts instantly and works
///    on files in the app's Documents folder
///
/// The @main App struct lives in App/Sources/Main.swift (the Xcode app
/// target generated from App/project.yml) and just shows this view.
public struct TermuxSandboxRootView: View {
    public init() {}

    public var body: some View {
        TabView {
            LinuxTerminalScreen()
                .ignoresSafeArea(.container, edges: .top)
                .tabItem { Label("Ubuntu", systemImage: "terminal") }
            DesktopScreen()
                .ignoresSafeArea(.container, edges: [.top, .horizontal])
                .tabItem { Label("Desktop", systemImage: "macwindow") }
            TerminalScreen()
                .ignoresSafeArea(.container, edges: .top)
                .tabItem { Label("iOS shell", systemImage: "apple.terminal") }
        }
        .preferredColorScheme(.dark)
    }
}
