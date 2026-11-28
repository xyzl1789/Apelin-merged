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

    func testLabelsUseOnlyProtocolFieldsForBalancesAndWindows() {
        var quota = snapshot()
        let record = AgentQuotaDisplayRecord(accountID: "deepseek", snapshot: quota)
        XCTAssertEqual(record.balances.first?.label, quota.provider.rawValue)

        quota.accountLabel = "api.example.test"
        XCTAssertEqual(AgentQuotaDisplayRecord(accountID: "deepseek", snapshot: quota).balances.first?.label, "api.example.test")
        quota.kind = .window
        quota.balances = []
        quota.windows = [AgentQuotaWindow(id: "fiveHour", label: "5小时", usedPercent: 25)]
        XCTAssertEqual(AgentQuotaDisplayRecord(accountID: "deepseek", snapshot: quota).balances.first?.label, "api.example.test · 5小时")
        quota.accountLabel = nil
        XCTAssertEqual(AgentQuotaDisplayRecord(accountID: "deepseek", snapshot: quota).balances.first?.label, quota.provider.rawValue + " · 5小时")
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

    func testCreditPackagesRoundTripAndFailureKeepsExpiry() throws {
        var quota = snapshot("98.75", currency: nil, unit: "积分")
        quota.provider = .workBuddy
        quota.creditPackages = [AgentQuotaBalance(id: "pack", unitLabel: "积分", total: 100, used: QuotaDecimalCoding.parse("1.25"), remaining: QuotaDecimalCoding.parse("98.75"), label: "奖励包", expiresAt: date.addingTimeInterval(86400))]
        var record = AgentQuotaDisplayRecord(accountID: "workbuddy", snapshot: quota)
        let restored = try JSONDecoder().decode(AgentQuotaDisplayRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored, record)
        XCTAssertEqual(record.balances.count, 1)
        XCTAssertEqual(record.balances.first?.currency, "积分")
        var failed = quota
        failed.status = .error
        failed.creditPackages = nil
        failed.balances = []
        failed.updatedAt = date.addingTimeInterval(30)
        record.merge(failed)
        XCTAssertEqual(record.snapshot.earliestCreditExpiry, quota.earliestCreditExpiry)
        XCTAssertEqual(record.snapshot.updatedAt, date)
    }

    func testOldCreditPercentWindowsAreNotBalances() {
        for provider in [AgentProvider.workBuddy, .workBuddyAI, .trae] {
            var quota = snapshot()
            quota.provider = provider
            quota.kind = .window
            quota.balances = []
            quota.windows = [AgentQuotaWindow(id: "primary", label: "主要窗口", usedPercent: 33)]
            XCTAssertFalse(AgentQuotaDisplayRecord.hasFigures(quota))
            XCTAssertTrue(AgentQuotaDisplayRecord(accountID: "test", snapshot: quota).balances.isEmpty)
        }
    }

    func testOldCacheWithoutCreditMetadataStillDecodes() throws {
        let text = #"{"id":"credits","unitLabel":"积分","remaining":"1.25"}"#
        let balance = try JSONDecoder().decode(AgentQuotaBalance.self, from: Data(text.utf8))
        XCTAssertEqual(balance.remaining, QuotaDecimalCoding.parse("1.25"))
        XCTAssertNil(balance.label)
        XCTAssertNil(balance.expiresAt)
    }

    func testPersistenceRoundTripKeepsDecimalAndTimestamp() throws {
        let record = AgentQuotaDisplayRecord(accountID: "deepseek#2", snapshot: snapshot("1234567890123456.123456789"))
        let restored = try JSONDecoder().decode(AgentQuotaDisplayRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored, record)
        XCTAssertEqual(restored.balances.first?.updatedAt, date)
    }
}
