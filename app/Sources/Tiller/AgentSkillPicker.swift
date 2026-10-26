import AppKit

/// One choice in a `CompletionPicker`: `prefix` and `name` on top, with an
/// optional hint after them, a badge at the end and an icon before, and
/// `detail` under them.
struct CompletionItem {
    var prefix: String
    var name: String
    var hint: String?
    var badge: String?
    var detail: String
    var icon: NSImage?
}

/// The list that opens above the message field while it holds a `/` and the
/// start of a skill's name, or an `@` and part of a tab's: what matches,
/// with what each is. Arrow keys move the selection, and Tab, Return or a
/// click completes it. What was typed shows in the accent in each name. It
/// sits on the same material as the address bar's suggestions, and rises a
/// little as it fades in.
final class CompletionPicker: NSVisualEffectView {
    /// Called with the place of the item clicked in what `show` was given.
    var onPick: ((Int) -> Void)?

    private let stack = NSStackView()
    private var rows: [CompletionPickerRow] = []
    private(set) var items: [CompletionItem] = []
    private var selected = 0
    static let maxRows = 7

    /// `label` names the list for VoiceOver.
    init(label: String) {
        super.init(frame: .zero)
        wantsLayer = true
        material = .popover
        blendingMode = .withinWindow
        state = .active
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
        setAccessibilityRole(.list)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Lists `matches`, the first `maxRows` of them, with `query` in the
    /// accent in each name, and hides when there are none. Returns whether
    /// any are listed.
    @discardableResult
    func show(_ matches: [CompletionItem], highlighting query: String) -> Bool {
        let matches = Array(matches.prefix(Self.maxRows))
        if matches.map({ $0.name + "\n" + $0.detail }) != items.map({ $0.name + "\n" + $0.detail }) {
            items = matches
            selected = 0
            rows.forEach { $0.removeFromSuperview() }
            rows = matches.enumerated().map { index, item in
                let row = CompletionPickerRow(item: item)
                row.onHover = { [weak self] in self?.select(index) }
                row.onClick = { [weak self] in self?.onPick?(index) }
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                return row
            }
            select(0)
        }
        for row in rows { row.highlight(query) }
        if isHidden && !matches.isEmpty && !Theme.reduceMotion {
            // It fades in over the transcript, rising from the field, rather
            // than popping up. It hides at once, as the keys it takes go
            // back to the field then.
            alphaValue = 0
            isHidden = false
            withEasing(Theme.Duration.quick) { animator().alphaValue = 1 }
            dropIn(distance: -6, duration: Theme.Duration.slide)
        } else {
            isHidden = matches.isEmpty
            alphaValue = 1
        }
        return !matches.isEmpty
    }

    func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }
        select((selected + offset + items.count) % items.count)
        // The keyboard stays in the message field, so VoiceOver is told
        // which item Tab or Return would now insert.
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: items[selected].prefix + items[selected].name,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    /// The place of the item Tab or Return would insert.
    var selectedIndex: Int? { items.indices.contains(selected) ? selected : nil }

    /// The text view's `doCommandBy` while the list shows: Up and Down move
    /// through it, Tab and Return pick the selected item as a click does,
    /// and Escape calls `dismiss`. Returns whether the list took the command.
    func handle(_ selector: Selector, dismiss: () -> Void) -> Bool {
        guard !isHidden else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)):
            if let selectedIndex { onPick?(selectedIndex) }
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
        default:
            return false
        }
        return true
    }

    private func select(_ index: Int) {
        selected = index
        for (i, row) in rows.enumerated() {
            row.isSelected = i == index
            row.setAccessibilitySelected(i == index)
        }
        setAccessibilitySelectedChildren(rows.indices.contains(index) ? [rows[index]] : [])
    }

    // A material view doesn't reliably call `updateLayer`, so the plate's
    // shape and border are set when it joins a window and when the
    // appearance changes, as the suggestions plate does.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        shapePlate()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        shapePlate()
    }

    private func shapePlate() {
        guard let layer else { return }
        layer.cornerRadius = Theme.Radius.plate
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = Theme.hairlineWidth
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.borderColor = Theme.hairline.layerColor
        }
    }
}

