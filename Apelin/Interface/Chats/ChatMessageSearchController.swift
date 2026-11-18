import ApelinCore
import UIKit

/// One conversation's messages, narrowed by the words the reader types.
/// A result is the message as the reader wrote or read it; picking one closes
/// this page and the conversation scrolls to that row, so a search is a way
/// to get somewhere, not a second transcript to keep.
final class ChatMessageSearchController: TableController, UISearchResultsUpdating {
    private struct Hit {
        let id: UUID
        let role: String
        let text: String
    }

    private let messages: [(id: UUID, role: String, text: String)]
    private let onPick: (UUID) -> Void
    private let search = UISearchController(searchResultsController: nil)
    private var hits: [Hit] = []
    private static let identifier = "message"

    init(messages: [(id: UUID, role: String, text: String)], onPick: @escaping (UUID) -> Void) {
        self.messages = messages
        self.onPick = onPick
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(messages:onPick:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Search in Conversation")
        navigationItem.largeTitleDisplayMode = .never
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search Messages")
        search.searchBar.autocapitalizationType = .none
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.identifier)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        search.searchBar.becomeFirstResponder()
    }

    @objc dynamic func updateSearchResults(for searchController: UISearchController) {
        let query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { hits = []; tableView.reloadData(); return }
        // Best first: a message that starts with the words, or names one word
        // exactly, rises above a long reply that merely mentions it. Ties keep
        // the transcript's own order.
        hits = SearchScorer.ranked(messages, query: query, text: { $0.text }).map { message, _ in
            Hit(id: message.id, role: message.role, text: message.text)
        }
        tableView.reloadData()
    }

    override func numberOfSections(in _: UITableView) -> Int { 1 }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        hits.count
    }

    override func tableView(_ table: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = table.dequeueReusableCell(withIdentifier: Self.identifier, for: indexPath)
        let hit = hits[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = hit.text
        content.textProperties.numberOfLines = 3
        content.secondaryText = hit.role
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ table: UITableView, didSelectRowAt indexPath: IndexPath) {
        table.deselectRow(at: indexPath, animated: true)
        let id = hits[indexPath.row].id
        dismiss(animated: true) { [weak self] in self?.onPick(id) }
    }
}
