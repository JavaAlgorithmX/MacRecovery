import SwiftUI
import RecoveryCore

// MARK: - View mode

private enum ResultsViewMode { case list, grid }
private enum ResultsSidebarMode { case path, type }

// MARK: - ResultsView
// Matches UI-Plan screens 5, 6, 8, 9:
//   sidebar (Path/Type) · breadcrumb · list/grid content · right detail panel

struct ResultsView: View {
    @EnvironmentObject var vm: ScanViewModel

    // Sidebar
    @State private var sidebarMode: ResultsSidebarMode = .type
    @State private var selectedCategory: FileCategory? = nil

    // File selection
    @State private var selectedCandidateID: UUID?   = nil
    @State private var queuedIDs:           Set<UUID> = []

    // View mode
    @State private var viewMode: ResultsViewMode = .grid

    // Filter / search
    @State private var showFilters  = false
    @State private var searchText   = ""
    @State private var sortOrder:   RecoveryCore.SortOrder = .recoverability
    @State private var sortAscending = false

    // Recovery sheet
    @State private var showRecovery = false

    // MARK: Derived

    private var selectedCandidate: FileCandidate? {
        guard let id = selectedCandidateID else { return nil }
        return vm.result?.candidates.first { $0.id == id }
    }

    private var displayedCandidates: [FileCandidate] {
        guard let index = vm.candidateIndex else { return [] }
        let categories: Set<FileCategory>? = selectedCategory.map { Set([$0]) }
        let q = CandidateQuery(
            nameContains: searchText.isEmpty ? nil : searchText,
            categories:   categories,
            minScore:     nil,
            sortBy:       sortOrder,
            ascending:    sortAscending
        )
        return index.search(query: q)
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbBar
            if showFilters {
                filterBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Divider()

            HStack(spacing: 0) {
                resultsSidebar
                Divider()
                mainContent
                if selectedCandidate != nil || selectedCategory != nil {
                    Divider()
                    detailPanel
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(VisualEffectBackground().ignoresSafeArea())
        .animation(.easeInOut(duration: 0.18), value: showFilters)
        .animation(.easeInOut(duration: 0.18), value: selectedCandidate?.id)
        .sheet(isPresented: $showRecovery) {
            if let result = vm.result {
                let queued = queuedIDs.isEmpty
                    ? result.candidates
                    : result.candidates.filter { queuedIDs.contains($0.id) }
                RecoverySheet(candidates: queued)
                    .environmentObject(vm)
            }
        }
    }

    // MARK: - Breadcrumb bar

    private var breadcrumbBar: some View {
        HStack(spacing: 6) {
            // Back to home
            Button(action: vm.resetToStart) {
                Image(systemName: "house")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("New scan")

            // Back within browse
            if selectedCategory != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)

                Button(action: { withAnimation { selectedCategory = nil } }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Back")
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)

            // Device name
            Text(vm.effectiveDisplayName)
                .font(.system(size: 13, weight: .semibold))
                .onTapGesture { withAnimation { selectedCategory = nil } }

            // Category breadcrumb
            if let cat = selectedCategory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(cat.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            Spacer()

            // List / Grid toggle
            HStack(spacing: 0) {
                viewToggleButton(icon: "list.bullet", mode: .list)
                viewToggleButton(icon: "square.grid.2x2", mode: .grid)
            }
            .background(Color.mrSurface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mrBorder, lineWidth: 0.5))

            // Filter toggle
            Button(action: { withAnimation { showFilters.toggle() } }) {
                Image(systemName: showFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(showFilters ? Color.mrTeal : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(showFilters ? "Hide filters" : "Show filters")

            // Search
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .frame(width: 120)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.mrSurface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mrBorder, lineWidth: 0.5))

            // Recover button
            Button(action: { showRecovery = true }) {
                Text(queuedIDs.isEmpty
                     ? "Recover All"
                     : "Recover (\(queuedIDs.count))")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.mrTeal)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func viewToggleButton(icon: String, mode: ResultsViewMode) -> some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { viewMode = mode } }) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(viewMode == mode ? Color.mrTeal.opacity(0.15) : Color.clear)
                .foregroundStyle(viewMode == mode ? Color.mrTeal : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(mode == .list ? "List view" : "Grid view")
    }

    // MARK: - Filter bar (stub — populated in step 5)

    private var filterBar: some View {
        HStack(spacing: 8) {
            filterPill("Show", icon: "eye")
            filterPill("File Type", icon: "doc")
            filterPill("File Size", icon: "scalemass")
            filterPill("Date Modified", icon: "calendar")
            Spacer()
            if !searchText.isEmpty {
                Button("Clear all") { searchText = "" }
                    .font(.caption)
                    .foregroundStyle(.mrTeal)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color.mrSurface)
    }

    private func filterPill(_ label: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.mrSurface)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.mrBorder, lineWidth: 0.5))
    }

    // MARK: - Left sidebar

    private var resultsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Path / Type toggle
            HStack(spacing: 0) {
                sidebarToggle("Path", selected: sidebarMode == .path) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        sidebarMode = .path
                        selectedCategory = nil
                    }
                }
                sidebarToggle("Type", selected: sidebarMode == .type) {
                    withAnimation(.easeInOut(duration: 0.18)) { sidebarMode = .type }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if sidebarMode == .type {
                        typeSidebar
                    } else {
                        pathSidebar
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(width: 180)
        .background(VisualEffectBackground(material: .sidebar).ignoresSafeArea())
    }

    @ViewBuilder
    private var typeSidebar: some View {
        let summary = vm.summary

        // All files row
        ResultsSidebarRow(
            icon: "tray.full.fill", color: .mrTeal,
            label: "All Files",
            count: vm.result.map { "\($0.candidates.count)" },
            isSelected: selectedCategory == nil
        ) {
            withAnimation { selectedCategory = nil }
        }

        if let summary {
            // Populated categories
            ForEach(FileCategory.allCases, id: \.self) { cat in
                let count = summary.group(for: cat)?.count ?? 0
                ResultsSidebarRow(
                    icon: cat.symbolName,
                    color: count > 0 ? cat.tintColor : .secondary,
                    label: cat.rawValue,
                    count: count > 0 ? "\(count)" : nil,
                    isSelected: selectedCategory == cat,
                    disabled: count == 0
                ) {
                    withAnimation { selectedCategory = cat }
                }
            }
        }
    }

    @ViewBuilder
    private var pathSidebar: some View {
        let total = vm.result?.candidates.count ?? 0

        ResultsSidebarRow(
            icon: vm.effectiveSymbol, color: .mrTeal,
            label: vm.effectiveDisplayName,
            count: "\(total)",
            isSelected: true
        ) {}

        ResultsSidebarRow(
            icon: "wand.and.stars", color: .mrMint,
            label: "Reconstructed",
            count: vm.result.map {
                "\($0.candidates.filter { $0.source == .deepScan }.count)"
            },
            isSelected: false
        ) {}

        Text("QUICK ACCESS")
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .kerning(0.5)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)

        ResultsSidebarRow(
            icon: "trash", color: .mrRose,
            label: "Trash",
            count: vm.summary.map { "\($0.trashed.count)" },
            isSelected: false
        ) {}
    }

    private func sidebarToggle(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(selected ? Color.mrTeal : Color.clear)
                .foregroundStyle(selected ? .white : .secondary)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            // Select All row
            HStack(spacing: 8) {
                Image(systemName: queuedIDs.count == displayedCandidates.count && !displayedCandidates.isEmpty
                      ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(queuedIDs.count == displayedCandidates.count && !displayedCandidates.isEmpty
                                     ? Color.mrTeal : Color.secondary)
                    .onTapGesture { toggleSelectAll() }

                Text("Select All")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .onTapGesture { toggleSelectAll() }

                Spacer()

                if !queuedIDs.isEmpty {
                    Text("\(queuedIDs.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Sort menu
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
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 22)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Content
            if viewMode == .grid {
                gridContent
            } else {
                listContent
            }
        }
    }

    private func toggleSelectAll() {
        withAnimation(.spring(response: 0.2)) {
            if queuedIDs.count == displayedCandidates.count {
                queuedIDs.removeAll()
            } else {
                queuedIDs = Set(displayedCandidates.map(\.id))
            }
        }
    }

    // MARK: Grid view

    @ViewBuilder
    private var gridContent: some View {
        if displayedCandidates.isEmpty && selectedCategory == nil && sidebarMode == .type {
            // Type mode, no selection → show category folder grid
            categoriesGrid
        } else if displayedCandidates.isEmpty {
            emptyState
        } else {
            filesGrid
        }
    }

    private var categoriesGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 100, maximum: 130), spacing: 14)],
                spacing: 14
            ) {
                ForEach(FileCategory.allCases, id: \.self) { cat in
                    if let group = vm.summary?.group(for: cat) {
                        CategoryFolderCard(
                            category: cat,
                            count:    group.count,
                            isSelected: selectedCategory == cat
                        ) {
                            withAnimation { selectedCategory = cat }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var filesGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 100, maximum: 130), spacing: 14)],
                spacing: 14
            ) {
                ForEach(displayedCandidates) { candidate in
                    FileGridCard(
                        candidate: candidate,
                        isQueued:  queuedIDs.contains(candidate.id),
                        isSelected: selectedCandidateID == candidate.id
                    ) {
                        withAnimation(.spring(response: 0.2)) {
                            toggleQueued(candidate.id)
                        }
                    } onSelect: {
                        selectedCandidateID = candidate.id
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: List view

    private var listContent: some View {
        VStack(spacing: 0) {
            // Column headers
            listColumnHeader

            Divider()

            if displayedCandidates.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(displayedCandidates) { candidate in
                            ListRow(
                                candidate:  candidate,
                                isQueued:   queuedIDs.contains(candidate.id),
                                isSelected: selectedCandidateID == candidate.id,
                                onCheckbox: { toggleQueued(candidate.id) }
                            )
                            .onTapGesture { selectedCandidateID = candidate.id }
                            .background(selectedCandidateID == candidate.id
                                        ? Color.mrTeal.opacity(0.08) : Color.clear)

                            Divider().padding(.leading, 58)
                        }
                    }
                }
            }
        }
    }

    private var listColumnHeader: some View {
        HStack(spacing: 0) {
            // Checkbox + expand + icon spacer
            Color.clear.frame(width: 58)

            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Date Modified")
                .frame(width: 148, alignment: .leading)

            Text("Size")
                .frame(width: 88, alignment: .leading)

            Text("Kind")
                .frame(width: 120, alignment: .leading)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color.mrSurface)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.badge.questionmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary.opacity(0.35))
            Text("No files found")
                .foregroundStyle(.secondary)
            if !searchText.isEmpty {
                Button("Clear search") { searchText = "" }
                    .font(.caption).foregroundStyle(.mrTeal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Detail panel

    @ViewBuilder
    private var detailPanel: some View {
        if let candidate = selectedCandidate {
            fileDetailPanel(candidate)
        } else if let cat = selectedCategory {
            categoryDetailPanel(cat)
        }
    }

    private func fileDetailPanel(_ candidate: FileCandidate) -> some View {
        VStack(spacing: 0) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(candidate.fileType.category.tintColor.opacity(0.10))
                    .frame(width: 72, height: 72)
                Image(systemName: candidate.fileType.sfSymbol)
                    .font(.system(size: 36, weight: .ultraLight))
                    .foregroundStyle(candidate.fileType.category.tintColor)
            }
            .padding(.top, 20)
            .padding(.bottom, 14)

            // Open button
            Button(action: {}) {
                Text("Open")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 80)
            }
            .buttonStyle(.borderedProminent)
            .tint(.mrTeal)
            .controlSize(.small)
            .disabled(true)
            .help("Recover this file first")

            Divider().padding(.vertical, 14)

            // Metadata
            VStack(alignment: .leading, spacing: 10) {
                detailRow(label: "Name",
                          value: candidate.suggestedFileName)
                detailRow(label: "Size",
                          value: formatBytes(candidate.estimatedSize))
                if let date = candidate.modificationDate {
                    detailRow(label: "Modified",
                              value: date.formatted(date: .abbreviated, time: .shortened))
                }
                if let path = candidate.originalPath {
                    detailRow(label: "Locations", value: path)
                }

                // Type badge
                Text(candidate.fileType.rawValue)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(candidate.fileType.category.tintColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Divider()

                // Queue toggle
                Button(action: { toggleQueued(candidate.id) }) {
                    Label(
                        queuedIDs.contains(candidate.id) ? "Remove from Queue" : "Add to Queue",
                        systemImage: queuedIDs.contains(candidate.id) ? "minus.circle.fill" : "plus.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(queuedIDs.contains(candidate.id) ? Color.secondary : Color.mrTeal)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .frame(width: 210)
        .background(VisualEffectBackground(material: .sidebar).ignoresSafeArea())
    }

    private func categoryDetailPanel(_ cat: FileCategory) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.system(size: 52, weight: .ultraLight))
                .foregroundStyle(cat.tintColor.opacity(0.7))
                .padding(.top, 24)

            Text(cat.rawValue)
                .font(.headline)

            if let count = vm.summary?.group(for: cat)?.count {
                Text("\(count) file\(count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .frame(width: 210)
        .background(VisualEffectBackground(material: .sidebar).ignoresSafeArea())
    }

    private func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.4)
            Text(value)
                .font(.caption)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    // MARK: - Helpers

    private func toggleQueued(_ id: UUID) {
        if queuedIDs.contains(id) { queuedIDs.remove(id) }
        else                      { queuedIDs.insert(id) }
    }
}

// MARK: - ResultsSidebarRow

private struct ResultsSidebarRow: View {
    let icon:       String
    let color:      Color
    let label:      String
    let count:      String?
    let isSelected: Bool
    var disabled:   Bool = false
    let action:     () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? .white : (disabled ? Color.secondary.opacity(0.4) : color))
                    .frame(width: 18)

                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? .white : (disabled ? Color.secondary.opacity(0.4) : Color.primary))
                    .lineLimit(1)

                Spacer()

                if let count {
                    Text(count)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.mrTeal : Color.clear)
            )
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

