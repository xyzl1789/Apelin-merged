import ApelinProtocol
import Foundation

/// Measures every enabled, signed-in, non-excluded model once and returns the
/// one that answered fastest. Used by Settings ▸ Auto Assistant ▸ Measure Models.
///
/// The probe is the same bounded `agentModelTest` the connectivity screen
/// uses: one short message, no history, no tools. Its final report carries a
/// `total` stage; smaller is faster. Models the reader excluded, and whole
/// excluded providers, are never probed. Probes run one at a time: a burst of
/// parallel first messages is harder on a provider than a short queue, and the
/// sequential order gives the progress its count.
///
/// Every model that was tried gets a `Result` — including the ones that timed
/// out or failed. The results page can then show the whole list, while the
/// automatic assistant deliberately picks only from the successful ones.
enum ModelSpeedPicker {
    /// A model that has not answered in this long is skipped: a relay that
    /// hangs would otherwise hold the whole measurement, and a model slow
    /// enough to matter is not the fastest one anyway.
    static let probeTimeout = Duration.seconds(10)

    /// A model's speed, kept beside the selection it belongs to. `success`
    /// says whether it answered; a failed probe keeps its reason so the
    /// results page can say what happened. Automatic switching only ever
    /// picks a result with `success == true`.
    struct Result: Codable {
        var selection: ComposerModelSelection
        var milliseconds: Double
        var success: Bool
        var failure: String?

        init(selection: ComposerModelSelection, milliseconds: Double,
             success: Bool = true, failure: String? = nil) {
            self.selection = selection
            self.milliseconds = milliseconds
            self.success = success
            self.failure = failure
        }

        private enum CodingKeys: String, CodingKey {
            case selection, milliseconds, success, failure
        }

        /// Measurements saved before `success`/`failure` existed held only
        /// models that answered, so read them as successful. Without this a
        /// saved measurement would not decode at all and the automatic
        /// assistant would be left with no candidates.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            selection = try values.decode(ComposerModelSelection.self, forKey: .selection)
            milliseconds = try values.decode(Double.self, forKey: .milliseconds)
            success = try values.decodeIfPresent(Bool.self, forKey: .success) ?? true
            failure = try values.decodeIfPresent(String.self, forKey: .failure)
        }
    }

    /// One probe's answer: the total time when it answered, otherwise why it
    /// did not. Both go into a `Result` so the results page can say what
    /// happened to every model.
    private struct Probe: Sendable {
        var milliseconds: Double? = nil
        var success: Bool
        var failure: String? = nil
    }

    static func pickFastest(
        progress: @MainActor (_ measured: Int, _ total: Int) -> Void = { _, _ in },
    ) async throws -> ComposerModelSelection? {
        try await measureAll(progress: progress).fastest
    }

    /// 所有已登录、未被排除的账号及其可用模型。测速和自动切换共用这份
    /// 候选：不再跟「手动启用」列表取交集——那会让从没手动启用过的人只剩
    /// 零星几个模型可测、可切。范围只由排除的服务商与排除的模型决定。
    static func availableAccounts() async throws -> [AgentAccount] {
        let listed = try await ApelinService.app.agentAccountsWithKnownModels()
        guard !Task.isCancelled else { throw CancellationError() }
        return listed.compactMap { account in
            guard account.signedIn else { return nil }
            let usable = (account.models ?? []).filter {
                !ModelExclusions.isModelExcluded(account.provider, model: $0)
            }
            guard !usable.isEmpty else { return nil }
            var available = account
            available.models = usable
            return available
        }
    }

    /// 每个候选模型各测一次，返回完整结果（成功的快到慢在前，失败的在后）
    /// 与其中最快者。结果留盘给「上次测量」页与自动切换共用；`fastest` 只
    /// 从成功的里取，绝不会是一个没应答的模型。
    static func measureAll(
        progress: @MainActor (_ measured: Int, _ total: Int) -> Void = { _, _ in },
    ) async throws -> (results: [Result], fastest: ComposerModelSelection?) {
        let accounts = try await availableAccounts()

        var candidates: [(account: AgentAccount, model: String)] = []
        for account in accounts {
            for model in account.models ?? [] {
                candidates.append((account, model))
            }
        }
        guard !candidates.isEmpty else { return ([], nil) }

        var measured: [Result] = []
        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            await progress(index, candidates.count)
            let probe = await measure(candidate.account, model: candidate.model)
            var selection = ComposerModelSelection(
                provider: candidate.account.provider,
                storeID: candidate.account.storeID,
                model: candidate.model,
                supportedEfforts: candidate.account.reasoningEfforts?[candidate.model] ?? [],
                supportedTiers: candidate.account.serviceTiers?[candidate.model],
            )
            selection.conversationScoped = nil
            selection.preferredEffort = nil
            selection.preferredTier = nil
            measured.append(Result(
                selection: selection,
                milliseconds: probe.milliseconds ?? 0,
                success: probe.success,
                failure: probe.failure,
            ))
        }
        measured.sort { a, b in
            if a.success != b.success { return a.success }
            guard a.success else { return false }
            return a.milliseconds < b.milliseconds
        }
        await progress(candidates.count, candidates.count)
        return (measured, measured.first(where: { $0.success })?.selection)
    }

    /// The total time of one successful probe, or — when it failed, reported
    /// no total, or outran `probeTimeout` — why it did not answer.
    private static func measure(_ account: AgentAccount, model: String) async -> Probe {
        do {
            let handle = try await ApelinService.app.agentModelTest(
                AgentModelTestRequest(provider: account.provider, accountID: account.storeID, model: model)
            )
            return await withTaskGroup(of: Probe.self) { group in
                group.addTask {
                    do {
                        for try await event in ApelinService.app.events(of: handle) {
                            if Task.isCancelled { return Probe(success: false) }
                            guard event.kind == TaskEvent.stateKind,
                                  let state = event.payload?["state"]?.stringValue.flatMap(TaskState.init(rawValue:)),
                                  state.isTerminal
                            else { continue }
                            guard let value = event.payload?[AgentModelTestResponse.stateMember],
                                  let report = try? value.decode(AgentModelTestResponse.self)
                            else {
                                return Probe(success: false, failure: event.payload?["message"]?.stringValue)
                            }
                            guard report.success,
                                  let total = report.stages.first(where: { $0.name == .total })?.milliseconds,
                                  total.isFinite, total > 0
                            else { return Probe(success: false, failure: report.failure) }
                            return Probe(milliseconds: total, success: true)
                        }
                        return Probe(success: false)
                    } catch {
                        return Probe(success: false, failure: error.readableMessage)
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: probeTimeout)
                    return Probe(success: false, failure: String(localized: "Measurement Timed Out"))
                }
                let first = await group.next() ?? Probe(success: false)
                group.cancelAll()
                return first
            }
        } catch {
            return Probe(success: false, failure: error.readableMessage)
        }
    }
}
