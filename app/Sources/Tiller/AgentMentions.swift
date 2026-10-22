import AppKit

/// An open tab the message field can mention with `@`.
struct AgentTabMention {
    let title: String
    let url: String
    let favicon: NSImage?
    /// The tab in front, which the agent is told about anyway.
    let isSelected: Bool
}

/// Drives a `CompletionPicker` of open tabs for a text view, as Codex's `@`
/// does for files: while the word at the caret starts with `@`, the list
/// shows the tabs whose title or address has what follows, and Tab, Return
/// or a click puts the tab's address in place of the word, so the agent
/// knows which page is meant.
@MainActor
final class MentionCompletion {
    let picker = CompletionPicker(label: "Tabs")
    /// The window's open tabs, read when the picker opens.
    var tabs: () -> [AgentTabMention]
    private weak var textView: NSTextView?
    /// The tabs offered while the picker is open.
    private var offered: [AgentTabMention]?
    /// The tabs listed, in the picker's order.
    private var listed: [AgentTabMention] = []
    /// Where the `@` word is in the text.
    private var word: NSRange?

    init(textView: NSTextView, tabs: @escaping () -> [AgentTabMention]) {
        self.textView = textView
        self.tabs = tabs
        picker.isHidden = true
        picker.onPick = { [weak self] index in
            guard let self, self.listed.indices.contains(index) else { return }
            self.complete(self.listed[index])
        }
    }

    var isShown: Bool { !picker.isHidden }

    /// Call when the text or the selection changes.
    func update() {
        guard let textView, let word = Self.mention(in: textView.string, caret: textView.selectedRange()) else { return hide() }
        let query = (textView.string as NSString).substring(with: NSRange(location: word.location + 1, length: word.length - 1))
        let tabs = offered ?? self.tabs()
        offered = tabs
        self.word = word
        listed = Array(Self.matches(tabs, query).prefix(CompletionPicker.maxRows))
        picker.show(listed.map {
            CompletionItem(
                prefix: "@", name: $0.title.isEmpty ? $0.url : $0.title, badge: $0.isSelected ? "This tab" : nil,
                // A page without an icon gets a globe, so the names line up.
                detail: $0.url, icon: $0.favicon ?? Theme.symbol("globe", size: 13)
            )
        }, highlighting: query)
    }

    /// The `@` word the caret is at the end of, `@` included: one that
    /// starts the text or follows whitespace. Nil while text is selected.
    static func mention(in text: String, caret: NSRange) -> NSRange? {
        guard caret.length == 0 else { return nil }
        let string = text as NSString
        var start = caret.location
        while start > 0 {
            let character = string.character(at: start - 1)
            if character == 0x40 { // @
                let before = start - 1
                guard before == 0 || Self.isSpace(string.character(at: before - 1)) else { return nil }
                return NSRange(location: before, length: caret.location - before)
            }
            if Self.isSpace(character) { return nil }
            start -= 1
        }
        return nil
    }

    private static func isSpace(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// Tabs whose title starts with `query` come first, then those with it
    /// elsewhere in the title or the address, each in the window's order.
    static func matches(_ tabs: [AgentTabMention], _ query: String) -> [AgentTabMention] {
        guard !query.isEmpty else { return tabs }
        let starts = tabs.filter { $0.title.range(of: query, options: [.caseInsensitive, .anchored]) != nil }
        let contains = tabs.filter {
            $0.title.range(of: query, options: [.caseInsensitive, .anchored]) == nil
                && ($0.title.range(of: query, options: .caseInsensitive) != nil || $0.url.range(of: query, options: .caseInsensitive) != nil)
        }
        return starts + contains
    }

    func hide() {
        picker.isHidden = true
        offered = nil
        word = nil
    }

    /// The text view's `doCommandBy` while the picker is open. Returns
    /// whether the picker took the command.
    func handle(_ selector: Selector) -> Bool {
        picker.handle(selector) { hide() }
    }

    /// Puts the tab's address and a space in place of the `@` word, keeping
    /// it undoable.
    func complete(_ tab: AgentTabMention) {
        guard let textView, let word, NSMaxRange(word) <= (textView.string as NSString).length else { return hide() }
        let replacement = tab.url + " "
        if textView.shouldChangeText(in: word, replacementString: replacement) {
            textView.replaceCharacters(in: word, with: replacement)
            textView.didChangeText()
        }
        textView.setSelectedRange(NSRange(location: word.location + (replacement as NSString).length, length: 0))
        hide()
        textView.window?.makeFirstResponder(textView)
    }
}