// MARK: - CategoryFolderCard (grid view, Type mode)

private struct CategoryFolderCard: View {
    let category:   FileCategory
    let count:      Int
    let isSelected: Bool
    let action:     () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                // Checkbox
                HStack {
                    Image(systemName: "square")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                // Folder icon
                ZStack {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Color(red: 0.55, green: 0.72, blue: 0.95))

                    Image(systemName: category.symbolName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .offset(y: 4)
                }

                // Name + count
                Text("\(count > 0 ? category.rawValue.lowercased() : category.rawValue) (\(count))")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(10)
            .background(isSelected ? Color.mrTeal.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.mrTeal.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - FileGridCard (grid view, inside category)

private struct FileGridCard: View {
    let candidate:  FileCandidate
    let isQueued:   Bool
    let isSelected: Bool
    let onQueue:    () -> Void
    let onSelect:   () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                // File icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(candidate.fileType.category.tintColor.opacity(0.10))
                        .frame(width: 64, height: 64)
                    Image(systemName: candidate.fileType.sfSymbol)
                        .font(.system(size: 28, weight: .ultraLight))
                        .foregroundStyle(candidate.fileType.category.tintColor)
                }
                .onTapGesture { onSelect() }

                // Checkbox overlay
                Image(systemName: isQueued ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(isQueued ? Color.mrTeal : Color.secondary.opacity(0.6))
                    .padding(4)
                    .onTapGesture { onQueue() }
            }

            Text(candidate.suggestedFileName)
                .font(.system(size: 10))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(8)
        .background(isSelected ? Color.mrTeal.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.mrTeal.opacity(0.4) : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: - ListRow (list view)

private struct ListRow: View {
    let candidate:  FileCandidate
    let isQueued:   Bool
    let isSelected: Bool
    let onCheckbox: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Checkbox
            Image(systemName: isQueued ? "checkmark.square.fill" : "square")
                .font(.system(size: 13))
                .foregroundStyle(isQueued ? Color.mrTeal : Color.secondary.opacity(0.5))
                .frame(width: 28)
                .onTapGesture { onCheckbox() }

            // Disclosure arrow placeholder
            Image(systemName: "chevron.right")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 14)

            // File icon
            Image(systemName: candidate.fileType.sfSymbol)
                .font(.system(size: 13))
                .foregroundStyle(candidate.fileType.category.tintColor)
                .frame(width: 20)
                .padding(.trailing, 6)

            // Name
            Text(candidate.suggestedFileName)
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Date Modified
            Text(candidate.modificationDate.map {
                $0.formatted(date: .numeric, time: .shortened)
            } ?? "—")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 148, alignment: .leading)

            // Size
            Text(formatBytes(candidate.estimatedSize))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)

            // Kind
            Text(candidate.fileType.kindLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
