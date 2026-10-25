import AppKit
import Quartz

@MainActor
protocol AgentPanelDelegate: AnyObject {
    /// The selected tab, described for the agent at the start of each message.
    func agentPanelContext(_ panel: AgentPanelView) -> String
    /// The window's open tabs, in order, which `@` in a message offers.
    func agentPanelTabs(_ panel: AgentPanelView) -> [AgentTabMention]
}

/// The side panel: pick an agent and chat with it, in up to a few tabs, each
/// with its own agent. A bar above the message field switches tabs, opens
/// new ones and past chats. The open tabs come back at the next launch.
/// Like the tab sidebar it has no background of its own, so it reads as one
/// surface with the toolbar.
final class AgentPanelView: NSView {
    weak var delegate: AgentPanelDelegate?
    /// Called when any chat starts or stops working.
    var onBusyChange: ((Bool) -> Void)?
    /// Whether any chat's agent is working.
    private(set) var isBusy = false {
        didSet { if isBusy != oldValue { onBusyChange?(isBusy) } }
    }

    /// The message being written in the selected tab.
    var input: NSView { active.input }

    private let agentPicker = NSPopUpButton()
    private let status = StatusPill()
    private let chatArea = NSView()
    private let tabBar = AgentTabBar()
    private var chats: [AgentChatView] = []
    /// Scheduled runs and chats sent from the `tiller` CLI going on in the
    /// background. They take no tab until opened, and leave once their turn
    /// ends.
    private var scheduledChats: [AgentChatView] = []
    private var activeIndex = 0
    /// The id of the chat the panel showed last, so the one taking its
    /// place, by a switch of tab, a chat opened from history or a tab
    /// closed, fades in. An id, as a replaced chat is gone by then.
    private var shownChatID: String?
    private var active: AgentChatView { chats[activeIndex] }
    private var historyPopover: NSPopover?

    private let profile: ProfileContext

    /// The panel of `profile`'s window, with its chats and agents.
    init(profile: ProfileContext, frame: NSRect) {
        self.profile = profile
        super.init(frame: frame)
        build()
        restoreTabs()
        NotificationCenter.default.addObserver(
            self, selector: #selector(currentAgentChanged(_:)), name: .agentKindDidChange, object: profile.providers
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(tabLimitChanged(_:)), name: .agentTabsDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(providersChanged(_:)), name: .agentProvidersDidChange, object: profile.providers
        )
        // A new chat follows Settings' options, and the button names the models.
        for name in [Notification.Name.agentModelOptionsDidChange, .agentModelsDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(tabLimitChanged(_:)), name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The panel is on screen: have the CLIs looked up now, so the first
    /// message doesn't wait on a login shell and the agent picker knows
    /// which are missing.
    override func viewDidUnhide() {
        super.viewDidUnhide()
        AgentEnvironment.refreshAvailability()
        AgentModelCatalog.refreshAll(profile: profile)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return }
        AgentEnvironment.refreshAvailability()
        AgentModelCatalog.refreshAll(profile: profile)
    }

    /// Ends every tab's agent and saves the chats. Called when the window closes.
    func shutDown() {
        saveTabs()
        (chats + scheduledChats).forEach { $0.shutDown() }
        profile.agentHistory.flush()
        profile.agentHistory.waitForWrites()
    }

    var hasKeyboardFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if let editor = responder as? NSText, let owner = editor.delegate as? NSView {
            return owner.isDescendant(of: self)
        }
        return (responder as? NSView)?.isDescendant(of: self) ?? false
    }

    // MARK: Layout

