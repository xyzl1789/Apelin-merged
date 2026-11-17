import ApelinProtocol
import Foundation

/// Measures every enabled, signed-in, non-excluded model once and returns the
/// one that answered fastest. Used by Settings ▸ Auto Assistant ▸ Measure Now.
///
/// The probe is the same bounded `agentModelTest` the connectivity screen
/// uses: one short message, no history, no tools. Its final report carries a
/// `total` stage; smaller is faster. Only successful probes rank. Models the
/// reader excluded, and whole excluded providers, are never probed — so the
/// choice always honours the exclusions the send path does. Probes run one at
/// a time: a burst of parallel first messages is harder on a provider than a
/// short queue, and the sequential order gives the progress card a count.
enum ModelSpeedPicker {
    /// A model that has not answered in this long is skipped: a relay that
    /// hangs would otherwise hold the whole measurement, and a model slow
    /// enough to matter is not the fastest one anyway.
    static let probeTimeout = Duration.seconds(10)

    /// A model's speed, kept beside the selection it belongs to.
    struct Result: Codable {
        var selection: ComposerModelSelection
        var milliseconds: Double
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

    /// 每个候选模型各测一次，返回完整排名（快到慢，失败的除外）与最快者。
    /// 排名留在原地供「测量结果」页读取；`Result` 的 Selection 也照旧带出。
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
            guard let milliseconds = try? await measure(candidate.account, model: candidate.model),
                  milliseconds.isFinite, milliseconds > 0
            else { continue }
            var selection = ComposerModelSelection(
                provider: candidate.account.provider,
                model: candidate.model,
                supportedEfforts: candidate.account.reasoningEfforts?[candidate.model] ?? [],
                supportedTiers: candidate.account.serviceTiers?[candidate.model],
            )
            selection.conversationScoped = nil
            selection.preferredEffort = nil
            selection.preferredTier = nil
            measured.append(Result(selection: selection, milliseconds: milliseconds))
        }
        measured.sort { $0.milliseconds < $1.milliseconds }
        await progress(candidates.count, candidates.count)
        return (measured, measured.first?.selection)
    }

    /// The total time of one successful probe, or nil when it failed, the
    /// report held no total stage, or the probe outran `probeTimeout`.
    private static func measure(_ account: AgentAccount, model: String) async throws -> Double? {
        let handle = try await ApelinService.app.agentModelTest(
            AgentModelTestRequest(provider: account.provider, model: model)
        )
        return try await withThrowingTaskGroup(of: Double?.self) { group in
            // Raced against a timer that answers nil: a stream that stops
            // sending events (a relay holding the connection open) says
            // nothing, so the cap cannot wait for the next event. The probe
            // task keeps running on the host after we stop reading it;
            // dropping the stream is the only cancel a model test has, and the
            // next probe starts at once.
            group.addTask {
                for try await event in ApelinService.app.events(of: handle) {
                    if Task.isCancelled { return nil }
                    guard event.kind == TaskEvent.stateKind,
                          let state = event.payload?["state"]?.stringValue.flatMap(TaskState.init(rawValue:)),
                          state.isTerminal
                    else { continue }
                    guard let value = event.payload?[AgentModelTestResponse.stateMember],
                          let report = try? value.decode(AgentModelTestResponse.self),
                          report.success,
                          let total = report.stages.first(where: { $0.name == .total })?.milliseconds
                    else { return nil }
                    return total
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: probeTimeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
