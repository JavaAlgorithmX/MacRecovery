import SwiftUI
import RecoveryCore

struct ResultsView: View {
    @EnvironmentObject var vm: ScanViewModel

    // Sidebar selection — nil = All Files
    @State private var selectedCategory: FileCategory? = nil

    // Detail selection — keyed by UUID so FileCandidate doesn't need Hashable
    @State private var selectedCandidateID: UUID? = nil
    private var selectedCandidate: FileCandidate? {
        guard let id = selectedCandidateID else { return nil }
        return vm.result?.candidates.first { $0.id == id }
    }

    // Recovery queue
    @State private var queuedIDs: Set<UUID> = []

    // Search + filter
    @State private var searchText = ""
    @State private var minScore: RecoverabilityScore = .low

    // Sheets
    @State private var showRecovery  = false
    @State private var showSortMenu  = false

    // Sort
    @State private var sortOrder: RecoveryCore.SortOrder = .recoverability
    @State private var sortAscending        = false

    // MARK: - Filtered candidates

    private var candidates: [FileCandidate] {
        guard let index = vm.candidateIndex else { return [] }
        let q = CandidateQuery(
            nameContains: searchText.isEmpty ? nil : searchText,
            categories:   selectedCategory.map { [$0] },
            minScore:     minScore == .low ? nil : minScore,
            sortBy:       sortOrder,
            ascending:    sortAscending
        )
        return index.search(query: q)
    }

    // MARK: - Body

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
        } content: {
            contentColumn
                .navigationSplitViewColumnWidth(min: 290, ideal: 360)
        } detail: {
            detailColumn
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showRecovery) {
            if let result = vm.result {
                let queued = result.candidates.filter { queuedIDs.contains($0.id) }
                RecoverySheet(candidates: queued)
                    .environmentObject(vm)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedCategory) {
            // All Files row
            Label {
                HStack {
                    Text("All Files")
                    Spacer()
                    Text("\(vm.result?.candidates.count ?? 0)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "tray.full.fill")
                    .foregroundStyle(.mrTeal)
            }
            .tag(Optional<FileCategory>.none)

            if let summary = vm.summary, !summary.groups.isEmpty {
                Section("By Category") {
                    ForEach(summary.groups, id: \.category) { group in
                        Label {
                            HStack {
                                Text(group.category.rawValue)
                                Spacer()
                                Text("\(group.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: group.category.symbolName)
                                .foregroundStyle(group.category.tintColor)
                        }
                        .tag(Optional(group.category))
                    }
                }
            }

            if let result = vm.result, !result.badSectors.isEmpty {
                Section("Diagnostics") {
                    Label {
                        Text("\(result.badSectors.count) bad sector\(result.badSectors.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.mrAmber)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("MacRecovery")
    }

    // MARK: - Content (file list)

    private var contentColumn: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            scoreFilter
            Divider()
            fileList
        }
        .navigationTitle(selectedCategory?.rawValue ?? "All Files")
        .navigationSubtitle("\(candidates.count) file\(candidates.count == 1 ? "" : "s")")
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            TextField("Search files…", text: $searchText)
                .textFieldStyle(.plain)

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var scoreFilter: some View {
        HStack(spacing: 6) {
            Text("Min score")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach([RecoverabilityScore.low, .medium, .high, .certain], id: \.self) { score in
                Button(action: {
                    withAnimation(.spring(response: 0.2)) { minScore = score }
                }) {
                    Text(score.label)
                        .font(.caption.bold())
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(minScore == score ? score.tintColor : Color.primary.opacity(0.06))
                        .foregroundStyle(minScore == score ? Color.white : Color.secondary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Sort picker
            Menu {
                Picker("Sort by", selection: $sortOrder) {
                    Label("Recoverability", systemImage: "checkmark.seal").tag(RecoveryCore.SortOrder.recoverability)
                    Label("Name",           systemImage: "textformat.abc").tag(RecoveryCore.SortOrder.name)
                    Label("Size",           systemImage: "arrow.up.arrow.down").tag(RecoveryCore.SortOrder.size)
                    Label("Date",           systemImage: "calendar").tag(RecoveryCore.SortOrder.date)
                }
                Divider()
                Toggle("Ascending", isOn: $sortAscending)
            } label: {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 22)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.mrSurface)
    }

    private var fileList: some View {
        Group {
            if candidates.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "doc.badge.questionmark")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary.opacity(0.4))
                    Text("No matching files")
                        .foregroundStyle(.secondary)
                    if !searchText.isEmpty {
                        Button("Clear search") { searchText = "" }
                            .font(.caption)
                            .foregroundStyle(.mrTeal)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedCandidateID) {
                    ForEach(candidates) { candidate in
                        CandidateRow(
                            candidate: candidate,
                            isQueued:  queuedIDs.contains(candidate.id)
                        )
                        .tag(candidate.id)
                        .listRowInsets(.init(top: 5, leading: 10, bottom: 5, trailing: 10))
                        .contextMenu {
                            Button {
                                if queuedIDs.contains(candidate.id) {
                                    queuedIDs.remove(candidate.id)
                                } else {
                                    queuedIDs.insert(candidate.id)
                                }
                            } label: {
                                Label(
                                    queuedIDs.contains(candidate.id) ? "Remove from Queue" : "Add to Queue",
                                    systemImage: queuedIDs.contains(candidate.id) ? "minus.circle" : "plus.circle"
                                )
                            }
                            Divider()
                            Button {
                                selectedCandidateID = candidate.id
                            } label: {
                                Label("Preview", systemImage: "eye")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Detail panel

    private var detailColumn: some View {
        Group {
            if let candidate = selectedCandidate {
                PreviewPanelView(
                    candidate:       candidate,
                    previewProvider: vm.previewProvider,
                    isQueued:        queuedIDs.contains(candidate.id)
                ) {
                    withAnimation(.spring(response: 0.2)) {
                        if queuedIDs.contains(candidate.id) {
                            queuedIDs.remove(candidate.id)
                        } else {
                            queuedIDs.insert(candidate.id)
                        }
                    }
                }
            } else {
                detailPlaceholder
            }
        }
    }

    private var detailPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 44))
                .foregroundStyle(.secondary.opacity(0.3))
            Text("Select a file to preview")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectBackground(material: .sidebar).ignoresSafeArea())
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: vm.resetToStart) {
                Label("New Scan", systemImage: "arrow.counterclockwise")
            }
            .help("Return to drive selection")
        }

        ToolbarItemGroup {
            if !queuedIDs.isEmpty {
                Text("\(queuedIDs.count) queued")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(action: {
                let all = vm.result?.candidates.map(\.id) ?? []
                if queuedIDs.count == all.count {
                    queuedIDs.removeAll()
                } else {
                    queuedIDs = Set(all)
                }
            }) {
                Label("Select All", systemImage: "checkmark.circle")
            }

            Button(action: { showRecovery = true }) {
                Label("Recover \(queuedIDs.isEmpty ? "…" : "\(queuedIDs.count) Files")",
                      systemImage: "arrow.down.doc.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.mrTeal)
            .disabled(queuedIDs.isEmpty)
        }
    }
}