    private func build() {
        fillAgentPicker()
        agentPicker.isBordered = false
        agentPicker.font = .systemFont(ofSize: Theme.FontSize.body, weight: .semibold)
        agentPicker.toolTip = "Agent for this chat"
        agentPicker.target = self
        agentPicker.action = #selector(agentChanged(_:))
        AgentMenuAvailability.watch(agentPicker, providers: profile.providers)

        tabBar.onSelect = { [weak self] index in self?.select(index, focus: true) }
        tabBar.onClose = { [weak self] index in self?.closeTab(index) }
        tabBar.onNewTab = { [weak self] in self?.newTab() }
        tabBar.onNewChat = { [weak self] in self?.newChat() }
        tabBar.onHistory = { [weak self] button in self?.showHistory(from: button) }

        for view in [agentPicker, status, chatArea] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            agentPicker.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            agentPicker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: agentPicker.trailingAnchor, constant: 4),
            status.centerYAnchor.constraint(equalTo: agentPicker.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

            chatArea.topAnchor.constraint(equalTo: agentPicker.bottomAnchor, constant: 8),
            chatArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            chatArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            chatArea.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: Tabs

    /// Last time's tabs, up to the limit. A chat since deleted opens empty.
    private func restoreTabs() {
        let store = profile.agentHistory
        for id in store.openTabs.prefix(Settings.agentTabs) {
            add(AgentChatView(profile: profile, conversation: id.isEmpty ? nil : store.conversation(id)))
        }
        if chats.isEmpty { add(AgentChatView(profile: profile)) }
        select(min(max(store.selectedTab, 0), chats.count - 1), focus: false)
    }

    private func add(_ chat: AgentChatView, at index: Int? = nil) {
        attach(chat)
        chats.insert(chat, at: index ?? chats.count)
    }

    /// Puts the chat in the panel, hidden, without giving it a tab.
    private func attach(_ chat: AgentChatView) {
        chat.context = { [weak self] in
            guard let self else { return "" }
            return self.delegate?.agentPanelContext(self) ?? ""
        }
        chat.openTabs = { [weak self] in
            guard let self else { return [] }
            return self.delegate?.agentPanelTabs(self) ?? []
        }
        chat.onChange = { [weak self, weak chat] in
            guard let self, let chat else { return }
            if self.chats.contains(chat) {
                self.refresh()
                self.saveTabs()
            } else if self.scheduledChats.contains(chat) {
                self.refresh()
            }
        }
        chat.onTools = { [weak self] button in self?.showTools(from: button) }
        chat.onModel = { [weak self] button in self?.showModelOptions(from: button) }
        chat.onEffort = { [weak self] button in self?.showModelOptions(from: button, effortOnly: true) }
        chat.isHidden = true
        chat.translatesAutoresizingMaskIntoConstraints = false
        chatArea.addSubview(chat)
        NSLayoutConstraint.activate([
            chat.topAnchor.constraint(equalTo: chatArea.topAnchor),
            chat.bottomAnchor.constraint(equalTo: chatArea.bottomAnchor),
            chat.leadingAnchor.constraint(equalTo: chatArea.leadingAnchor),
            chat.trailingAnchor.constraint(equalTo: chatArea.trailingAnchor),
        ])
    }

    /// Shows the tab at `index`, with the tab bar moved into it.
    private func select(_ index: Int, focus: Bool) {
        activeIndex = index
        for (i, chat) in chats.enumerated() { chat.isHidden = i != index }
        let chat = active
        if window != nil, shownChatID != nil, shownChatID != chat.id { chat.playSwitchIn() }
        shownChatID = chat.id
        if tabBar.superview !== chat.tabBarHost {
            tabBar.removeFromSuperview()
            tabBar.translatesAutoresizingMaskIntoConstraints = false
            chat.tabBarHost.addSubview(tabBar)
            NSLayoutConstraint.activate([
                tabBar.topAnchor.constraint(equalTo: chat.tabBarHost.topAnchor),
                tabBar.bottomAnchor.constraint(equalTo: chat.tabBarHost.bottomAnchor),
                tabBar.leadingAnchor.constraint(equalTo: chat.tabBarHost.leadingAnchor),
                tabBar.trailingAnchor.constraint(equalTo: chat.tabBarHost.trailingAnchor),
            ])
        }
        refresh()
        saveTabs()
        if focus { window?.makeFirstResponder(chat.input) }
    }

    private func newTab() {
        guard chats.count < Settings.agentTabs else { return NSSound.beep() }
        add(AgentChatView(profile: profile))
        select(chats.count - 1, focus: true)
    }

    /// Starts over in the selected tab. The chat it had stays in history.
    private func newChat() {
        if active.isEmpty {
            window?.makeFirstResponder(input)
        } else {
            replace(activeIndex, with: AgentChatView(profile: profile))
        }
    }

    private func replace(_ index: Int, with chat: AgentChatView) {
        let old = chats.remove(at: index)
        old.shutDown()
        old.removeFromSuperview()
        add(chat, at: index)
        select(index, focus: true)
    }

    /// Closing the last tab leaves a new chat.
    private func closeTab(_ index: Int) {
        guard chats.indices.contains(index) else { return }
        if chats.count == 1 { return newChat() }
        let chat = chats.remove(at: index)
        chat.shutDown()
        chat.removeFromSuperview()
        let selected = index < activeIndex ? activeIndex - 1 : min(activeIndex, chats.count - 1)
        select(selected, focus: hasKeyboardFocus || index == activeIndex)
    }

    private func saveTabs() {
        profile.agentHistory.setOpenTabs(chats.map { $0.isEmpty ? "" : $0.id }, selected: activeIndex)
    }

    /// The header and tab bar show the selected chat.
    private func refresh() {
        let chat = active
        isBusy = (chats + scheduledChats).contains { $0.isBusy }
        if let stale = agentPicker.lastItem, stale.representedObject == nil, !stale.isSeparatorItem {
            agentPicker.menu?.removeItem(stale)
        }
        if let index = agentPicker.itemArray.firstIndex(where: { $0.representedObject as? String == chat.choice.rawValue }) {
            agentPicker.selectItem(at: index)
        } else {
            // A removed provider's chat names it, without offering it.
            agentPicker.addItem(withTitle: profile.providers.displayName(chat.choice))
            agentPicker.lastItem?.image = chat.choice.logo(size: 16)
            agentPicker.lastItem?.isHidden = true
            agentPicker.select(agentPicker.lastItem)
        }
        status.show(chat.statusText, busy: chat.statusBusy)
        tabBar.update(
            tabs: chats.map { (title: $0.title, busy: $0.isBusy) },
            selected: activeIndex,
            canAddTab: chats.count < Settings.agentTabs
        )
        chat.showOptions()
    }

    // MARK: Model

    /// The selected chat's model, effort, context and fast mode. Locked while
    /// a turn runs, since a change restarts the agent.
    private func showModelOptions(from button: NSView, effortOnly: Bool = false) {
        let chat = active
        AgentModelMenu.popUp(
            from: button, above: true, kind: chat.choice, profile: profile, options: chat.modelOptions, locked: chat.isBusy,
            note: chat.isBusy ? "Stop the agent to change the model." : "Settings sets them for new chats.", effortOnly: effortOnly
        ) { [weak chat] options in
            chat?.setModelOptions(options)
        }
    }

    // MARK: Tools

    /// The selected chat's built-in tools, each a checkmark item. Codex can
    /// always read and run read-only commands, so writing and running
    /// commands widen its sandbox, and Antigravity CLI always has them all.
    /// Locked while a turn runs, since a change restarts the agent.
    private func showTools(from button: NSView) {
        let chat = active
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Also allow in this chat"))
        for tool in AgentTool.allCases {
            let item = NSMenuItem(title: tool.displayName, action: #selector(toggleTool(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tool.rawValue
            let alwaysOn = chat.kind.alwaysAllows(tool)
            item.state = alwaysOn || chat.tools.contains(tool) ? .on : .off
            item.isEnabled = !alwaysOn && !chat.isBusy
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let note = NSMenuItem(
            title: chat.isBusy ? "Stop the agent to change tools." : "They run without asking. Settings sets them for new chats.",
            action: nil, keyEquivalent: ""
        )
        note.isEnabled = false
        menu.addItem(note)
        // Above the button, which sits at the bottom of the message field.
        menu.popUp(above: button)
    }

    @objc private func toggleTool(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tool = AgentTool(rawValue: raw) else { return }
        let chat = active
        var tools = Set(chat.tools)
        if tools.contains(tool) { tools.remove(tool) } else { tools.insert(tool) }
        chat.setTools(AgentTool.allCases.filter(tools.contains))
    }

    @objc private func tabLimitChanged(_ notification: Notification) {
        refresh()
    }

    // MARK: History

    private func showHistory(from button: NSView) {
        if let historyPopover, historyPopover.isShown { return historyPopover.close() }
        let controller = AgentHistoryController(items: historyItems(), current: active.id)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        controller.onOpen = { [weak self, weak popover] id in
            popover?.close()
            self?.open(id)
        }
        controller.onDelete = { [weak self, weak controller] id in
            guard let self else { return }
            self.delete(id)
            controller?.reload(self.historyItems())
        }
        historyPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    private func historyItems() -> [AgentHistoryController.Item] {
        profile.agentHistory.conversations.map { conversation in
            .init(
                conversation: conversation, tab: chats.firstIndex { $0.id == conversation.id },
                agentName: profile.providers.displayName(conversation.choice)
            )
        }
    }

    /// Switches to the chat if a tab has it, or opens it in the selected tab.
    func open(_ id: String) {
        open(id, newTabIfRoom: false)
    }

    /// Shows a scheduled run's chat: in a new tab while there is room, else
    /// in the selected tab.
    func openScheduled(_ id: String) {
        open(id, newTabIfRoom: true)
    }

    /// A run still going keeps going in its new tab.
    private func open(_ id: String, newTabIfRoom: Bool) {
        if let index = chats.firstIndex(where: { $0.id == id }) {
            return select(index, focus: true)
        }
        let chat: AgentChatView
        if let index = scheduledChats.firstIndex(where: { $0.id == id }) {
            chat = scheduledChats.remove(at: index)
            chat.removeFromSuperview()
        } else {
            guard let conversation = profile.agentHistory.conversation(id) else { return }
            chat = AgentChatView(profile: profile, conversation: conversation)
        }
        if newTabIfRoom, chats.count < Settings.agentTabs {
            add(chat)
            select(chats.count - 1, focus: true)
        } else {
            replace(activeIndex, with: chat)
        }
        chat.scrollToBottom()
    }

    /// A tab showing the chat gets a new one instead.
    private func delete(_ id: String) {
        if let index = scheduledChats.firstIndex(where: { $0.id == id }) {
            let chat = scheduledChats.remove(at: index)
            chat.shutDown()
            chat.removeFromSuperview()
            refresh()
        }
        if let index = chats.firstIndex(where: { $0.id == id }) {
            let old = chats.remove(at: index)
            old.shutDown()
            old.removeFromSuperview()
            add(AgentChatView(profile: profile), at: index)
            select(activeIndex, focus: false)
        }
        profile.agentHistory.delete(id)
    }

    // MARK: Agent

    /// Picking another agent starts a new chat with it, unless the selected
    /// tab has no messages yet.
    @objc private func agentChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let kind = AgentChoice(rawValue: raw),
            kind != active.choice || kind != profile.providers.current
        else { return }
        let startOver = !active.isEmpty && kind != active.choice
        profile.providers.current = kind
        if startOver { newChat() } else { refresh() }
    }

    /// The CLIs, then the providers added in Settings.
    private func fillAgentPicker() {
        agentPicker.removeAllItems()
        for (index, choice) in profile.providers.all.enumerated() {
            if index == AgentKind.allCases.count { agentPicker.menu?.addItem(.separator()) }
            agentPicker.addItem(withTitle: profile.providers.displayName(choice))
            agentPicker.lastItem?.representedObject = choice.rawValue
            agentPicker.lastItem?.image = choice.logo(size: 16)
        }
    }

    /// A provider was added, renamed or removed in Settings.
    @objc private func providersChanged(_ notification: Notification) {
        fillAgentPicker()
        refresh()
        (chats + scheduledChats).forEach { $0.providersChanged() }
    }

    /// Settings changed the agent for new chats, which an empty tab shows.
    @objc private func currentAgentChanged(_ notification: Notification) {
        refresh()
    }

    // MARK: Sending

    #if DEBUG
    func stopForTesting() { active.stopForTesting() }

    func pasteAndSendForTesting(_ text: String) { active.pasteAndSendForTesting(text) }

    /// One of the tab bar's buttons, by name, for `ui.agentAction`.
    func performForTesting(_ action: String) {
        switch action {
        case "newChat": newChat()
        case "newTab": newTab()
        case "closeTab": closeTab(activeIndex)
        case "history": tabBar.historyForTesting()
        case "tools": active.toolsForTesting()
        case "model": active.modelForTesting()
        case "effort": active.effortForTesting()
        case "focus": window?.makeFirstResponder(input)
        case "enter": active.submitForTesting(direct: false)
        case "ctrlEnter": active.submitForTesting(direct: true)
        default:
            if action.hasPrefix("tab"), let index = Int(action.dropFirst(3)), chats.indices.contains(index - 1) {
                select(index - 1, focus: true)
            }
        }
    }

    /// Puts `text` in the selected chat's message field, as if typed.
    func setTextForTesting(_ text: String) {
        window?.makeFirstResponder(input)
        active.setTextForTesting(text)
    }
    #endif

    func send(_ text: String) {
        active.send(text)
    }

    // MARK: Scheduled runs

    func isChatBusy(_ id: String) -> Bool {
        (chats + scheduledChats).contains { $0.id == id && $0.isBusy }
    }

    /// Sends a scheduled prompt in a new chat in the background, taking no
    /// tab. Once its turn ends the chat leaves, unless opened in a tab by
    /// then; it stays in history. `completion` gets the chat's id and how
    /// its turn ended.
    func runScheduled(_ schedule: ScheduledPrompt, completion: @escaping (String, AgentRunOutcome) -> Void) -> String {
        let chat = AgentChatView(profile: profile, kind: schedule.choice, tools: schedule.tools, modelOptions: schedule.modelOptions)
        attach(chat)
        scheduledChats.append(chat)
        let id = chat.id
        chat.runScheduled(schedule) { [weak self, weak chat] outcome in
            completion(id, outcome)
            guard let self, let chat, let index = self.scheduledChats.firstIndex(of: chat) else { return }
            self.scheduledChats.remove(at: index)
            chat.shutDown()
            chat.removeFromSuperview()
            self.refresh()
        }
        refresh()
        return id
    }

    // MARK: Command line

    /// Sends `text` for `tiller agent send`: in the chat `chat` names, which
    /// a tab may show, or else in a new chat with `kind`, `tools` and
    /// `options`, in the background like a scheduled run, taking no tab.
    /// `completion` gets how the turn ended. Returns the chat's id.
    func runFromCommandLine(
        _ text: String, chat id: String?, kind: AgentChoice?, tools: [AgentTool]?, options: AgentModelOptions?,
        completion: @escaping (AgentRunOutcome) -> Void
    ) throws -> String {
        let chat: AgentChatView
        var background = false
        if let id {
            if let open = (chats + scheduledChats).first(where: { $0.id == id }) {
                guard !open.isBusy else { throw ControlError("that chat is working; wait for it, or stop it with `tiller agent stop`") }
                chat = open
            } else {
                guard let conversation = profile.agentHistory.conversation(id) else {
                    throw ControlError("no chat with id \(id). Run `tiller agent chats` for the list.")
                }
                chat = AgentChatView(profile: profile, conversation: conversation)
                background = true
            }
        } else {
            if let kind, !profile.providers.exists(kind) { throw ControlError("\(kind.rawValue) isn't an agent here") }
            chat = AgentChatView(profile: profile, kind: kind, tools: tools, modelOptions: options)
            background = true
        }
        if background {
            attach(chat)
            scheduledChats.append(chat)
        }
        chat.runPrompt(text) { [weak self, weak chat] outcome in
            completion(outcome)
            guard background, let self, let chat, let index = self.scheduledChats.firstIndex(of: chat) else { return }
            self.scheduledChats.remove(at: index)
            chat.shutDown()
            chat.removeFromSuperview()
            self.refresh()
        }
        refresh()
        return chat.id
    }

    /// Stops the chat's turn, in a tab or in the background. False when no
    /// such chat is working.
    func stopChat(_ id: String) -> Bool {
        guard let chat = (chats + scheduledChats).first(where: { $0.id == id }), chat.isBusy else { return false }
        chat.stop()
        return true
    }

    /// Where the chat is open: the panel tab's number from 1, 0 for the
    /// background, nil when it isn't.
    func place(of id: String) -> Int? {
        if let index = chats.firstIndex(where: { $0.id == id }) { return index + 1 }
        return scheduledChats.contains { $0.id == id } ? 0 : nil
    }

    /// Removes the chat from history, as its menu's Delete does.
    func deleteChat(_ id: String) {
        delete(id)
    }
}


// MARK: Header

/// Where the agent is at: a dot, pulsing while it works, and a short label.
private final class StatusPill: NSView {
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private var busy = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Theme.busyDot / 2
        label.font = .systemFont(ofSize: Theme.FontSize.caption)
        label.textColor = Theme.secondaryText
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [dot, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: Theme.busyDot),
            dot.heightAnchor.constraint(equalToConstant: Theme.busyDot),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The dot's color is the only other sign of the state, so VoiceOver
        // reads the pill as one element whose label says it in words.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        label.setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, busy: Bool) {
        label.stringValue = text
        setShown(!text.isEmpty, fadesOut: true, duration: Theme.Duration.standard)
        toolTip = text
        setAccessibilityLabel("Agent status: \(text)")
        guard busy != self.busy else { return }
        self.busy = busy
        needsDisplay = true
        dot.layer?.removeAnimation(forKey: "pulse")
        if busy, !Theme.reduceMotion {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.25
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.layer?.add(pulse, forKey: "pulse")
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        dot.layer?.backgroundColor = (busy ? Theme.accentColor : Theme.success).layerColor
    }
}

// MARK: Empty state

/// What a new chat shows: what the agent can do, and a few things to ask.
final class AgentEmptyState: NSView {
    var onSuggestion: ((String) -> Void)?
    private var kind: AgentChoice?

    /// Names the agent, `name` being its name or its provider's.
    func show(_ kind: AgentChoice, name: String) {
        guard kind != self.kind || title.stringValue != "Ask \(name)" else { return }
        let changed = kind != self.kind
        self.kind = kind
        title.stringValue = "Ask \(name)"
        title.toolTip = title.stringValue
        if changed { badge.logo = kind.logo(size: 28) }
    }

    private let badge = SymbolBadge(symbol: "sparkles")
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "It can read the page, click, type and open tabs for you. Type / for skills, @ for tabs.")
    private static let subtitleWidth: CGFloat = 240

    private static let suggestions: [(symbol: String, text: String)] = [
        ("text.alignleft", "Summarize this page"),
        ("list.bullet", "List the key points"),
        ("magnifyingglass", "Find related pages"),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: Theme.FontSize.title, weight: .semibold)
        title.alignment = .center
        // A long agent or provider name ends in an ellipsis in a narrow panel
        // rather than being cut mid-letter.
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitle.font = .systemFont(ofSize: Theme.FontSize.secondary)
        subtitle.textColor = Theme.secondaryText
        subtitle.alignment = .center
        subtitle.preferredMaxLayoutWidth = Self.subtitleWidth

        let buttons = NSStackView()
        buttons.orientation = .vertical
        buttons.alignment = .centerX
        buttons.spacing = 6
        for (symbol, text) in Self.suggestions {
            let button = SuggestionButton(symbol: symbol, title: text) { [weak self] in self?.onSuggestion?(text) }
            buttons.addArrangedSubview(button)
            // One width for all, so the column reads as a list.
            button.widthAnchor.constraint(equalToConstant: 200).isActive = true
        }

        for view in [badge, title, subtitle, buttons] { stack.addArrangedSubview(view) }
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(12, after: badge)
        stack.setCustomSpacing(18, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private let stack = NSStackView()

    /// Brings the badge, the words and the suggestions in one after another,
    /// a few hundredths of a second apart, as a new chat opens.
    func appear() {
        for (index, view) in stack.arrangedSubviews.enumerated() {
            view.fadeUp(delay: Double(index) * 0.05)
        }
    }

    /// The subtitle wraps to the space there is, when the panel is narrower
    /// than its usual width. Set before the stack lays out, so it lays out once.
    override func layout() {
        let width = min(Self.subtitleWidth, bounds.width)
        if width > 0, subtitle.preferredMaxLayoutWidth != width { subtitle.preferredMaxLayoutWidth = width }
        super.layout()
    }
}

/// An SF Symbol on a soft accent-colored circle, or a logo on a plain one.
private final class SymbolBadge: NSView {
    /// Shown instead of the symbol, in its own colors.
    var logo: NSImage? {
        didSet {
            image.image = logo ?? symbol
            image.contentTintColor = logo == nil ? Theme.accentColor : nil
            needsDisplay = true
        }
    }

    private let symbol: NSImage
    private let image: NSImageView
    private static let side: CGFloat = 48

    init(symbol: String) {
        self.symbol = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 20, weight: .medium))!
        image = NSImageView(image: self.symbol)
        super.init(frame: .zero)
        wantsLayer = true
        image.contentTintColor = Theme.accentColor
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Round, at any size.
        layer?.cornerRadius = Self.side / 2
        let color = logo == nil ? Theme.accent(Theme.Accent.soft) : Theme.fill(Theme.Fill.rest)
        layer?.backgroundColor = color.layerColor
    }
}

/// A rounded, lightly filled button with an icon and a prompt, which
/// highlights on hover.
private final class SuggestionButton: NSView {
    private let action: () -> Void
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }

