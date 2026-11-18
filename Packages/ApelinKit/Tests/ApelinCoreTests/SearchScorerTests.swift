import ApelinCore
import XCTest

final class SearchScorerTests: XCTestCase {
    func testTiers() {
        let scorer = SearchScorer.self
        XCTAssertEqual(scorer.score("claude", against: "claude"), .exact)
        XCTAssertEqual(scorer.score("claude-3-5", against: "claude"), .prefix)
        XCTAssertEqual(scorer.score("gemini-2.5-pro", against: "2.5"), .tokenPrefix)
        XCTAssertEqual(scorer.score("claude-opus", against: "opus"), .tokenPrefix)
        XCTAssertEqual(scorer.score("a-claude-b", against: "claude"), .substring)
        XCTAssertEqual(scorer.score("gemini-2.5-pro", against: "g25p"), .subsequence)
        XCTAssertNil(scorer.score("claude", against: "xyz"))
    }

    func testRankingPutsExactBeforePrefixBeforeOther() {
        let names = [
            "my-claude-helper",
            "claude-3-5-sonnet",
            "claude",
            "something claude inside",
        ]
        let ranked = SearchScorer.sorted(names, query: "claude", text: { $0 })
        XCTAssertEqual(Array(ranked.prefix(3)), ["claude", "claude-3-5-sonnet", "my-claude-helper"])
        XCTAssertEqual(ranked.last, "something claude inside")
    }

    func testTokenPrefixBeatsSubstring() {
        let names = ["the opus legacy", "opus-4", "gpt-opus"]
        let ranked = SearchScorer.sorted(names, query: "opus", text: { $0 })
        XCTAssertEqual(ranked.first, "opus-4")
    }

    func testCaseAndDiacritics() {
        let ranked = SearchScorer.sorted(["Sönnet Alpha", "sonnet", "Sonnet Beta"], query: "sonnet", text: { $0 })
        XCTAssertTrue(ranked.contains("sonnet"))
        XCTAssertTrue(ranked.contains("Sönnet Alpha"))
    }

    func testTiesKeepCallerOrder() {
        let names = ["alpha-one", "alpha-two", "alpha-three"]
        XCTAssertEqual(SearchScorer.sorted(names, query: "alpha", text: { $0 }), names)
    }

    func testEmptyQueryMatchesNothing() {
        XCTAssertTrue(SearchScorer.sorted(["a", "b"], query: "  ", text: { $0 }).isEmpty)
    }
}
