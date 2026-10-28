import AppKit
import SwiftUI

struct AccountEditor: View {
    let store: UsageStore
    /// Closes the hosting window.
    let close: () -> Void
    @State private var rows: [Row] = []
    @State private var error: String?
    @State private var loaded = false
    @State private var originalData: Data?
    @State private var originalAccounts: [AccountConfig] = []
    @State private var saving = false
    @State private var selection: UUID?

    private let sampleMode: Bool

    init(store: UsageStore, sampleAccounts: [AccountConfig]? = nil, close: @escaping () -> Void = {}) {
        self.store = store
        self.close = close
        sampleMode = sampleAccounts != nil
        // Load before the first frame so the window doesn't redraw from an empty state as it opens.
        var accounts = sampleAccounts ?? []
        var loadError: String?
        if sampleAccounts == nil {
            do {
                accounts = try AppConfig.load()
                _originalData = State(initialValue: try Data(contentsOf: URL(fileURLWithPath: AppConfig.path)))
            } catch {
                loadError = "Could not load accounts: \(error.localizedDescription)"
            }
        }
        let initialRows = accounts.map { Row(account: $0) }
        _rows = State(initialValue: initialRows)
        _originalAccounts = State(initialValue: accounts)
        _selection = State(initialValue: initialRows.first?.id)
        _loaded = State(initialValue: loadError == nil)
        _error = State(initialValue: loadError)
    }

    private struct Row: Identifiable {
        let id = UUID()
        var account: AccountConfig
    }

    /// Consecutive rows that share a group, the same runs the dropdown shows under one heading.
    private struct Section: Identifiable {
        /// Distinct from the row IDs, which the list uses as selection tags.
        let id: String
        let title: String?
        let rows: [Row]
    }

    private var sections: [Section] {
        var result: [Section] = []
        for row in rows {
            let title = row.account.group.flatMap { $0.isEmpty ? nil : $0 }
            if let last = result.last, last.title == title {
                result[result.count - 1] = Section(id: last.id, title: title, rows: last.rows + [row])
            } else {
                result.append(Section(id: "section-\(row.id)", title: title, rows: [row]))
            }
        }
        return result
    }

    private var hasChanges: Bool { rows.map(\.account) != originalAccounts }
    private var hasProblems: Bool { rows.contains { problem(for: $0) != nil } }