    init(symbol: String, title: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))!)
        icon.contentTintColor = Theme.secondaryText
        // The symbols differ in width, so each sits centered in a slot of one
        // width and the prompts start at one x.
        icon.imageAlignment = .alignCenter
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: Theme.FontSize.secondary)
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = Theme.Radius.plate
        layer?.cornerCurve = .continuous
        let alpha = isPressed ? Theme.Fill.pressed : isHovered ? Theme.Fill.hover : Theme.Fill.rest
        withEasing(Theme.Duration.quick) { layer?.backgroundColor = Theme.fill(alpha).layerColor }
        layer?.borderWidth = Theme.hairlineWidth
        layer?.borderColor = Theme.hairline.layerColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        addHoverArea([.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect])
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}

// MARK: Composer

/// The message field: a rounded card with the text across its full width on
/// top, easing taller with what is typed up to a few lines, and a row of
/// controls along its bottom: the add button, the chat's model, effort and
/// tools, then how full the context window is, dictation and the send/stop
/// button. Attached images show
/// above the text. Images pasted or dropped on it go to `onImages`, and a
/// hint says so while they are dragged over it. A `/name` at the start that
/// calls a skill reads as a token, and text taller than the field fades out
/// at the edge it scrolls past.
final class Composer: NSView {
    let textView = PlaceholderTextView()
    let sendButton = SendButton()
    /// Opens a menu of things to add: images, or a message sent before.
    let addButton = Theme.iconButton("plus", label: "Add")
    /// Names the chat's model and opens its options.
    let modelButton = ComposerChip()
    /// Names the chat's thinking effort and opens just those. Hidden for an
    /// agent without efforts.
    let effortButton = ComposerChip()
    /// Tinted while any built-in tool is on, and opens their menu.
    let toolsButton = Theme.iconButton("wrench.and.screwdriver", label: "Tools", size: Theme.Symbol.row)
    /// Starts macOS dictation into the field, beside the send button.
    let dictateButton = Theme.iconButton("mic", label: "Dictate", size: Theme.Symbol.bar)
    /// How much of the model's context window the chat takes, before the
    /// dictation button once the agent says.
    let contextMeter = ContextMeter()
    var onImages: (([NSImage]) -> Void)?
    var onOpenImage: ((Int) -> Void)?
    /// Whether a skill of that name can be called, which makes `/name` at
    /// the start of the text a token.
    var isSkill: ((String) -> Bool)?
    private let undo = UndoManager()
    private let scrollView = FadingScrollView()
    /// The name after the last `/` looked up, and whether it was a skill,
    /// so typing past it doesn't look it up again.
    private var lookedUp: (name: Substring, isSkill: Bool)?
    private let thumbnails = ThumbnailGrid(side: 48, alignment: .leading)
    private let controls = NSStackView()
    private let dropHint = NSStackView()
    private var textHeight: NSLayoutConstraint!
    private var textBelowTop: NSLayoutConstraint!
    private var textBelowThumbnails: NSLayoutConstraint!
    /// Whether the field holds nothing but whitespace, worked out once per
    /// change rather than each time the chat asks.
    private var isBlank = true
    /// Whether the placeholder was showing as of the last change.
    private var hadNoText = true
    private var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            needsDisplay = true
            // The hint takes the card's middle while what is in it steps back.
            dropHint.setShown(isDropTarget, fadesOut: true, duration: Theme.Duration.standard)
            if isDropTarget { dropHint.dropIn(distance: 4, duration: Theme.Duration.slide) }
            for view in [scrollView, thumbnails, controls, contextMeter, dictateButton, sendButton] as [NSView] {
                view.fadeAlpha(to: isDropTarget ? 0.15 : 1, duration: Theme.Duration.standard)
            }
        }
    }
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    var attachments: [AgentAttachment] = [] {
        didSet {
            thumbnails.images = attachments.map(\.image)
            thumbnails.setShown(!attachments.isEmpty, duration: Theme.Duration.standard)
            textBelowTop.isActive = attachments.isEmpty
            textBelowThumbnails.isActive = !attachments.isEmpty
            updateSendButton()
        }
    }

    private static let font = NSFont.systemFont(ofSize: Theme.FontSize.body)
    private static let maxLines: CGFloat = 10
    /// The card's inner margins: the text's from the edges, the controls'
    /// from the corners, whose radius is the send button's plus that margin
    /// so the two curves run alongside.
    private static let textInset: CGFloat = 14
    private static let controlInset: CGFloat = 8
    /// Room inside the text view on each side for the plate behind a token,
    /// taken back from the card's margin so the text stays where it was.
    private static let tokenRoom: CGFloat = 3
    static let radius = SendButton.side / 2 + controlInset

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            // Typing undo steps refer to the old text.
            undo.removeAllActions()
            textChanged()
        }
    }

    override var undoManager: UndoManager? { undo }

    var placeholder = "" {
        didSet { updatePlaceholder() }
    }

    /// Drawn instead of `placeholder` when that doesn't fit the field.
    var shortPlaceholder = "" {
        didSet { updatePlaceholder() }
    }

    /// While a turn runs, the hint says that what is written now waits.
    var isBusy = false {
        didSet {
            guard isBusy != oldValue else { return }
            updateSendButton()
            updatePlaceholder()
        }
    }

    private func updatePlaceholder() {
        let hint = isBusy ? "Queue a follow-up…" : placeholder
        guard hint != textView.placeholder || (isBusy ? "Follow up…" : shortPlaceholder) != textView.shortPlaceholder else { return }
        // A showing hint fades into the next rather than swapping.
        if textView.string.isEmpty { textView.crossfade() }
        textView.placeholder = hint
        textView.shortPlaceholder = isBusy ? "Follow up…" : shortPlaceholder
    }

    /// Messages wait to be sent, which an empty field can send.
    var hasQueued = false {
        didSet { if hasQueued != oldValue { updateSendButton() } }
    }

    /// Whether nothing is written or attached.
    var isEmpty: Bool { isBlank && attachments.isEmpty }

    /// Shows the chat's model, `summary` in full in the tooltip, its effort
    /// when the agent has efforts (`hasEfforts`), and its tools. Choices
    /// other than the CLI's own read stronger.
    func showOptions(
        model title: String, summary: String, isDefault: Bool, effort: String?, hasEfforts: Bool, tools: [AgentTool]
    ) {
        modelButton.title = title
        modelButton.isEmphasized = !isDefault
        modelButton.toolTip = "Model: " + summary
        modelButton.setAccessibilityValue(summary)
        // A model with efforts brings the button in with a fade.
        effortButton.setShown(hasEfforts, duration: Theme.Duration.standard)
        effortButton.title = effort.map(AgentModelOptions.effortTitle) ?? "Effort"
        effortButton.isEmphasized = effort != nil
        effortButton.toolTip = "Thinking effort: " + (effort.map(AgentModelOptions.effortTitle) ?? "the CLI's default")
        effortButton.setAccessibilityValue(effort ?? "default")
        let toolsTint = tools.isEmpty ? Theme.secondaryText : Theme.accentColor
        if toolsButton.contentTintColor != toolsTint {
            toolsButton.crossfade()
            toolsButton.contentTintColor = toolsTint
        }
        toolsButton.toolTip = tools.isEmpty
            ? "Tools: browser only"
            : "Tools: browser, " + tools.map { $0.displayName.lowercased() }.joined(separator: ", ")
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        textView.font = Self.font
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: Self.tokenRoom, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.onFocusChange = { [weak self] in self?.needsDisplay = true }
        textView.onPasteboardImages = { [weak self] pasteboard in self?.takeImages(from: pasteboard) ?? false }
        textView.imageDropTarget = self
        // The placeholder is drawn by hand, so VoiceOver gets it, and a
        // name for the field, from here.
        textView.setAccessibilityLabel("Message")
        registerForDraggedTypes(AgentAttachment.pasteboardTypes)

        thumbnails.isHidden = true
        thumbnails.onOpen = { [weak self] index in self?.onOpenImage?(index) }
        thumbnails.onRemove = { [weak self] index in
            guard let self else { return }
            let removed = self.attachments.remove(at: index)
            try? FileManager.default.removeItem(at: removed.url)
        }

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(textScrolled(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )

        updateSendButton()

        effortButton.setAccessibilityLabel("Thinking effort")
        effortButton.isHidden = true
        // The model's name truncates before the row clips any button, and
        // the effort after it.
        modelButton.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        effortButton.setContentCompressionResistancePriority(.defaultLow - 2, for: .horizontal)
        controls.setViews([addButton, modelButton, effortButton, toolsButton], in: .leading)
        controls.spacing = 2
        controls.setClippingResistancePriority(.defaultLow, for: .horizontal)

        let dropIcon = NSImageView(image: Theme.symbol("photo.badge.plus", size: 13, weight: .medium) ?? NSImage())
        dropIcon.contentTintColor = Theme.accentColor
        let dropLabel = NSTextField(labelWithString: "Drop images to attach")
        dropLabel.font = .systemFont(ofSize: Theme.FontSize.secondary, weight: .medium)
        dropLabel.textColor = Theme.accentColor
        dropHint.setViews([dropIcon, dropLabel], in: .center)
        dropHint.spacing = 6
        dropHint.isHidden = true

        dictateButton.contentTintColor = Theme.secondaryText
        (dictateButton as? HoverButton)?.plateRadius = Theme.ButtonSize.bar / 2
        dictateButton.target = self
        dictateButton.action = #selector(dictate(_:))

        for view in [thumbnails, scrollView, controls, contextMeter, dictateButton, sendButton, dropHint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textHeight = scrollView.heightAnchor.constraint(equalToConstant: Self.lineHeight)
        textBelowTop = scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 13)
        textBelowThumbnails = scrollView.topAnchor.constraint(equalTo: thumbnails.bottomAnchor, constant: 10)
        NSLayoutConstraint.activate([
            thumbnails.topAnchor.constraint(equalTo: topAnchor, constant: Self.textInset),
            thumbnails.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textInset),
            thumbnails.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.textInset),
            textBelowTop,
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textInset - Self.tokenRoom),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Self.textInset - Self.tokenRoom)),
            textHeight,

            sendButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.controlInset),
            sendButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.controlInset),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.controlInset),
            controls.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            dictateButton.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -4),
            dictateButton.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            contextMeter.trailingAnchor.constraint(equalTo: dictateButton.leadingAnchor, constant: -2),
            contextMeter.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: contextMeter.leadingAnchor, constant: -8),

            dropHint.centerXAnchor.constraint(equalTo: centerXAnchor),
            dropHint.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let lineHeight = NSLayoutManager().defaultLineHeight(for: font)

    /// Whether the insertion point is on the text's first line, as laid
    /// out, where Up goes to an older message.
    var caretOnFirstLine: Bool {
        let string = textView.string as NSString
        let location = textView.selectedRange().location
        guard location > 0, let layoutManager = textView.layoutManager else { return true }
        // After a final newline, the caret is on a line of its own.
        if location == string.length, string.character(at: location - 1) == 0x0A { return false }
        return lineRange(of: min(location, string.length - 1), in: layoutManager).location == 0
    }

    /// Whether the end of the selection is on the text's last line, as laid
    /// out, where Down goes to a newer message.
    var caretOnLastLine: Bool {
        let string = textView.string as NSString
        let location = NSMaxRange(textView.selectedRange())
        guard location < string.length, let layoutManager = textView.layoutManager else { return true }
        // A final newline starts a line after the last character's.
        if string.character(at: string.length - 1) == 0x0A { return false }
        return NSMaxRange(lineRange(of: location, in: layoutManager)) >= layoutManager.numberOfGlyphs
    }

    /// The glyphs on the laid-out line that holds `character`.
    private func lineRange(of character: Int, in layoutManager: NSLayoutManager) -> NSRange {
        let glyph = layoutManager.glyphIndexForCharacter(at: character)
        var range = NSRange()
        layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
        return range
    }

    func textChanged() {
        let string = textView.string
        // Stops at the first character that isn't whitespace, usually the first.
        isBlank = !string.contains { !$0.isWhitespace }
        updateSendButton()
        // The placeholder comes and goes with the text.
        if string.isEmpty != hadNoText {
            hadNoText = string.isEmpty
            textView.needsDisplay = true
        }
        updateToken()
        defer { updateEdgeFade() }
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        // Only as far down as the field can grow: past that it scrolls, and
        // the rest is laid out as it shows.
        let tallest = Self.lineHeight * Self.maxLines
        layoutManager.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: container.size.width, height: tallest + 1), in: container)
        let used = layoutManager.usedRect(for: container).height
        let height = min(max(Self.lineHeight, used), tallest).rounded(.up)
        guard textHeight.constant != height else { return }
        // A line more or less eases the card to its new height; text set all
        // at once, such as a sent message clearing it, or a field out of
        // sight, lands there at once.
        let lines = abs(height - textHeight.constant) / Self.lineHeight
        guard window?.isVisible == true, !Theme.reduceMotion, lines < 3 else {
            textHeight.constant = height
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Duration.standard
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            textHeight.animator().constant = height
        }
    }

    /// Makes `/name` at the start a token while it names a skill: in the
    /// accent, on a soft plate of it, which fades in and out with it.
    private func updateToken() {
        let string = textView.string
        var length = 0
        if string.hasPrefix("/") {
            let name = string.dropFirst().prefix { !$0.isWhitespace }
            if lookedUp?.name != name {
                lookedUp = (name, !name.isEmpty && isSkill?(String(name)) == true)
            }
            if lookedUp?.isSkill == true { length = name.utf16.count + 1 }
        }
        textView.tokenLength = length
    }

    /// The skills on offer changed, so a `/name` is looked up again.
    func skillsChanged() {
        lookedUp = nil
        updateToken()
    }

    @objc private func textScrolled(_ notification: Notification) {
        updateEdgeFade()
    }

    private func updateEdgeFade() {
        let visible = scrollView.contentView.bounds
        scrollView.fadeEdges(above: visible.minY > 1, below: textView.frame.height - visible.maxY > 1)
    }

    /// Shows that the chat takes `used` tokens of the model's `window`.
    func showContextUsage(used: Int, window: Int) {
        contextMeter.show(used: used, window: window)
    }

    /// Marks a message going out: the send arrow lifts away.
    func didSend() {
        sendButton.launch()
    }

    /// Puts the caret in the field and asks macOS to dictate into it, as
    /// Edit > Start Dictation does.
    @objc private func dictate(_ sender: Any?) {
        window?.makeFirstResponder(textView)
        if !NSApp.sendAction(Selector(("startDictation:")), to: nil, from: sender) { NSSound.beep() }
    }

    private func updateSendButton() {
        let empty = isEmpty
        // While a turn runs, a written message is queued instead.
        if isBusy && empty {
            sendButton.show(.stop, toolTip: "Stop (⎋)")
        } else {
            sendButton.show(.send, toolTip: isBusy ? "Queue (↩) · Stop and Send (⌃↩)" : "Send (↩)")
        }
        sendButton.isEnabled = isBusy || !empty || hasQueued
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        let focused = window?.firstResponder === textView
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer.cornerRadius = Self.radius
        layer.cornerCurve = .continuous
        // See-through over the panel's material, unless Reduce Transparency is on.
        let background: NSColor = isDropTarget ? Theme.accent(0.08)
            : Theme.surface.dynamic(alpha: Theme.reduceTransparency ? 1 : dark ? 0.75 : 0.92)
        // Neutral, as the text is what holds the eye: the edge firms up under
        // the mouse and more with focus. Only a drop takes the accent.
        let border: NSColor = isDropTarget ? Theme.accentColor
            : focused ? Theme.text.dynamic(alpha: dark ? 0.3 : 0.24)
            : isHovered ? Theme.text.dynamic(alpha: dark ? 0.16 : 0.13)
            : Theme.hairline
        // A soft lift off the panel, a little higher while focused.
        let lifted = focused || isDropTarget
        withEasing(Theme.Duration.standard) {
            layer.backgroundColor = background.layerColor
            layer.borderWidth = isDropTarget ? 1.5 : Theme.hairlineWidth
            layer.borderColor = border.layerColor
            layer.shadowColor = (isDropTarget ? Theme.accentColor : .black).layerColor
            layer.shadowOpacity = lifted ? (dark ? 0.4 : 0.1) : (dark ? 0.25 : 0.05)
            layer.shadowRadius = lifted ? 14 : 8
            layer.shadowOffset = CGSize(width: 0, height: lifted ? -4 : -2)
        }
        // A path keeps the shadow off the offscreen pass AppKit would
        // otherwise render the card's contents in to find its outline.
        layer.shadowPath = shadowPath
        layer.masksToBounds = false
    }

    private var shadowPath: CGPath {
        CGPath(roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = shadowPath
        updateEdgeFade()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        addHoverArea([.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect])
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// Clicks anywhere in the card that isn't a control go to the text.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
    }

    /// Hands the pasteboard's images to `onImages`, and returns false if it
    /// has none, so it is pasted as text.
    private func takeImages(from pasteboard: NSPasteboard) -> Bool {
        guard AgentAttachment.canRead(pasteboard) else { return false }
        onImages?(AgentAttachment.images(on: pasteboard))
        return true
    }

    // MARK: Dropping images

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isDropTarget = AgentAttachment.canRead(sender.draggingPasteboard)
        return isDropTarget ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isDropTarget ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isDropTarget = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDropTarget = false
        return takeImages(from: sender.draggingPasteboard)
    }
}

