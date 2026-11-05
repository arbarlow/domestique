import SwiftUI

/// Indirection so chat code blocks can use the panel's SyntaxHighlighter.
/// `language` may be a markdown fence tag ("tsx", "bash") or a highlighter language id ("ts", "sh").
enum CodeHighlight {
    static func lines(_ code: String, language: String) -> [AttributedString] {
        let lang = SyntaxHighlighter.specs[language] != nil ? language : SyntaxHighlighter.language(forFence: language)
        return SyntaxHighlighter.highlightLines(code, language: lang)
    }
}
