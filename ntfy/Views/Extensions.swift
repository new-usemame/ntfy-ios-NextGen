import SwiftUI
import UIKit

// MARK: Extensions

extension Notification {
    /// Body for display: rendered Markdown when the message is `text/markdown`
    /// (ntfy #1072), otherwise plain text with detected links made tappable.
    func renderedMessageAttributedString() -> AttributedString {
        return renderMessageBody(formatMessage(), contentType: contentType)
    }

    func linkifiedMessageAttributedString() -> AttributedString {
        return renderMessageBody(formatMessage(), contentType: nil)
    }
}

/// Pure + testable. Parses Markdown (iOS 15+) when `contentType` is
/// `text/markdown`; otherwise linkifies plain text via `linkify()`. Markdown
/// failures fall back to the linkified plain text so a malformed body never
/// renders empty.
func renderMessageBody(_ source: String, contentType: String?) -> AttributedString {
    if #available(iOS 15.0, *), contentType == "text/markdown" {
        if var attributed = try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible)) {
            // Foundation's markdown parser only links [text](url)/<url>, never a bare
            // "https://…", so a bare URL in a markdown message rendered dead while the
            // exact same text as plain text was tappable. Run the same detector pass the
            // plain-text path uses over the parsed runs to close that gap (ntfy #1743).
            linkifyBareUrls(in: &attributed)
            return attributed
        }
    }
    // Plain-text path: full-range link styling (ntfy #1743) via the shared linkify().
    return linkify(source)
}

/// Add tappable + styled links to any bare URL in an already-parsed AttributedString
/// (e.g. markdown output), WITHOUT disturbing existing runs. Ranges that already carry
/// a `.link` (markdown-authored links) are left untouched so their target/label survive.
/// Operates purely on the Swift AttributedString so no markdown styling is ever lost.
func linkifyBareUrls(in attributed: inout AttributedString) {
    let text = String(attributed.characters)
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    let range = NSRange(location: 0, length: (text as NSString).length)
    detector?.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
        guard let match, let url = match.url, let strRange = Range(match.range, in: text) else { return }
        let start = text.distance(from: text.startIndex, to: strRange.lowerBound)
        let length = text.distance(from: strRange.lowerBound, to: strRange.upperBound)
        let lower = attributed.index(attributed.startIndex, offsetByCharacters: start)
        let upper = attributed.index(lower, offsetByCharacters: length)
        let attrRange = lower..<upper
        guard attributed[attrRange].link == nil else { return }  // keep markdown-authored links
        attributed[attrRange].link = url
        attributed[attrRange].foregroundColor = UIColor.link
        attributed[attrRange].underlineStyle = NSUnderlineStyle.single
    }
}

/// Detect links in `source` and return an AttributedString with each link made
/// tappable AND fully styled (color + underline) across its ENTIRE range.
///
/// Setting only `.link` and letting SwiftUI apply the implicit link styling
/// truncated the coloring/underline of long or line-wrapping URLs to the
/// recognized prefix (ntfy iOS #1743). Applying `.foregroundColor` and
/// `.underlineStyle` explicitly over the full detector match keeps the whole
/// URL visibly a link. Pure + free-standing so it's unit-testable without a
/// Core Data Notification.
func linkify(_ source: String) -> AttributedString {
    let mutable = NSMutableAttributedString(string: source)
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    let range = NSRange(location: 0, length: mutable.string.utf16.count)
    detector?.enumerateMatches(in: mutable.string, options: [], range: range) { match, _, _ in
        guard let match, let url = match.url else { return }
        mutable.addAttribute(.link, value: url, range: match.range)
        mutable.addAttribute(.foregroundColor, value: UIColor.link, range: match.range)
        mutable.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
    }
    return AttributedString(mutable)
}

// MARK: Modifiers

struct DisableAutocapitalizationModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 15.0, *) {
            content
                .textInputAutocapitalization(.never)
        } else {
            content
                .autocapitalization(.none)
        }
    }
}

extension View {
    func disableAutocapitalization() -> some View {
        modifier(DisableAutocapitalizationModifier())
    }
}