/// The composer's text, faded out at the top while lines are scrolled up
/// past it and at the bottom while more are below. Masked only while it
/// overflows, so a field that fits draws as it is.
private final class FadingScrollView: NSScrollView {
    private let edgeFade = EdgeFadeMask()

    func fadeEdges(above: Bool, below: Bool) {
        guard above || below else {
            layer?.mask = nil
            return
        }
        wantsLayer = true
        let opaque = CGColor.black
        // The gradient's first stop draws at the top edge here.
        let colors = [above ? .clear : opaque, opaque, opaque, below ? .clear : opaque]
        let added = layer?.mask == nil
        if added {
            edgeFade.fit(bounds)
            layer?.mask = edgeFade
        }
        guard edgeFade.colors as? [CGColor] != colors else { return }
        CATransaction.begin()
        // A fade turning on with the overflow lands at once; one edge
        // giving way to the other as the text scrolls eases.
        CATransaction.setDisableActions(added || Theme.reduceMotion)
        CATransaction.setAnimationDuration(Theme.Duration.quick)
        edgeFade.colors = colors
        CATransaction.commit()
    }

    /// Follows the field's height frame by frame as it eases.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if layer?.mask != nil { edgeFade.fit(bounds) }
    }
}

/// The composer's send button: an arrow on a disc of the text color, which
/// greys out with nothing to send, and a square on the same disc while a turn
/// can be stopped. The disc eases between states, dips under a press and pops
/// a little as it comes on; the glyph turns into the other one, and the
/// arrow lifts away as a message goes. While the stop square shows, a short
/// arc circles inside the disc's edge to say the agent is working.
final class SendButton: NSButton {
    enum Mode { case send, stop }

