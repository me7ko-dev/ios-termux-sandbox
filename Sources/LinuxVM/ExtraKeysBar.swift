import UIKit

/// Termux-style row of extra keys, used above the iOS keyboard (as an
/// `inputAccessoryView`) and, on the Desktop tab, also at the bottom of the
/// screen while the keyboard is hidden.
///
/// Three groups so nothing important can end up off-screen: `leading` and
/// `trailing` are pinned (hide keyboard, options, arrows), everything in
/// `keys` sits in a horizontal scroller between them — swipe it for F-keys.
public final class ExtraKeysBar: UIInputView, UIInputViewAudioFeedback {
    public struct Key {
        public var id: String
        public var title: String
        /// SF Symbol shown instead of the title.
        public var symbol: String?
        /// Auto-repeats while held (arrows).
        public var repeats = false
        /// Pops up this menu instead of calling `action`.
        public var menu: UIMenu?
        public var action: () -> Void

        public init(_ title: String, id: String? = nil, symbol: String? = nil, repeats: Bool = false,
                    menu: UIMenu? = nil, action: @escaping () -> Void = {}) {
            self.id = id ?? title
            self.title = title
            self.symbol = symbol
            self.repeats = repeats
            self.menu = menu
            self.action = action
        }
    }

    public static let height: CGFloat = 46

    private var buttons: [String: KeyButton] = [:]

    public init(leading: [Key] = [], keys: [Key], trailing: [Key] = []) {
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: Self.height),
                   inputViewStyle: .keyboard)
        autoresizingMask = .flexibleWidth
        allowsSelfSizing = true

        let scroller = KeyScrollView()
        scroller.showsHorizontalScrollIndicator = false
        scroller.alwaysBounceHorizontal = true
        scroller.delaysContentTouches = false
        scroller.canCancelContentTouches = true
        let middle = makeStack(keys)
        middle.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(middle)

        let row = UIStackView(arrangedSubviews: [makeStack(leading), scroller, makeStack(trailing)])
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        let guide = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            row.bottomAnchor.constraint(equalTo: topAnchor, constant: Self.height - 5),
            middle.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            middle.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            middle.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            middle.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            middle.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    public var enableInputClicksWhenVisible: Bool { true }

    /// Highlights a sticky modifier (Ctrl, Alt, …) while it is armed.
    public func setActive(_ active: Bool, forKey id: String) {
        buttons[id]?.isActive = active
    }

    private func makeStack(_ keys: [Key]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: keys.map { key in
            let button = KeyButton(key: key)
            buttons[key.id] = button
            return button
        })
        stack.axis = .horizontal
        stack.spacing = 5
        stack.alignment = .fill
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        return stack
    }
}

/// Lets a swipe that starts on a key scroll the row instead of pressing it.
private final class KeyScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

private final class KeyButton: UIButton {
    private let key: ExtraKeysBar.Key
    private var repeatTimer: Timer?
    private var didRepeat = false

    var isActive = false {
        didSet { updateColors() }
    }

    init(key: ExtraKeysBar.Key) {
        self.key = key
        super.init(frame: .zero)
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
        if let symbol = key.symbol {
            config.image = UIImage(systemName: symbol,
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        } else {
            config.attributedTitle = AttributedString(key.title, attributes: AttributeContainer([
                .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
            ]))
        }
        configuration = config
        accessibilityLabel = key.title
        widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        updateColors()

        if let menu = key.menu {
            self.menu = menu
            showsMenuAsPrimaryAction = true
        } else if key.repeats {
            addTarget(self, action: #selector(repeatBegan), for: .touchDown)
            addTarget(self, action: #selector(repeatReleased), for: .touchUpInside)
            addTarget(self, action: #selector(repeatCancelled), for: [.touchUpOutside, .touchCancel])
        } else {
            addTarget(self, action: #selector(tapped), for: .touchUpInside)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateColors() {
        configuration?.baseBackgroundColor = isActive ? .systemOrange : UIColor(white: 0.28, alpha: 1)
        configuration?.baseForegroundColor = isActive ? .black : .white
    }

    private func fire() {
        UIDevice.current.playInputClick()
        key.action()
    }

    @objc private func tapped() { fire() }

    /// Held: first repeat after 0.4 s, then ~14 per second. A plain tap
    /// fires once, on release, so swiping the row doesn't type arrows.
    @objc private func repeatBegan() {
        didRepeat = false
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.didRepeat = true
                self.fire()
                self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.fire() }
                }
            }
        }
    }

    @objc private func repeatReleased() {
        let fireOnce = !didRepeat
        repeatCancelled()
        if fireOnce { fire() }
    }

    @objc private func repeatCancelled() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        didRepeat = false
    }
}
