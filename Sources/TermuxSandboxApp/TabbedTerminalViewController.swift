import UIKit

/// Multi-tab container (Docs/NEXT_STEPS.md item 4 / Docs/ROADMAP.md Track A
/// item 9) — each tab is its own `TerminalViewController`, which means its
/// own `ShellEngine`, which means its own `ios_switchSession` token: tabs
/// get independent working directories and environments, exactly like
/// separate Termux sessions, not separate views onto one shared shell.
///
/// Standard UIViewController containment (`addChild`/`didMove`), one tab's
/// view attached to `contentContainer` at a time; the rest sit fully
/// detached (not just hidden) so their `TerminalViewController`s stay alive
/// — closing a tab is what actually deallocates one, which is what runs
/// `ShellEngine.deinit`'s `ios_closeSession`.
public final class TabbedTerminalViewController: UIViewController {

    private final class Tab {
        let id = UUID()
        let controller = TerminalViewController()
        var title: String
        init(title: String) { self.title = title }
    }

    private var tabs: [Tab] = []
    private var activeTabID: UUID?
    private var nextTabNumber = 1

    private let tabBarScrollView = UIScrollView()
    private let tabBarStack = UIStackView()
    private let addButton = UIButton(type: .system)
    private let contentContainer = UIView()

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        layoutChrome()
        addTab()
    }

    private func layoutChrome() {
        tabBarScrollView.showsHorizontalScrollIndicator = false
        tabBarScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabBarScrollView)

        tabBarStack.axis = .horizontal
        tabBarStack.spacing = 4
        tabBarStack.translatesAutoresizingMaskIntoConstraints = false
        tabBarScrollView.addSubview(tabBarStack)

        addButton.setTitle("+", for: .normal)
        addButton.tintColor = .white
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.addTarget(self, action: #selector(addTabTapped), for: .touchUpInside)
        view.addSubview(addButton)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)

        let barHeight: CGFloat = 36
        NSLayoutConstraint.activate([
            tabBarScrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tabBarScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBarScrollView.trailingAnchor.constraint(equalTo: addButton.leadingAnchor),
            tabBarScrollView.heightAnchor.constraint(equalToConstant: barHeight),

            tabBarStack.topAnchor.constraint(equalTo: tabBarScrollView.topAnchor),
            tabBarStack.bottomAnchor.constraint(equalTo: tabBarScrollView.bottomAnchor),
            tabBarStack.leadingAnchor.constraint(equalTo: tabBarScrollView.leadingAnchor, constant: 4),
            tabBarStack.trailingAnchor.constraint(equalTo: tabBarScrollView.trailingAnchor),
            tabBarStack.heightAnchor.constraint(equalTo: tabBarScrollView.heightAnchor),

            addButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            addButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            addButton.widthAnchor.constraint(equalToConstant: 32),
            addButton.heightAnchor.constraint(equalToConstant: barHeight),

            contentContainer.topAnchor.constraint(equalTo: tabBarScrollView.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    @objc private func addTabTapped() {
        addTab()
    }

    private func addTab() {
        let tab = Tab(title: "\(nextTabNumber)")
        nextTabNumber += 1
        tabs.append(tab)
        activate(tabID: tab.id)
    }

    /// Closing the last remaining tab starts a fresh one instead of leaving
    /// zero tabs — matches how a real terminal app's "close tab" behaves
    /// when it's the only one open (a new session, not an empty screen).
    private func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = activeTabID == id
        let tab = tabs.remove(at: index)

        detach(tab.controller)

        if tabs.isEmpty {
            addTab()
        } else if wasActive {
            let fallbackIndex = min(index, tabs.count - 1)
            activate(tabID: tabs[fallbackIndex].id)
        } else {
            rebuildTabBar()
        }
    }

    private func activate(tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }

        for other in tabs where other.id != tabID {
            detach(other.controller)
        }

        if tab.controller.parent == nil {
            addChild(tab.controller)
            tab.controller.view.frame = contentContainer.bounds
            tab.controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            contentContainer.addSubview(tab.controller.view)
            tab.controller.didMove(toParent: self)
        }

        activeTabID = tabID
        rebuildTabBar()
    }

    private func detach(_ controller: TerminalViewController) {
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    private func rebuildTabBar() {
        tabBarStack.arrangedSubviews.forEach {
            tabBarStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        for tab in tabs {
            tabBarStack.addArrangedSubview(makeTabButton(for: tab))
        }
    }

    private func makeTabButton(for tab: Tab) -> UIView {
        let container = UIStackView()
        container.axis = .horizontal
        container.spacing = 2
        container.isLayoutMarginsRelativeArrangement = true
        container.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 6)
        // UIStackView is a non-drawing view — .backgroundColor isn't
        // reliably respected, but its backing CALayer's is.
        container.layer.backgroundColor = (tab.id == activeTabID ? UIColor.darkGray : UIColor.black).cgColor
        container.layer.cornerRadius = 6
        container.layer.masksToBounds = true

        let titleButton = UIButton(type: .system)
        titleButton.setTitle(tab.title, for: .normal)
        titleButton.tintColor = tab.id == activeTabID ? .white : .lightGray
        titleButton.addAction(UIAction { [weak self] _ in self?.activate(tabID: tab.id) }, for: .touchUpInside)

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("✕", for: .normal)
        closeButton.tintColor = .lightGray
        closeButton.addAction(UIAction { [weak self] _ in self?.closeTab(id: tab.id) }, for: .touchUpInside)

        container.addArrangedSubview(titleButton)
        container.addArrangedSubview(closeButton)
        return container
    }
}