    static let side: CGFloat = 28

    private(set) var mode = Mode.send
    private let disc = CALayer()
    private let glyph = CALayer()
    private let ring = CAShapeLayer()
    /// What the glyph last showed, so a change of mode or of being enabled
    /// is animated once, not on every hover redraw.
    private var shownMode: Mode?
    private var shownEnabled: Bool?
    /// When the arrow last lifted away, which stands in for the morph to
    /// the stop square that a sent message brings.
    private var launched: CFTimeInterval = 0
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isBordered = false
        title = ""
        imagePosition = .noImage
        setButtonType(.momentaryChange)
        layer?.addSublayer(disc)
        disc.addSublayer(glyph)
        disc.addSublayer(ring)
        ring.fillColor = nil
        ring.lineWidth = 1.5
        ring.lineCap = .round
        ring.strokeEnd = 0.3
        ring.opacity = 0
        disc.cornerCurve = .circular
        // The arrow leaving goes out of sight at the disc's edge.
        disc.masksToBounds = true
        glyph.contentsGravity = .center
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
        setAccessibilityLabel("Send")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows `mode`, with `toolTip`, changing nothing that is already so.
    func show(_ mode: Mode, toolTip: String) {
        if self.toolTip != toolTip { self.toolTip = toolTip }
        guard mode != self.mode else { return }
        self.mode = mode
        setAccessibilityLabel(mode == .stop ? "Stop" : "Send")
        needsDisplay = true
    }

