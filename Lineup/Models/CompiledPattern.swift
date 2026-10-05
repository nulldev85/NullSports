import Foundation

/// A regular expression compiled once.
///
/// `replacingOccurrences(of:with:options: .regularExpression)` compiles its
/// pattern on every call. For one title that is nothing; for an IPTV
/// provider's list of tens of thousands, each name cleaned with half a dozen
/// patterns, it was most of the wait before the list could be searched.
struct CompiledPattern: @unchecked Sendable {
    // Unchecked because NSRegularExpression is immutable once made, and safe
    // to match with from any number of threads at once.
    private let expression: NSRegularExpression

    init(_ pattern: String) {
        do { expression = try NSRegularExpression(pattern: pattern) }
        catch { preconditionFailure("Invalid pattern \(pattern): \(error)") }
    }

    /// Every match replaced by a template, as `replacingOccurrences` with
    /// `.regularExpression` would.
    func replacing(in text: String, with template: String) -> String {
        expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                            withTemplate: template)
    }

    /// The text of the last match's first capture group.
    func lastCapture(in text: String) -> String? {
        guard let match = expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Where the first match is, as `range(of:options: .regularExpression)`
    /// would say.
    func firstRange(in text: String) -> Range<String.Index>? {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
            .flatMap { Range($0.range, in: text) }
    }
}
