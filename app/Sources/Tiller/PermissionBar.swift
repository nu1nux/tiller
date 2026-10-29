import AppKit

/// Asks whether a site may use the camera or microphone: a glass card at the
/// top of the page naming the site, with Block, Allow Once and Always Allow.
/// Closing it denies the request this once. When macOS refuses Tiller the
/// devices instead, it says so and offers System Settings. It also asks
/// whether a site may open a link in another app, with Cancel, Open and
/// Always Open.
final class PermissionBar: NSView {
    enum Answer {
        /// Denied, and denied from now on.
        case block
        case allowOnce
        /// Allowed, and allowed from now on.
        case allowAlways
        /// Closed: denied this once.
        case dismiss
    }

    enum Content: Equatable {
        case request(MediaRequest)
        /// macOS refuses Tiller these devices.
        case refused(Set<MediaDevice>)
        case app(AppRequest)
    }

    var onAnswer: ((Answer) -> Void)?
    var onOpenSettings: (() -> Void)?
    private(set) var content: Content?

    private let glass = GlassView()
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    let blockButton = NSButton(title: "Block", target: nil, action: nil)
    let allowOnceButton = NSButton(title: "Allow Once", target: nil, action: nil)
    let allowButton = NSButton(title: "Always Allow", target: nil, action: nil)
    let settingsButton = NSButton(title: "Open System Settings", target: nil, action: nil)
    private let closeButton = Theme.iconButton("xmark", label: "Close", size: Theme.Symbol.inline, frame: Theme.ButtonSize.inline)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        icon.contentTintColor = Theme.danger
        icon.setContentHuggingPriority(.required, for: .horizontal)

        label.font = .systemFont(ofSize: Theme.FontSize.body)
        label.textColor = Theme.text
        label.isSelectable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        closeButton.image = Theme.closeImage(size: 9, label: "Close")
        (closeButton as? HoverButton)?.plateRadius = Theme.ButtonSize.inline / 2
        closeButton.target = self
        closeButton.action = #selector(close(_:))