    override var isEnabled: Bool {
        didSet { if isEnabled != oldValue { needsDisplay = true } }
    }

    override var isHighlighted: Bool {
        didSet { if isHighlighted != oldValue { needsDisplay = true } }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let side = Self.side
        disc.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        disc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        disc.cornerRadius = side / 2
        glyph.frame = disc.bounds
        ring.frame = disc.bounds
        ring.path = CGPath(ellipseIn: disc.bounds.insetBy(dx: 3, dy: 3), transform: nil)

        let fill: NSColor
        let ink: NSColor
        switch (mode, isEnabled) {
        case (.stop, _), (.send, true):
            fill = Theme.text
            ink = Theme.chrome
        case (.send, false):
            fill = Theme.fill(Theme.Fill.pressed)
            ink = Theme.text.dynamic(alpha: 0.4)
        }
        // Hover and press redraw often, the glyph only per state and appearance.
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = "\(mode)-\(isEnabled)-\(dark)-\(Settings.theme.rawValue)"
        var image = Self.glyphs[key]
        if image == nil {
            // A fixed color, since the image would resolve a dynamic one
            // whenever, and in whichever appearance, it is drawn.
            effectiveAppearance.performAsCurrentDrawingAppearance {
                image = Self.glyph(for: mode, color: NSColor(cgColor: ink.cgColor) ?? ink)
            }
            Self.glyphs[key] = image
        }
        let scale: CGFloat = isHighlighted && isEnabled ? 0.9 : 1
        withEasing(Theme.Duration.quick) {
            disc.backgroundColor = fill.layerColor
            disc.opacity = isHovered && isEnabled && !isHighlighted ? 0.88 : 1
            disc.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        }
        let modeChanged = shownMode != nil && shownMode != mode
        let cameOn = shownEnabled == false && isEnabled
        shownMode = mode
        shownEnabled = isEnabled
        glyph.contents = image
        glyph.contentsScale = window?.backingScaleFactor ?? 2
        updateRing(ink: ink)
        guard window != nil, !Theme.reduceMotion else { return }
        if modeChanged, CACurrentMediaTime() - launched < 0.5 {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Theme.Duration.quick
            glyph.add(fade, forKey: "contents")
        } else if modeChanged {
            // The arrow and the square turn into each other.
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Theme.Duration.slide
            glyph.add(fade, forKey: "contents")
            glyph.add(Self.spring(keyPath: "transform.scale", from: 0.4, overshoot: 1.12), forKey: "morph")
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = mode == .stop ? -CGFloat.pi / 2 : CGFloat.pi / 2
            turn.toValue = 0
            turn.duration = Theme.Duration.slide
            turn.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            glyph.add(turn, forKey: "turn")
        } else if cameOn {
            disc.add(Self.spring(keyPath: "transform.scale", from: 0.86, overshoot: 1.06), forKey: "on")
        }
    }