/// One item in the picker: a skill's `/name`, argument hint and
/// description, or a tab's `@title`, icon and address.
private final class CompletionPickerRow: NSView {
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    private var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }

    private let name: NSTextField
    private let item: CompletionItem
    /// What the name shows in the accent.
    private var query: String?
    private let hint: NSTextField
    private let badge: NSTextField
    private let hasHint: Bool
    /// Between the name, the hint, the spacer and the badge.
    private static let spacing: CGFloat = 6
    private static let sideInset: CGFloat = 8

    private let icon: NSImageView?
    private static let iconSide: CGFloat = 16

    init(item: CompletionItem) {
        let argumentHint = item.hint ?? ""
        name = NSTextField(labelWithString: item.prefix + item.name)
        self.item = item
        hint = NSTextField(labelWithString: argumentHint)
        badge = NSTextField(labelWithString: item.badge ?? "")
        hasHint = !argumentHint.isEmpty
        icon = item.icon.map { NSImageView(image: $0) }
        super.init(frame: .zero)
        wantsLayer = true
        name.font = .systemFont(ofSize: Theme.FontSize.body, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        // Cut before the split view's holding priority gives way, so a long
        // tab title can't widen the panel, but after the hint.
        name.setContentCompressionResistancePriority(.init(255), for: .horizontal)
        hint.font = .systemFont(ofSize: Theme.FontSize.caption)
        hint.textColor = Theme.tertiaryText
        // Never cut: a hint broken mid-token misleads, so `layout()` hides
        // it when it doesn't fit whole. It gives way to the row's width, and
        // under the split view's holding priority, so a long hint can't
        // widen the panel.
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.isHidden = !hasHint
        badge.font = .systemFont(ofSize: Theme.FontSize.caption, weight: .medium)
        badge.textColor = Theme.secondaryText
        badge.isHidden = item.badge == nil
        let top = NSStackView(views: [name, hint, NSView(), badge])
        if let icon {
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.contentTintColor = Theme.secondaryText
            icon.widthAnchor.constraint(equalToConstant: Self.iconSide).isActive = true
            icon.heightAnchor.constraint(equalToConstant: Self.iconSide).isActive = true
            top.insertArrangedSubview(icon, at: 0)
        }
        top.spacing = Self.spacing
        let description = NSTextField(labelWithString: item.detail.isEmpty ? " " : item.detail)
        description.font = .systemFont(ofSize: Theme.FontSize.caption)
        description.textColor = Theme.secondaryText
        description.lineBreakMode = .byTruncatingTail
        description.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [top, description])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.sideInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.sideInset),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        toolTip = item.detail.isEmpty ? nil : item.detail
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.prefix + item.name)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the first place `query` is in the name in the accent, and the
    /// rest of the name in the text's color.
    func highlight(_ query: String) {
        guard query != self.query else { return }
        self.query = query
        let font = NSFont.systemFont(ofSize: Theme.FontSize.body, weight: .medium)
        let truncates = NSMutableParagraphStyle()
        truncates.lineBreakMode = .byTruncatingTail
        let title = NSMutableAttributedString(string: item.prefix + item.name, attributes: [
            .font: font, .foregroundColor: Theme.text, .paragraphStyle: truncates,
        ])
        let range = (item.name as NSString).range(of: query, options: .caseInsensitive)
        if !query.isEmpty, range.location != NSNotFound {
            title.addAttributes([
                .foregroundColor: Theme.accentColor,
                .font: NSFont.systemFont(ofSize: Theme.FontSize.body, weight: .semibold),
            ], range: NSRange(location: range.location + (item.prefix as NSString).length, length: range.length))
        }
        name.attributedStringValue = title
    }

    /// Shows the hint only when the name, the hint and the badge all fit on
    /// the line. Decided before the stack lays out, so it lays out once.
    override func layout() {
        if hasHint, bounds.width > 0 {
            let available = bounds.width - 2 * Self.sideInset
            // The spacer between the hint and the badge adds one gap even at zero width.
            let badgeWidth = badge.isHidden ? 0 : Self.spacing + ceil(badge.intrinsicContentSize.width)
            let iconWidth = icon == nil ? 0 : Self.iconSide + Self.spacing
            let needed = iconWidth + ceil(name.intrinsicContentSize.width) + Self.spacing
                + ceil(hint.intrinsicContentSize.width) + Self.spacing + badgeWidth
            let hide = needed > available
            if hint.isHidden != hide { hint.isHidden = hide }
        }
        super.layout()
    }

    override var wantsUpdateLayer: Bool { true }

    /// The mouse selects the row it is over, so a pressed row is a selected
    /// one, and deepens its tint rather than turning grey.
    override func updateLayer() {
        layer?.cornerRadius = Theme.Radius.row
        layer?.cornerCurve = .continuous
        let fill: NSColor = isSelected
            ? Theme.accent(isPressed ? Theme.Accent.selectedHover : Theme.Accent.selected)
            : Theme.fill(hovered: false, pressed: isPressed)
        withEasing(Theme.Duration.quick) { layer?.backgroundColor = fill.layerColor }
        layer?.borderWidth = Theme.hairlineWidth
        layer?.borderColor = Theme.selectionOutline(selected: isSelected).layerColor
        // Tertiary text is too faint on the accent's wash.
        hint.textColor = isSelected || Theme.increaseContrast ? Theme.secondaryText : Theme.tertiaryText
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        addHoverArea([.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect])
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseExited(with event: NSEvent) { isPressed = false }
    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// Drives a `SkillPicker` for a text view: opens it while the text is a `/`
/// and the start of a name, moves through it with the arrow keys, and puts
/// `/name ` in the text on Tab, Return or a click. The chat's message field
/// and the scheduled prompt editor both use it.
@MainActor
final class SkillCompletion {
    let picker = CompletionPicker(label: "Skills")
    /// What `/` can call, read when the picker opens.
    var skills: () -> [AgentSkill]
    private weak var textView: NSTextView?
    /// The skills offered while the picker is open.
    private var offered: [AgentSkill]?
    /// The skills listed, in the picker's order.
    private var listed: [AgentSkill] = []

    init(textView: NSTextView, skills: @escaping () -> [AgentSkill]) {
        self.textView = textView
        self.skills = skills
        picker.isHidden = true
        picker.onPick = { [weak self] index in
            guard let self, self.listed.indices.contains(index) else { return }
            self.complete(self.listed[index])
        }
    }

    var isShown: Bool { !picker.isHidden }

    /// Call when the text changes.
    func update() {
        guard let text = textView?.string, text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return hide() }
        let skills = offered ?? self.skills()
        offered = skills
        let query = String(text.dropFirst())
        listed = Array(Self.matches(skills, query).prefix(CompletionPicker.maxRows))
        picker.show(listed.map {
            CompletionItem(prefix: "/", name: $0.name, hint: $0.argumentHint, badge: $0.origin == .library ? "Tiller" : nil, detail: $0.description)
        }, highlighting: query)
    }

    /// Skills whose name starts with `query` come first, then those that
    /// have it elsewhere in the name.
    static func matches(_ skills: [AgentSkill], _ query: String) -> [AgentSkill] {
        let query = query.lowercased()
        let starts = skills.filter { $0.name.lowercased().hasPrefix(query) }
        guard !query.isEmpty else { return starts }
        return starts + skills.filter { !$0.name.lowercased().hasPrefix(query) && $0.name.lowercased().contains(query) }
    }

    func hide() {
        picker.isHidden = true
        offered = nil
    }

    /// The text view's `doCommandBy` while the picker is open. Returns
    /// whether the picker took the command.
    func handle(_ selector: Selector) -> Bool {
        picker.handle(selector) { hide() }
    }

    /// Puts `/name ` in the field, keeping it undoable.
    func complete(_ skill: AgentSkill) {
        guard let textView else { return }
        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        let replacement = "/" + skill.name + " "
        if textView.shouldChangeText(in: range, replacementString: replacement) {
            textView.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
        }
        textView.setSelectedRange(NSRange(location: (replacement as NSString).length, length: 0))
        hide()
        textView.window?.makeFirstResponder(textView)
    }

    /// The skill a message starting with `/name` calls, among `skills`.
    static func skill(calledBy text: String, in skills: [AgentSkill]) -> AgentSkill? {
        guard text.hasPrefix("/") else { return nil }
        let name = text.dropFirst().prefix { !$0.isWhitespace }
        return skills.first { $0.name == name }
    }
}
