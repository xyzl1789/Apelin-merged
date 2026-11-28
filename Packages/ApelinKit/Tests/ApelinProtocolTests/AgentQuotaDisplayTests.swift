import ApelinProtocol
import Foundation
import XCTest

final class AgentQuotaDisplayTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 100)
    private func snapshot(_ amount: String = "12.345", currency: String? = "USD", unit: String? = nil) -> AgentQuotaSnapshot {
        AgentQuotaSnapshot(
            poolID: "key:one", provider: .deepSeek, kind: .balance, source: .activeAPI, status: .available,
            balances: [AgentQuotaBalance(id: "balance", currency: currency, unitLabel: unit, remaining: QuotaDecimalCoding.parse(amount))],
            updatedAt: date
        )
    }

    func testMoneyRoundsButTokensAndOriginalUnitsKeepPrecision() throws {
        let money = AgentQuotaDisplayRecord(accountID: "deepseek", snapshot: snapshot())
        XCTAssertEqual(try XCTUnwrap(money.balances.first).displayedAmount, "12.35")
        let tokens = AgentQuotaDisplayRecord(accountID: "relay", snapshot: snapshot("80852458", currency: nil, unit: "tokens"))
        XCTAssertEqual(try XCTUnwrap(tokens.balances.first).displayedAmount, "80852458")
        let raw = AgentQuotaDisplayRecord(accountID: "relay", snapshot: snapshot("0.00012345", currency: nil, unit: "quota"))
        XCTAssertEqual(try XCTUnwrap(raw.balances.first).displayedAmount, "0.00012345")
    }

    func testZeroIsValidAndUnavailableIsNotZero() {
        let zero = AgentQuotaDisplayRecord(accountID: "deepseek", snapshot: snapshot("0"))
        XCTAssertEqual(zero.balances.first?.displayedAmount, "0.00")
        var empty = snapshot()
        empty.balances = []
        XCTAssertFalse(AgentQuotaDisplayRecord.hasFigures(empty))
        XCTAssertTrue(AgentQuotaDisplayRecord(accountID: "deepseek", snapshot: empty).balances.isEmpty)
    }

    func testFailureAndEmptySuccessKeepFiguresAndTheirSuccessfulTime() {
        for status in [AgentQuotaStatus.error, .cooldown, .circuitBroken, .unsupported, .available] {
            var record = AgentQuotaDisplayRecord(accountID: "deepseek", snapshot: snapshot())
            var next = snapshot("99")
            next.balances = []
            next.status = status
            next.updatedAt = date.addingTimeInterval(60)
            record.merge(next)
            XCTAssertEqual(record.snapshot.balances.first?.remaining, QuotaDecimalCoding.parse("12.345"))
            XCTAssertEqual(record.snapshot.updatedAt, date)
            XCTAssertEqual(record.balances.first?.stale, true)
        }
    }

    func testNewNumbersInErrorResponseAreNotASuccessfulUpdate() {
        var record = AgentQuotaDisplayRecord(accountID: "deepseek", snapshot: snapshot())
        var error = snapshot("99")
        error.status = .error
        error.updatedAt = date.addingTimeInterval(60)
        record.merge(error)
        XCTAssertEqual(record.balances.first?.amount, "12.345")
        XCTAssertEqual(record.snapshot.updatedAt, date)
    }

    func testOldReplyAndDifferentPoolCannotOverwrite() {
        var record = AgentQuotaDisplayRecord(accountID: "deepseek", snapshot: snapshot())
        var older = snapshot("99")
        older.updatedAt = date.addingTimeInterval(-1)
        record.merge(older)
        var another = snapshot("99")
        another.poolID = "key:two"
        record.merge(another)
        XCTAssertEqual(record.balances.first?.amount, "12.345")
        XCTAssertEqual(record.snapshot.updatedAt, date)
    }

    func testMatchingRequiresAccountAndPoolNotHostOrLabel() {
        let record = AgentQuotaDisplayRecord(accountID: "deepseek#2", snapshot: snapshot())
        var account = AgentAccount(provider: .deepSeek, method: .apiKey, signedIn: true, poolID: "key:one", storeID: "deepseek#2")
        XCTAssertTrue(record.matches(account))
        account.storeID = "deepseek"
        XCTAssertFalse(record.matches(account))
        account.storeID = "deepseek#2"
        account.poolID = "key:two"
        XCTAssertFalse(record.matches(account))
        account.poolID = "key:one"
        account.signedIn = false
        XCTAssertFalse(record.matches(account))
    }

    func testWindowProjectsRemainingPercentWithoutMoneyRounding() {
        var next = snapshot()
        next.kind = .window
        next.balances = []
        next.windows = [AgentQuotaWindow(id: "fiveHour", label: "5小时", usedPercent: QuotaDecimalCoding.parse("25.5")!)]
        let record = AgentQuotaDisplayRecord(accountID: "subscription", snapshot: next)
        XCTAssertEqual(record.balances.first?.displayedAmount, "74.5")
        XCTAssertEqual(record.balances.first?.currency, "%")
        XCTAssertEqual(record.balances.first?.isMonetary, false)
    }

    func testPersistenceRoundTripKeepsDecimalAndTimestamp() throws {
        let record = AgentQuotaDisplayRecord(accountID: "deepseek#2", snapshot: snapshot("1234567890123456.123456789"))
        let restored = try JSONDecoder().decode(AgentQuotaDisplayRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored, record)
        XCTAssertEqual(restored.balances.first?.updatedAt, date)
    }
}