    /// Shows the arc and keeps it turning while the stop square shows, in a
    /// window and without Reduce Motion, where a still arc would read as
    /// something stuck.
    private func updateRing(ink: NSColor) {
        let spins = mode == .stop && window != nil && !Theme.reduceMotion
        ring.strokeColor = ink.dynamic(alpha: 0.55).layerColor
        guard spins else {
            guard ring.animation(forKey: "spin") != nil else { return }
            // Fades, then stops turning, unless the square came back meanwhile.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.reduceMotion ? 0 : Theme.Duration.slide
                context.allowsImplicitAnimation = true
                ring.opacity = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.mode != .stop else { return }
                    self.ring.removeAnimation(forKey: "spin")
                }
            }
            return
        }
        withEasing(Theme.Duration.slide) { ring.opacity = 1 }
        if ring.animation(forKey: "spin") == nil {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            // Clockwise whichever way up the layer is drawn.
            let turn: CGFloat = disc.contentsAreFlipped() ? 2 * .pi : -2 * .pi
            spin.fromValue = 0
            spin.toValue = turn
            spin.duration = 1
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            ring.add(spin, forKey: "spin")
        }
    }

    /// The spin is dropped with the window and taken up again in the next.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }

    /// Scales from `from` past `overshoot` to full size.
    private static func spring(keyPath: String, from: CGFloat, overshoot: CGFloat) -> CAAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = [from, overshoot, 1]
        animation.keyTimes = [0, 0.6, 1]
        animation.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        animation.duration = Theme.Duration.panel
        return animation
    }

    /// A copy of the arrow lifts out of the top of the disc, and the glyph,
    /// by then often the stop square, rises in from below as a message
    /// goes. Nothing under Reduce Motion.
    func launch() {
        guard window != nil, !Theme.reduceMotion, mode == .send else { return }
        launched = CACurrentMediaTime()
        // Up is +y unless the layer is drawn flipped.
        let up: CGFloat = disc.contentsAreFlipped() ? -1 : 1
        let travel = Self.side * 0.8 * up
        let ghost = CALayer()
        ghost.frame = glyph.frame
        ghost.contents = glyph.contents
        ghost.contentsGravity = .center
        ghost.contentsScale = glyph.contentsScale
        disc.addSublayer(ghost)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ghost.removeFromSuperlayer() }
        let out = CABasicAnimation(keyPath: "transform.translation.y")
        out.fromValue = 0
        out.toValue = travel
        out.duration = 0.18
        out.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.9, 0.5)
        out.fillMode = .forwards
        out.isRemovedOnCompletion = false
        ghost.add(out, forKey: "out")
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -travel
        rise.toValue = 0
        rise.beginTime = CACurrentMediaTime() + 0.12
        rise.duration = Theme.Duration.panel
        rise.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        rise.fillMode = .backwards
        glyph.add(rise, forKey: "launch")
        CATransaction.commit()
    }

    private static var glyphs: [String: NSImage] = [:]

    private static func glyph(for mode: Mode, color: NSColor) -> NSImage? {
        let name = mode == .stop ? "stop.fill" : "arrow.up"
        let size: CGFloat = mode == .stop ? 10 : 13
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    private var hoverArea: NSTrackingArea?

    // Only its own area is replaced: the others are AppKit's.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === hoverArea else { return super.mouseEntered(with: event) }
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === hoverArea else { return super.mouseExited(with: event) }
        isHovered = false
    }
}

/// A borderless text button with a small chevron after it, which opens a
/// menu: the composer's model. Plain secondary text at rest, stronger when
/// `isEmphasized`, with the hover plate of the other bar buttons.
final class ComposerChip: HoverButton {
    var isEmphasized = false {
        didSet { if isEmphasized != oldValue { updateTitle() } }
    }

    override var title: String {
        didSet {
            guard title != oldValue else { return }
            // A new model or effort fades in over the old name.
            crossfade()
            updateTitle()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .accessoryBarAction
        image = Theme.symbol("chevron.down", size: 8, weight: .semibold)
        imagePosition = .imageTrailing
        imageHugsTitle = true
        lineBreakMode = .byTruncatingTail
        cell?.lineBreakMode = .byTruncatingTail
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Theme.ButtonSize.bar).isActive = true
        setAccessibilityLabel("Model")
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateTitle() {
        let color: NSColor = isEmphasized ? Theme.text : Theme.secondaryText
        contentTintColor = color
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: Theme.FontSize.secondary, weight: .medium),
            .foregroundColor: color,
        ])
    }

    /// Room on each side for the plate.
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 12
        return size
    }
}

/// A small ring that fills as the chat takes up its model's context window,
/// as Codex's does: in the secondary text color, orange from 80% and red
/// from 95%, with the numbers in its tooltip. Hidden until the agent reports
/// them; it fades in, and the ring eases to each new amount.
final class ContextMeter: NSView {
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()
    private(set) var fraction: CGFloat = 0
    private static let diameter: CGFloat = 14
    private static let lineWidth: CGFloat = 2

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for ring in [track, fill] {
            ring.fillColor = nil
            ring.lineWidth = Self.lineWidth
            ring.lineCap = .round
            layer?.addSublayer(ring)
        }
        fill.strokeEnd = 0
        isHidden = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Theme.ButtonSize.bar),
            heightAnchor.constraint(equalToConstant: Theme.ButtonSize.bar),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel("Context window")
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(used: Int, window: Int) {
        let fraction = min(1, max(0, CGFloat(used) / CGFloat(window)))
        let percent = Int((fraction * 100).rounded())
        toolTip = "Context window: \(percent)% used\n\(Self.tokens(used)) of \(Self.tokens(window)) tokens"
        setAccessibilityValue("\(percent)% used")
        let from = isHidden ? 0 : self.fraction
        self.fraction = fraction
        setShown(true, duration: Theme.Duration.standard)
        needsDisplay = true
        guard window > 0, self.window != nil, !Theme.reduceMotion, from != fraction else { return }
        let ease = CABasicAnimation(keyPath: "strokeEnd")
        ease.fromValue = from
        ease.toValue = fraction
        ease.duration = 0.5
        ease.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        fill.add(ease, forKey: "fill")
    }

    /// 950, 12.3K, 258K, 1M.
    static func tokens(_ count: Int) -> String {
        func short(_ value: Double, _ unit: String) -> String {
            let text = value < 10 ? String(format: "%.1f", value) : String(Int(value.rounded()))
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + unit
        }
        if count >= 1_000_000 { return short(Double(count) / 1_000_000, "M") }
        if count >= 1000 { return short(Double(count) / 1000, "K") }
        return String(count)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = (Self.diameter - Self.lineWidth) / 2
        // From the top, clockwise whichever way up the layer is drawn.
        let path = CGMutablePath()
        if fill.contentsAreFlipped() {
            path.addArc(center: center, radius: radius, startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: false)
        } else {
            path.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: -1.5 * .pi, clockwise: true)
        }
        let ink: NSColor = fraction >= 0.95 ? .systemRed : fraction >= 0.8 ? .systemOrange : Theme.secondaryText
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for ring in [track, fill] {
            ring.frame = bounds
            ring.path = path
        }
        track.strokeColor = Theme.text.dynamic(alpha: 0.14).layerColor
        fill.strokeColor = ink.layerColor
        fill.strokeEnd = fraction
        CATransaction.commit()
    }
}

// MARK: Queued messages

/// The messages written while a turn runs, above the tab bar: one row each,
/// which a click takes back into the field and its close button removes.
/// Empty, it takes no room.
final class QueuedMessagesView: NSView {
    var onEdit: ((Int) -> Void)?
    var onRemove: ((Int) -> Void)?
    var onSendNow: (() -> Void)?