        for (button, action) in [
            (blockButton, #selector(block(_:))),
            (allowOnceButton, #selector(allowOnce(_:))),
            (allowButton, #selector(allowAlways(_:))),
            (settingsButton, #selector(openSettings(_:))),
        ] {
            button.target = self
            button.action = action
            button.bezelStyle = .push
            button.controlSize = .regular
        }
        // No Return key equivalent: a key typed into the page must never
        // answer for the user.

        let top = NSStackView(views: [icon, label, closeButton])
        top.alignment = .top
        top.spacing = 8
        let buttons = NSStackView(views: [NSView(), blockButton, allowOnceButton, allowButton, settingsButton])
        buttons.spacing = 8
        let column = NSStackView(views: [top, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 10)
        NSLayoutConstraint.activate([
            top.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -24),
            buttons.widthAnchor.constraint(equalTo: top.widthAnchor),
        ])

        glass.contentView = column
        glass.cornerRadius = Theme.Radius.plate
        // As the find bar's: still visible over a white page.
        glass.tintColor = Theme.background.dynamic(alpha: 0.85)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
        // Narrows when the page is too narrow to hold it. Below the split
        // view's holding priorities, so it never widens the page and pushes
        // the sidebar or the agent panel aside.
        let width = glass.widthAnchor.constraint(equalToConstant: 440)
        width.priority = .init(255)
        width.isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Narrow pages

    private var answerButtons: [NSButton] { [blockButton, allowOnceButton, allowButton, settingsButton] }

    /// The page width under which regular buttons no longer fit side by
    /// side: theirs, the spacing, and the card's and the page's margins.
    private lazy var compactBelow: CGFloat = {
        let buttons = [blockButton, allowOnceButton, allowButton]
        return buttons.reduce(0) { $0 + $1.fittingSize.width } + 3 * 8 + 24 + 2 * Theme.Padding.panel
    }()

    private var isCompact = false {
        didSet {
            guard isCompact != oldValue else { return }
            let size: NSControl.ControlSize = isCompact ? .small : .regular
            for button in answerButtons {
                button.controlSize = size
                button.font = .systemFont(ofSize: NSFont.systemFontSize(for: size))
            }
        }
    }

    // Follows the page's width, as the bar at its narrowest doesn't change
    // size of its own when the page does.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        guard let superview else { return }
        superview.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(pageResized), name: NSView.frameDidChangeNotification, object: superview)
        pageResized()
    }

    @objc private func pageResized() {
        guard let width = superview?.bounds.width else { return }
        isCompact = width < compactBelow
    }

    func show(_ content: Content) {
        self.content = content
        let text: NSMutableAttributedString
        let font = NSFont.systemFont(ofSize: Theme.FontSize.body)
        let bold = NSFont.systemFont(ofSize: Theme.FontSize.body, weight: .semibold)
        switch content {
        case .request(let request):
            text = NSMutableAttributedString(
                string: SitePermissions.displayName(request.origin), attributes: [.font: bold, .foregroundColor: Theme.text])
            text.append(NSAttributedString(
                string: " wants to use your \(MediaDevice.names(request.devices)).",
                attributes: [.font: font, .foregroundColor: Theme.text]))
        case .refused(let refused):
            text = NSMutableAttributedString(
                string: "macOS isn't letting Tiller use your \(MediaDevice.names(refused)). "
                    + "Turn Tiller on in Privacy & Security, then reload the page.",
                attributes: [.font: font, .foregroundColor: Theme.text])
        case .app(let request):
            let site = request.origin.isEmpty ? "This page" : SitePermissions.displayName(request.origin)
            text = NSMutableAttributedString(string: site, attributes: [.font: bold, .foregroundColor: Theme.text])
            text.append(NSAttributedString(
                string: " wants to open \(request.app.name).", attributes: [.font: font, .foregroundColor: Theme.text]))
        }
        label.attributedStringValue = text
        setAccessibilityLabel(text.string)
        switch content {
        case .request(let request): showDevices(request.devices)
        case .refused(let refused): showDevices(refused)
        case .app(let request):
            let image = NSWorkspace.shared.icon(forFile: request.app.url.path)
            image.size = NSSize(width: Theme.Symbol.bar + 4, height: Theme.Symbol.bar + 4)
            image.accessibilityDescription = request.app.name
            icon.image = image
            icon.contentTintColor = nil
        }
        let (block, once, always) = if case .app = content {
            ("Cancel", "Open", "Always Open")
        } else {
            ("Block", "Allow Once", "Always Allow")
        }
        blockButton.title = block
        allowOnceButton.title = once
        allowButton.title = always
        blockButton.isHidden = if case .refused = content { true } else { false }
        allowOnceButton.isHidden = blockButton.isHidden
        // Only a website's choice is kept.
        allowButton.isHidden = switch content {
        case .request: false
        case .refused: true
        case .app(let request): request.origin.isEmpty
        }
        settingsButton.isHidden = !blockButton.isHidden
    }

    private func showDevices(_ devices: Set<MediaDevice>) {
        let symbol = devices.contains(.camera) ? "video.fill" : "mic.fill"
        icon.image = Theme.symbol(symbol, size: Theme.Symbol.bar, label: MediaDevice.names(devices))
        icon.contentTintColor = Theme.danger
    }

    @objc private func block(_ sender: Any?) { onAnswer?(.block) }
    @objc private func allowOnce(_ sender: Any?) { onAnswer?(.allowOnce) }
    @objc private func allowAlways(_ sender: Any?) { onAnswer?(.allowAlways) }
    @objc private func close(_ sender: Any?) { onAnswer?(.dismiss) }
    @objc private func openSettings(_ sender: Any?) { onOpenSettings?() }

    // Clicks on the card stay on it rather than reaching the page.
    override var mouseDownCanMoveWindow: Bool { false }
}