    var body: some View {
        // The split view is the window's root so the sidebar and toolbar span the title bar.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .frame(width: 240)
                .navigationSplitViewColumnWidth(240)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                .bottomBar { footer }
                // One surface from the title bar down, instead of a darker strip above the form.
                .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
                .hiddenToolbarBackground()
        }
        .navigationTitle("Accounts")
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 560)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(sections) { section in
                SwiftUI.Section {
                    ForEach(section.rows) { row in
                        sidebarRow(row).tag(row.id)
                            .contextMenu {
                                Button("Remove", role: .destructive) { remove(row.id) }
                            }
                    }
                } header: {
                    if let title = section.title { Text(title) }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Accounts")
        .onDeleteCommand { if let selection { remove(selection) } }
        .disabled(saving)
        .softScrollEdges()
        .bottomBar { sidebarFooter }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 2) {
            Menu {
                Button { add(.claude) } label: { Text("Claude") }
                Button { add(.codex) } label: { Text("Codex") }
            } label: {
                Image(systemName: "plus").frame(width: 22, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add an account")
            .accessibilityLabel("Add account")
            .disabled(!loaded || saving)
            Button {
                if let selection { remove(selection) }
            } label: {
                Image(systemName: "minus").frame(width: 22, height: 20)
            }
            .buttonStyle(.borderless)
            .help("Remove the selected account")
            .accessibilityLabel("Remove account")
            .disabled(selection == nil || saving)
            Spacer()
            Text(rows.count == 1 ? "1 account" : "\(rows.count) accounts")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .lineLimit(1).fixedSize()
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: AppConfig.path))
            } label: {
                Image(systemName: "doc.text").frame(width: 22, height: 20)
            }
            .buttonStyle(.borderless)
            .help("Open the config file")
            .accessibilityLabel("Open config file")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private func sidebarRow(_ row: Row) -> some View {
        HStack(spacing: 10) {
            ProviderIconView(provider: row.account.provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.account.name.isEmpty ? "New account" : row.account.name)
                    .lineLimit(1)
                Text(row.account.dir.isEmpty ? "No login directory" : row.account.dir)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if problem(for: row) != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(problem(for: row) ?? "")
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let index = rows.firstIndex(where: { $0.id == selection }) {
            accountDetails($rows[index])
                .id(rows[index].id)
        } else if !loaded, let error {
            ContentUnavailableView {
                Label("Couldn’t load accounts", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error).textSelection(.enabled)
            }
        } else {
            ContentUnavailableView {
                Label(rows.isEmpty ? "No accounts yet" : "No account selected",
                      systemImage: "person.crop.circle.badge.plus")
            } description: {
                Text(rows.isEmpty ? "Add a Claude or Codex login to track its usage in the menu bar."
                     : "Select an account in the sidebar to edit it.")
            } actions: {
                if rows.isEmpty && loaded {
                    HStack {
                        Button("Add Claude") { add(.claude) }
                        Button("Add Codex") { add(.codex) }
                    }
                }
            }
        }
    }

    private func accountDetails(_ row: Binding<Row>) -> some View {
        let account = row.wrappedValue.account
        return Form {
            SwiftUI.Section {
                HStack(spacing: 14) {
                    ProviderIconView(provider: account.provider, height: 22)
                        .frame(width: 48, height: 48)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.name.isEmpty ? "New account" : account.name)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        status(for: account)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { remove(row.wrappedValue.id) }
                        .help("Remove this account from AI Usage")
                }
                .padding(.vertical, 4)
            }

            if let error {
                SwiftUI.Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SwiftUI.Section {
                TextField("Display name", text: row.account.name, prompt: Text("e.g. Claude Work"))
                TextField("Group", text: optional(row.account.group), prompt: Text("Optional, e.g. Work"))
            } footer: {
                footnote("Accounts in the same group sit together; a dot separates groups in the menu bar.")
            }

            SwiftUI.Section {
                Picker("Provider", selection: provider(row)) {
                    Text("Claude").tag(Provider.claude)
                    Text("Codex").tag(Provider.codex)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                LabeledContent("Login directory") {
                    HStack(spacing: 8) {
                        TextField("Login directory", text: row.account.dir,
                                  prompt: Text(defaultDir(account.provider)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .font(.body.monospaced())
                        Button("Choose…") { chooseDirectory(row) }
                            .controlSize(.small)
                    }
                }
            } footer: {
                if let problem = problem(for: row.wrappedValue) {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    footnote(account.provider == .claude
                             ? "The folder Claude Code uses as CLAUDE_CONFIG_DIR."
                             : "The folder Codex uses as CODEX_HOME.")
                }
            }

            if account.provider == .claude {
                SwiftUI.Section {
                    TextField("Keychain service", text: optional(row.account.keychainService),
                              prompt: Text("Default"))
                } header: {
                    Text("Advanced")
                } footer: {
                    footnote("Leave blank unless this login stores its token under a custom keychain service.")
                }
            }

        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .softScrollEdges()
        .disabled(saving)
    }

    /// The account's result from the last refresh; edits that change its name or folder clear it.
    @ViewBuilder
    private func status(for account: AccountConfig) -> some View {
        let state = store.states[account.id]
        HStack(spacing: 6) {
            Circle().frame(width: 7, height: 7)
                .foregroundStyle(state?.snapshot != nil ? Color.green : state?.error != nil ? .red : .secondary.opacity(0.5))
            Group {
                if let snapshot = state?.snapshot {
                    Text([snapshot.identity, snapshot.plan].compactMap { $0 }.joined(separator: " · ")
                         .nonEmpty ?? "Signed in")
                } else if let error = state?.error {
                    Text(error)
                } else {
                    Text(originalAccounts.contains(account) ? "Not checked yet" : "Checked after you save")
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.tail)
        }
        .help(state?.error ?? "")
    }

    private func footnote(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Group {
                if store.isRefreshing {
                    ProgressView().controlSize(.mini)
                    Text("Waiting for the current refresh…")
                } else if hasProblems {
                    Text("Fix the highlighted accounts to save.")
                } else if hasChanges {
                    Text("Unsaved changes")
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            Button("Cancel") { close() }
                .keyboardShortcut(.cancelAction)
            Button(saving ? "Saving…" : "Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!loaded || saving || store.isRefreshing || !hasChanges || hasProblems)
        }
        .controlSize(.large)
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: - Editing

    private func problem(for row: Row) -> String? {
        let account = row.account
        if account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a display name." }
        if account.dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a login directory." }
        if rows.contains(where: { $0.id != row.id && $0.account.id == account.id }) {
            return "Another account has the same name and login directory."
        }
        return nil
    }

    private func defaultDir(_ provider: Provider) -> String {
        provider == .claude ? "~/.claude" : "~/.codex"
    }

    /// Switching provider also switches the folder while it is still the other provider's default.
    private func provider(_ row: Binding<Row>) -> Binding<Provider> {
        Binding(get: { row.wrappedValue.account.provider }, set: { provider in
            let account = row.wrappedValue.account
            if account.dir == defaultDir(account.provider) { row.wrappedValue.account.dir = defaultDir(provider) }
            if account.name == account.provider.rawValue.capitalized {
                row.wrappedValue.account.name = provider.rawValue.capitalized
            }
            row.wrappedValue.account.provider = provider
        })
    }

    private func chooseDirectory(_ row: Binding<Row>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder containing this account’s CLI login."
        let current = row.wrappedValue.account.expandedDir
        panel.directoryURL = URL(fileURLWithPath: current.isEmpty ? NSHomeDirectory() : current)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = NSHomeDirectory()
        let path = url.path
        row.wrappedValue.account.dir = path == home ? "~"
            : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func add(_ provider: Provider) {
        // New accounts join the selected account's group, right after it.
        let selected = rows.firstIndex { $0.id == selection }
        let row = Row(account: AccountConfig(
            name: provider.rawValue.capitalized, group: selected.flatMap { rows[$0].account.group },
            provider: provider, dir: defaultDir(provider)))
        rows.insert(row, at: selected.map { $0 + 1 } ?? rows.endIndex)
        selection = row.id
    }

    private func remove(_ id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows.remove(at: index)
        selection = rows.isEmpty ? nil : rows[min(index, rows.count - 1)].id
    }

    private func save() {
        guard !sampleMode else { return }
        do {
            let current = try Data(contentsOf: URL(fileURLWithPath: AppConfig.path))
            guard current == originalData else {
                error = "The config changed outside this window. Close and reopen Accounts to load those changes."
                return
            }
            try AppConfig.save(rows.map(\.account))
            saving = true
            Task {
                await store.refresh()
                saving = false
                close()
            }
        } catch {
            self.error = (error as? FetchError)?.description ?? error.localizedDescription
        }
    }
}

private extension View {
    /// A bar pinned under scrolling content: the system scroll-edge bar on macOS 26, a divider before.
    @ViewBuilder
    func bottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(macOS 26.0, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: bar)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    bar()
                }
                .background(.bar)
            }
        }
    }

    /// Lets the form run up under the title bar, as in System Settings, instead of a separate strip.
    @ViewBuilder
    func hiddenToolbarBackground() -> some View {
        if #available(macOS 15.0, *) {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }

    @ViewBuilder
    func softScrollEdges() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
