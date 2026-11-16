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
    /// A model's speed, kept beside the selection it belongs to.
    struct Result {
        var selection: ComposerModelSelection
        var milliseconds: Double
    }

    static func pickFastest(
        progress: @MainActor (_ measured: Int, _ total: Int) -> Void = { _, _ in },
    ) async throws -> ComposerModelSelection? {
        let selected = EnabledModels.selectedModelIDs()
        let listed = try await ApelinService.app
            .agentAccountList(extraModels: selected, onlyExtraModels: true).accounts
        guard !Task.isCancelled else { throw CancellationError() }
        let accounts = EnabledModels.accounts(from: listed)

        var candidates: [(account: AgentAccount, model: String)] = []
        for account in accounts {
            for model in account.models ?? [] {
                guard !ModelExclusions.isModelExcluded(account.provider, model: model) else { continue }
                candidates.append((account, model))
            }
        }
        guard !candidates.isEmpty else { return nil }

        var fastest: Result?
        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            await progress(index, candidates.count)
            guard let milliseconds = try? await measure(candidate.account, model: candidate.model),
                  milliseconds.isFinite, milliseconds > 0
            else { continue }
            if fastest == nil || milliseconds < fastest!.milliseconds {
                var selection = ComposerModelSelection(
                    provider: candidate.account.provider,
                    model: candidate.model,
                    supportedEfforts: candidate.account.reasoningEfforts?[candidate.model] ?? [],
                    supportedTiers: candidate.account.serviceTiers?[candidate.model],
                )
                selection.conversationScoped = nil
                selection.preferredEffort = nil
                selection.preferredTier = nil
                fastest = Result(selection: selection, milliseconds: milliseconds)
            }
        }
        await progress(candidates.count, candidates.count)
        return fastest?.selection
    }

    /// The total time of one successful probe, or nil when it failed or the
    /// report held no total stage.
    private static func measure(_ account: AgentAccount, model: String) async throws -> Double? {
        let handle = try await ApelinService.app.agentModelTest(
            AgentModelTestRequest(provider: account.provider, model: model)
        )
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
}
