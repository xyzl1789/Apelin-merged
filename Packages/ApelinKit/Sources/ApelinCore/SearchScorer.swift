import Foundation

/// Ranks a list of strings against a query, best match first.
///
/// A plain `localizedStandardContains` answers only "is it in there": typing
/// the first letters of a model's name can put an unrelated model whose id
/// happens to contain those letters ahead of the one asked for. A search that
/// narrows as you type should read like the reader's intent — an exact name
/// first, then one that starts with what was typed, then a word that starts
/// with it, then a match anywhere, and a scattered match last.
///
/// The tiers are deliberately ordered, never added: a short id that matches
/// exactly must outrank a long paragraph that merely contains the same words,
/// however many times it contains them.
public enum SearchScorer {
    /// How well a candidate matches. Larger is better; `nil` is no match.
    /// Raw values leave room to refine a tier without reordering the others.
    public enum Tier: Int, Sendable {
        case subsequence = 100
        case substring = 700
        case tokenPrefix = 800
        case prefix = 900
        case exact = 1000
    }

    /// Characters that begin a word in an id or a name. Model ids join words
    /// with these instead of spaces: `claude-3-5-sonnet`, `gemini/2.5/pro`.
    private static let tokenBoundaries: Set<Character> = ["-", "/", ".", "_", ":", " ", "\t"]

    /// Returns `candidates` that match `query`, best first. Ties keep the
    /// caller's order, so a stable roster never reshuffles while unchanged.
    /// Empty queries match nothing: callers show their full list themselves.
    public static func ranked<T>(_ candidates: [T], query: String, text: (T) -> String) -> [(item: T, tier: Tier)] {
        let needle = fold(query)
        guard !needle.isEmpty else { return [] }
        var result: [(item: T, tier: Tier, order: Int)] = []
        for (index, candidate) in candidates.enumerated() {
            guard let tier = score(fold(text(candidate)), against: needle) else { continue }
            result.append((candidate, tier, index))
        }
        result.sort { left, right in
            if left.tier != right.tier { return left.tier.rawValue > right.tier.rawValue }
            return left.order < right.order
        }
        return result.map { ($0.item, $0.tier) }
    }

    /// Just the matches, in rank order — the common case for a filter.
    public static func sorted<T>(_ candidates: [T], query: String, text: (T) -> String) -> [T] {
        ranked(candidates, query: query, text: text).map(\.item)
    }

    /// The tier one folded candidate earns, or nil when it does not match.
    static func score(_ folded: String, against needle: String) -> Tier? {
        if folded == needle { return .exact }
        if folded.hasPrefix(needle) { return .prefix }
        if tokenHasPrefix(folded, needle) { return .tokenPrefix }
        if folded.localizedCaseInsensitiveContains(needle) { return .substring }
        if isSubsequence(needle, of: folded) { return .subsequence }
        return nil
    }

    /// Case- and diacritic-insensitive, so a reader can type `sonnet` or
    /// `Sönnet` and find the same row. `precomposedStringWithCanonicalMapping`
    /// steadies the unicode form before folding.
    public static func fold(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US")
        )
    }

    /// A word boundary starts at the beginning or after a separator.
    private static func tokenHasPrefix(_ folded: String, _ needle: String) -> Bool {
        for index in folded.indices {
            guard folded[index...].hasPrefix(needle) else { continue }
            if index == folded.startIndex { return true }
            let before = folded.index(before: index)
            if tokenBoundaries.contains(folded[before]) { return true }
        }
        return false
    }

    /// Ordered letters with anything between them: `g25p` finds
    /// `gemini-2.5-pro`. Case has already been folded away by the caller.
    private static func isSubsequence(_ needle: String, of folded: String) -> Bool {
        var cursor = folded.startIndex
        for character in needle {
            guard let found = folded[cursor...].firstIndex(of: character) else { return false }
            cursor = folded.index(after: found)
        }
        return true
    }
}