    private let stack = NSStackView()
    private let header = NSStackView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let sendNowButton = NSButton(title: "Send Now", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        headerLabel.font = .systemFont(ofSize: Theme.FontSize.caption, weight: .medium)
        headerLabel.textColor = Theme.secondaryText
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sendNowButton.bezelStyle = .accessoryBarAction
        sendNowButton.controlSize = .small
        sendNowButton.font = .systemFont(ofSize: Theme.FontSize.caption, weight: .medium)
        sendNowButton.target = self
        sendNowButton.action = #selector(sendNow(_:))
        header.orientation = .horizontal
        header.spacing = 6
        // The header's text starts where the rows' text does.
        header.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 0)
        header.setViews([headerLabel, sendNowButton], in: .leading)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Each message's text and how many images it has.
    func show(_ messages: [(text: String, images: Int)], paused: Bool) {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        // Room from the transcript only while there is something to show.
        stack.edgeInsets = NSEdgeInsets(top: messages.isEmpty ? 0 : 6, left: 0, bottom: 0, right: 0)
        guard !messages.isEmpty else { return }
        headerLabel.stringValue = paused ? "Queued · paused" : "Queued · sends when this turn finishes"
        sendNowButton.isHidden = !paused
        stack.addArrangedSubview(header)
        for (index, message) in messages.enumerated() {
            let row = QueuedMessageRow(text: message.text, images: message.images)
            row.onEdit = { [weak self] in self?.onEdit?(index) }
            row.onRemove = { [weak self] in self?.onRemove?(index) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    @objc private func sendNow(_ sender: Any?) { onSendNow?() }
}

/// A queued message's first line, with its image count and a close button.
private final class QueuedMessageRow: NSView {
    var onEdit: (() -> Void)?
    var onRemove: (() -> Void)?

    private let closeButton = HoverButton()
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var isPressed = false {
        didSet { if isPressed != oldValue { needsDisplay = true } }
    }

    init(text: String, images: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.row
        layer?.cornerCurve = .continuous

        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let imageNote = images == 0 ? nil : images == 1 ? "1 image" : "\(images) images"
        let label = NSTextField(labelWithString: firstLine.isEmpty ? imageNote ?? "" : firstLine)
        label.font = .systemFont(ofSize: Theme.FontSize.secondary)
        label.textColor = firstLine.isEmpty ? Theme.secondaryText : Theme.text
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let count = NSTextField(labelWithString: firstLine.isEmpty ? "" : imageNote ?? "")
        count.font = .systemFont(ofSize: Theme.FontSize.caption)
        count.textColor = Theme.secondaryText
        count.isHidden = count.stringValue.isEmpty

        closeButton.image = Theme.closeImage(size: 8, label: "Remove from Queue")
        closeButton.isBordered = false
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = Theme.secondaryText
        closeButton.toolTip = "Remove from Queue"
        closeButton.plateRadius = 8
        closeButton.target = self
        closeButton.action = #selector(remove(_:))

        for view in [label, count, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(greaterThanOrEqualTo: count.trailingAnchor, constant: 4),
            closeButton.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        toolTip = "Click to edit"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Queued: " + (firstLine.isEmpty ? imageNote ?? "" : firstLine))
        setAccessibilityHelp("Takes the message back into the field to edit")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let alpha = isPressed ? Theme.Fill.pressed : isHovered ? Theme.Fill.hover : Theme.Fill.rest
        withEasing(Theme.Duration.quick) { layer?.backgroundColor = Theme.fill(alpha).layerColor }
        layer?.borderWidth = Theme.hairlineWidth
        layer?.borderColor = Theme.hairline.layerColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        addHoverArea([.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect])
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onEdit?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onEdit?()
        return true
    }

    @objc private func remove(_ sender: Any?) { onRemove?() }
}

/// The images Quick Look shows for the panel.
final class QuickLookItems: NSObject, QLPreviewPanelDataSource {
    var urls: [URL] = []
    var index = 0

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }
}

/// A text view that shows a grey hint while empty and reports focus changes.
/// Images pasted into it go to `onPasteboardImages`, and images dragged onto
/// it go to `imageDropTarget`.
final class PlaceholderTextView: NSTextView {
    var placeholder = "" {
        didSet {
            needsDisplay = true
            setAccessibilityPlaceholderValue(placeholder)
        }
    }
    /// Drawn when `placeholder` would truncate. VoiceOver still reads the
    /// full one.
    var shortPlaceholder = "" {
        didSet { needsDisplay = true }
    }
    /// How many characters at the start make a token, drawn in the accent on
    /// a rounded plate of it. 0 for none.
    var tokenLength = 0 {
        didSet {
            // Set again on every change, as an edit can carry the color
            // past the token or take it off part of it.
            guard tokenLength != 0 || oldValue != 0, let layoutManager else { return }
            let all = NSRange(location: 0, length: (string as NSString).length)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
            if tokenLength > 0 {
                let token = NSRange(location: 0, length: min(tokenLength, all.length))
                layoutManager.addTemporaryAttribute(.foregroundColor, value: Theme.accentColor, forCharacterRange: token)
            }
            // A token coming or going fades in or out, rather than snapping.
            if (tokenLength == 0) != (oldValue == 0) { crossfade(duration: Theme.Duration.quick) }
            if tokenLength != oldValue { needsDisplay = true }
        }
    }
    var onFocusChange: (() -> Void)?
    /// Sees each key first, and returns true for one it handled.
    var onKeyDown: ((NSEvent) -> Bool)?
    /// Takes the pasteboard's images, returning false if it has none.
    var onPasteboardImages: ((NSPasteboard) -> Bool)?
    weak var imageDropTarget: NSView?

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true { super.keyDown(with: event) }
    }

    override func paste(_ sender: Any?) {
        if onPasteboardImages?(.general) != true { super.paste(sender) }
    }

    /// Paste is on for an image, which plain text can't take.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), onPasteboardImages != nil, AgentAttachment.canRead(.general) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + AgentAttachment.pasteboardTypes
    }

    private func dropsImages(_ sender: (any NSDraggingInfo)?) -> Bool {
        guard let sender, imageDropTarget != nil else { return false }
        return AgentAttachment.canRead(sender.draggingPasteboard)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropsImages(sender) ? imageDropTarget!.draggingEntered(sender) : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropsImages(sender) ? imageDropTarget!.draggingUpdated(sender) : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if dropsImages(sender) { imageDropTarget!.draggingExited(sender) } else { super.draggingExited(sender) }
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropsImages(sender) || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropsImages(sender) ? imageDropTarget!.performDragOperation(sender) : super.performDragOperation(sender)
    }

    /// The token's plate goes under the text, padded a little past it on
    /// each side, into the room the text container's inset leaves.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard tokenLength > 0, let layoutManager, let textContainer else { return }
        let characters = NSRange(location: 0, length: min(tokenLength, (string as NSString).length))
        let glyphs = layoutManager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        var plate = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        plate.origin.x += textContainerOrigin.x
        plate.origin.y += textContainerOrigin.y
        plate = plate.insetBy(dx: -3, dy: 0)
        Theme.accent(Theme.Accent.soft).setFill()
        NSBezierPath(roundedRect: plate, xRadius: 4, yRadius: 4).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: Theme.FontSize.body),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: textContainerOrigin.x + padding, y: textContainerOrigin.y)
        let available = bounds.width - origin.x - textContainerOrigin.x - padding
        var text = NSAttributedString(string: placeholder, attributes: attributes)
        // A shorter hint whole reads better than the long one cut off.
        if !shortPlaceholder.isEmpty, ceil(text.size().width) > available {
            text = NSAttributedString(string: shortPlaceholder, attributes: attributes)
        }
        text.draw(with: NSRect(origin: origin, size: NSSize(width: available, height: bounds.height)),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// The hint that fits depends on the width, so it is drawn again on a resize.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged, string.isEmpty, !placeholder.isEmpty { needsDisplay = true }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            // The caret in the theme's accent, read again in case it changed.
            insertionPointColor = Theme.accentColor
            onFocusChange?()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?() }
        return accepted
    }
}
