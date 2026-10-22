import AppKit
import Testing
@testable import Tiller

@Suite(.serialized)
@MainActor
struct ComposerTests {
    private final class Receiver: NSObject {
        var clicks = 0
        @objc func clicked(_ sender: Any?) { clicks += 1 }
    }

    private func makeComposer() -> (NSWindow, Composer) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 300), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let composer = Composer()
        composer.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(composer)
        NSLayoutConstraint.activate([
            composer.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 12),
            composer.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -12),
            composer.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -12),
        ])
        window.contentView!.layoutSubtreeIfNeeded()
        return (window, composer)
    }

    @Test func emptyFieldDisablesSend() {
        let (window, composer) = makeComposer()
        defer { window.close() }
        #expect(composer.isEmpty)
        #expect(!composer.sendButton.isEnabled)

        composer.text = "  \n "
        #expect(composer.isEmpty)
        #expect(!composer.sendButton.isEnabled)

        composer.text = " hello"
        #expect(!composer.isEmpty)
        #expect(composer.sendButton.isEnabled)
        #expect(composer.sendButton.mode == .send)
    }

    @Test func busyEmptyFieldStops() {
        let (window, composer) = makeComposer()
        defer { window.close() }
        composer.isBusy = true
        #expect(composer.sendButton.mode == .stop)
        #expect(composer.sendButton.isEnabled)

        // Written while busy, the message is queued with the same button.
        composer.text = "next"
        #expect(composer.sendButton.mode == .send)

        composer.text = ""
        composer.isBusy = false
        #expect(composer.sendButton.mode == .send)
        #expect(!composer.sendButton.isEnabled)
    }

    @Test func dictateButtonSitsBesideSend() {
        let (window, composer) = makeComposer()
        defer { window.close() }
        #expect(composer.dictateButton.action != nil)
        #expect(composer.dictateButton.frame.maxX <= composer.sendButton.frame.minX)
        #expect(abs(composer.dictateButton.frame.midY - composer.sendButton.frame.midY) <= 1)
    }

    @Test func queuedMessagesEnableSend() {
        let (window, composer) = makeComposer()
        defer { window.close() }
        composer.hasQueued = true
        #expect(composer.sendButton.isEnabled)
    }

    @Test func busyChangesPlaceholder() {
        let (window, composer) = makeComposer()
        defer { window.close() }
        composer.placeholder = "Ask Codex about this page…"
        #expect(composer.textView.placeholder == "Ask Codex about this page…")
        composer.isBusy = true
        #expect(composer.textView.placeholder == "Queue a follow-up…")
        composer.isBusy = false
        #expect(composer.textView.placeholder == "Ask Codex about this page…")
    }

    @Test func fieldGrowsWithLinesUpToALimit() {
        let (window, composer) = makeComposer()
        defer { window.close() }
        let oneLine = composer.fittingSize.height
        composer.text = "one\ntwo\nthree"
        window.contentView!.layoutSubtreeIfNeeded()
        let threeLines = composer.fittingSize.height
        #expect(threeLines > oneLine)

        composer.text = Array(repeating: "line", count: 60).joined(separator: "\n")
        window.contentView!.layoutSubtreeIfNeeded()
        let capped = composer.fittingSize.height
        composer.text = Array(repeating: "line", count: 120).joined(separator: "\n")
        window.contentView!.layoutSubtreeIfNeeded()
        #expect(composer.fittingSize.height == capped)
        #expect(capped > threeLines)
    }

    /// The send button reaches its action, as the chat sets it up.
    @Test func sendButtonSends() {
        let (window, composer) = makeComposer()
        defer { window.close() }
        let receiver = Receiver()
        composer.sendButton.target = receiver
        composer.sendButton.action = #selector(Receiver.clicked(_:))
        composer.text = "hello"
        composer.sendButton.performClick(nil)
        #expect(receiver.clicks == 1)

        // Nothing to send: the button is off.
        composer.text = ""
        composer.sendButton.performClick(nil)
        #expect(receiver.clicks == 1)
    }

    @Test func effortHasItsOwnButton() {
        let (window, composer) = makeComposer()
        defer { window.close() }
        composer.showOptions(model: "GPT-5", summary: "GPT-5 · high", isDefault: false, effort: "high", hasEfforts: true, tools: [])
        #expect(composer.modelButton.title == "GPT-5")
        #expect(!composer.effortButton.isHidden)
        #expect(composer.effortButton.title == "High")

        composer.showOptions(model: "GPT-5", summary: "GPT-5", isDefault: false, effort: nil, hasEfforts: true, tools: [])
        #expect(composer.effortButton.title == "Effort")

        // An agent without efforts has no effort button.
        composer.showOptions(model: "Default model", summary: "default model", isDefault: true, effort: nil, hasEfforts: false, tools: [])
        #expect(composer.effortButton.isHidden)
    }

    @Test func skillNameReadsAsAToken() {
        let (window, composer) = makeComposer()
        defer { window.close() }
        composer.isSkill = { $0 == "review" }
        composer.text = "/review the page"
        #expect(composer.textView.tokenLength == 7)

        composer.text = "/reviewing"
        #expect(composer.textView.tokenLength == 0)

        // Only at the very start.
        composer.text = "please /review"
        #expect(composer.textView.tokenLength == 0)

        composer.text = "/review"
        composer.isSkill = { _ in false }
        composer.skillsChanged()
        #expect(composer.textView.tokenLength == 0)
    }

    @Test func mentionIsTheAtWordAtTheCaret() {
        func mention(_ text: String) -> NSRange? {
            MentionCompletion.mention(in: text, caret: NSRange(location: (text as NSString).length, length: 0))
        }
        #expect(mention("@") == NSRange(location: 0, length: 1))
        #expect(mention("compare with @git") == NSRange(location: 13, length: 4))
        // Not after a word, as in an email address, nor once a space follows.
        #expect(mention("me@example") == nil)
        #expect(mention("@github ") == nil)
        #expect(MentionCompletion.mention(in: "@git", caret: NSRange(location: 0, length: 4)) == nil)
    }

    @Test func mentionMatchesTitleFirstThenAddress() {
        let tabs = [
            AgentTabMention(title: "Pull requests", url: "https://github.com/pulls", favicon: nil, isSelected: false),
            AgentTabMention(title: "GitHub", url: "https://github.com", favicon: nil, isSelected: true),
            AgentTabMention(title: "Docs", url: "https://example.com", favicon: nil, isSelected: false),
        ]
        #expect(MentionCompletion.matches(tabs, "git").map(\.title) == ["GitHub", "Pull requests"])
        #expect(MentionCompletion.matches(tabs, "").count == 3)
        #expect(MentionCompletion.matches(tabs, "zzz").isEmpty)
    }

    @Test func pickingATabPutsItsAddressInPlaceOfTheWord() {
        let (window, composer) = makeComposer()
        defer { window.close() }
        let tab = AgentTabMention(title: "GitHub", url: "https://github.com/", favicon: nil, isSelected: false)
        let completion = MentionCompletion(textView: composer.textView) { [tab] }
        composer.text = "compare with @git"
        composer.textView.setSelectedRange(NSRange(location: 17, length: 0))
        completion.update()
        #expect(completion.isShown)
        #expect(completion.handle(#selector(NSResponder.insertTab(_:))))
        #expect(composer.text == "compare with https://github.com/ ")
        #expect(!completion.isShown)
    }

    @Test func contextMeterShowsOnceUsageComes() {
        let (window, composer) = makeComposer()
        defer { window.close() }
        #expect(composer.contextMeter.isHidden)
        composer.showContextUsage(used: 64_500, window: 258_000)
        #expect(!composer.contextMeter.isHidden)
        #expect(composer.contextMeter.fraction == 0.25)
        #expect(composer.contextMeter.toolTip == "Context window: 25% used\n65K of 258K tokens")
        #expect(composer.contextMeter.frame.maxX <= composer.dictateButton.frame.minX)
    }

    @Test func tokenCounts() {
        #expect(ContextMeter.tokens(950) == "950")
        #expect(ContextMeter.tokens(1000) == "1K")
        #expect(ContextMeter.tokens(12_340) == "12K")
        #expect(ContextMeter.tokens(1_000_000) == "1M")
        #expect(ContextMeter.tokens(1_500_000) == "1.5M")
    }

    @Test func effortTitles() {
        #expect(AgentModelOptions.effortTitle("low") == "Low")
        #expect(AgentModelOptions.effortTitle("xhigh") == "Extra high")
        #expect(AgentModelOptions.effortTitle("max") == "Max")
    }
}
