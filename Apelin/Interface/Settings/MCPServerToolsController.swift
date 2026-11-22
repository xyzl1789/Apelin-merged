import ApelinProtocol
import Then
import UIKit

/// Live read-only tools/list for one configured MCP server.
final class MCPServerToolsController: UITableViewController {
    private let serverName: String
    private var tools: [AgentMCPToolSummary] = []
    private var errorText: String?
    private var isLoading = false

    init(serverName: String) {
        self.serverName = serverName
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(serverName:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = serverName
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: String(localized: "Done"), style: .done, target: self, action: #selector(done),
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            primaryAction: UIAction { [weak self] _ in self?.refresh() },
        ).then { $0.accessibilityLabel = String(localized: "Refresh Tool List") }
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "tool")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 76
        refresh()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if isLoading || errorText != nil || tools.isEmpty { return 1 }
        return tools.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "tool", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        if isLoading {
            content.text = String(localized: "Connecting and fetching tools…")
            content.image = UIImage(systemName: "arrow.triangle.2.circlepath")
        } else if let errorText {
            content.text = errorText
            content.image = UIImage(systemName: "exclamationmark.triangle.fill")
            content.imageProperties.tintColor = .systemOrange
        } else if tools.isEmpty {
            content.text = String(localized: "The server reported no tools.")
            content.textProperties.color = .secondaryLabel
        } else {
            let tool = tools[indexPath.row]
            content.text = tool.name
            content.secondaryText = tool.description
            content.textProperties.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
            content.secondaryTextProperties.numberOfLines = 3
        }
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }

    private func refresh() {
        guard !isLoading else { return }
        isLoading = true
        errorText = nil
        tools = []
        tableView.reloadData()
        Task { [weak self] in
            do {
                let response = try await ApelinService.app.agentMCPTools(serverName: serverName)
                guard let self else { return }
                tools = response.tools
                isLoading = false
                tableView.reloadData()
            } catch {
                guard let self else { return }
                errorText = error.readableMessage
                isLoading = false
                tableView.reloadData()
            }
        }
    }

    @objc private func done() { dismiss(animated: true) }
}
