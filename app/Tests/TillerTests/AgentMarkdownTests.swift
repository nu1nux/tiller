import AppKit
import Testing
@testable import Tiller

@MainActor
struct AgentMarkdownTests {
    /// Bold next to Chinese punctuation, which CommonMark alone leaves as
    /// literal asterisks.
    @Test func boldsNextToChinesePunctuation() {
        #expect(bold(in: "**建议层级：**P6") == ["建议层级："])
        #expect(bold(in: "**优势：**有 Coding Agent") == ["优势："])
        #expect(bold(in: "中文**“引号”**中文") == ["“引号”"])
        #expect(AgentMarkdown.render("**建议层级：**P6").string == "建议层级：P6")
    }

    @Test func leavesOtherMarkdownAlone() {
        #expect(bold(in: "**Level:** P6") == ["Level:"])
        #expect(AgentMarkdown.render("2**3 and `a：**b`").string == "2**3 and a：**b")
        #expect(AgentMarkdown.render("\\*\\*：**x").string == "**：**x")
        #expect(AgentMarkdown.separatingEmphasis("**Level:** P6") == "**Level:** P6")
    }

    private func bold(in text: String) -> [String] {
        let rendered = AgentMarkdown.render(text)
        var runs: [String] = []
        rendered.enumerateAttribute(.font, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
            guard let font = value as? NSFont, font.fontDescriptor.symbolicTraits.contains(.bold) else { return }
            runs.append((rendered.string as NSString).substring(with: range))
        }
        return runs
    }
}
