import ApelinProtocol

/// How a model is written on screen.
///
/// The provider's own id is what a conversation sends and what every row would
/// otherwise show — `cn:deepseek-v4.1-flash` for the model the catalogs call
/// DeepSeek V4.1 Flash. Where a catalog knows the model, its name is the one a
/// reader sees and the id sits under it, unchanged: nothing is renamed on the
/// wire, and a model no catalog names keeps its id alone.
extension AgentModelCapabilities {
    /// The catalog's name for `model`, unless it only spells the id again.
    func displayName(for model: String) -> String? {
        guard let title = catalogTitle, !title.isEmpty,
              title.caseInsensitiveCompare(model) != .orderedSame
        else { return nil }
        return title
    }
}

extension AgentAccount {
    /// What the catalog calls `model`, when one knows it in words.
    func catalogTitle(for model: String) -> String? {
        capabilities?[model]?.displayName(for: model)
    }

    /// The model as a reader reads it: the catalog's name, or its own id.
    func displayName(for model: String) -> String {
        catalogTitle(for: model) ?? model
    }

    /// The abilities a catalog knows, in the order a row shows them. Only
    /// affirmative ones: a missing `false` is a catalog that did not say, and
    /// a badge claiming a model cannot see would be a worse lie than none.
    /// The input modalities models.dev lists drive the badges; a catalog that
    /// only said `acceptsImages` gets the two basic ones.
    func abilityBadges(for model: String) -> [AbilityBadge] {
        guard let ability = capabilities?[model] else { return [] }
        var badges: [AbilityBadge] = []
        let modalities = Set((ability.inputModalities ?? []).map { $0.lowercased() })
        if !modalities.isEmpty {
            for badge in AbilityBadge.modalityOrder where modalities.contains(badge.modality ?? "") {
                badges.append(badge)
            }
        } else if ability.acceptsImages == true {
            badges = [.text, .vision]
        }
        if ability.reasoning == true { badges.append(.reasoning) }
        return badges
    }

    enum AbilityBadge: Sendable {
        case text
        case vision
        case video
        case document
        case audio
        case reasoning

        /// The modality a badge answers to; reasoning is a property, not an
        /// input type, so it has none and is added on its own.
        var modality: String? {
            switch self {
            case .text: "text"
            case .vision: "image"
            case .video: "video"
            case .document: "pdf"
            case .audio: "audio"
            case .reasoning: nil
            }
        }

        /// The order the badges appear in, whatever order the catalog listed
        /// the modalities, so a row does not reshuffle between refreshes.
        static let modalityOrder: [AbilityBadge] = [.text, .vision, .video, .document, .audio]

        /// The symbol drawn beside the model's name.
        var symbolName: String {
            switch self {
            case .text: "text.bubble"
            case .vision: "eye"
            case .video: "video"
            case .document: "doc.text"
            case .audio: "mic.fill"
            case .reasoning: "brain"
            }
        }

        /// The spoken name, so an icon-only mark never goes unnamed.
        var label: String {
            switch self {
            case .text: String(localized: "Text")
            case .vision: String(localized: "Vision")
            case .video: String(localized: "Video")
            case .document: String(localized: "Document")
            case .audio: String(localized: "Audio")
            case .reasoning: String(localized: "Reasoning")
            }
        }
    }
}
