import SwiftUI
import UIKit

// MARK: Extensions

extension Notification {
    func linkifiedMessageAttributedString() -> AttributedString {
        return linkify(formatMessage())
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
