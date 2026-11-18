import SwiftUI
import MihonDomain
import MihonAPKEngine
import MihonData

// MARK: - 1:1 Mihon Global Search (`GlobalSearchScreen`: every source searched at once, one row per source)

struct GlobalSearchScreen: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @Environment(\.mihonNavigator) private var navigator
    @Environment(\.dismiss) private var dismiss

    @State private var query: String
    @State private var submitted: String
    @State private var results: [Int64: SourceResult] = [:]
    /// The query `results` answer.
    @State private var resultsQuery = ""
    @State private var onlyWithResults = false
    /// Migration (upstream `MigrateSearchScreen`): the library title being moved, and the result picked for it.
    private let migratingMangaId: Int64?
    @State private var migrationTarget: MigrationTarget?

    struct MigrationTarget: Identifiable {
        let manga: SManga
        let sourceId: Int64
        var id: String { "\(sourceId)|\(manga.url)" }
    }

    enum SourceResult {
        case loading
        case found([SManga])
        case failed(String)

        var hasResults: Bool {
            if case .found(let mangas) = self { return !mangas.isEmpty }
            return false
        }
    }

    init(initialQuery: String?, migratingMangaId: Int64? = nil) {
        let text = (initialQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        _query = State(initialValue: text)
        _submitted = State(initialValue: text)
        self.migratingMangaId = migratingMangaId
    }

    var body: some View {
        let sources = orderedSources()
        VStack(spacing: 0) {
            MihonSearchAppBar(query: $query, placeholder: "搜索全部图源…", onClose: { dismiss() }, onSubmit: {
                submitted = query.trimmingCharacters(in: .whitespacesAndNewlines)
            })
            HStack(spacing: MihonPadding.small) {
                MihonFilterChip(label: "只显示有结果的图源", selected: onlyWithResults) { onlyWithResults.toggle() }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            if let migratingMangaId, let manga = store.manga(id: migratingMangaId) {
                Text("迁移「\(manga.title)」：选择要迁移到的作品")
                    .font(MihonType.bodyMedium)
                    .foregroundStyle(colors.onSurfaceVariant)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if submitted.isEmpty {
                MihonEmptyScreen(message: "输入作品名，同时搜索所有图源")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sources, id: \.id) { source in
                            let result = results[source.id] ?? .loading
                            if !onlyWithResults || result.hasResults {
                                row(source, result)
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }
                // Scroll content draws into the side safe area (the Duo cover screen's status strip) unless clipped.
                .clipped()
            }
        }
        .background(colors.background)
        .task(id: SearchKey(query: submitted, sourceIds: sources.map(\.id))) { await search(submitted, in: sources) }
        .sheet(item: $migrationTarget) { target in
            if let migratingMangaId, let current = store.manga(id: migratingMangaId) {
                MigrationDialog(current: current, target: target.manga, sourceId: target.sourceId) { migrated in
                    migrationTarget = nil
                    if migrated { dismiss() }
                }
                .environment(store)
                .mihonSheetChrome(colors)
            }
        }
    }

    /// Pinned sources first, then by language like the sources tab.
    private func orderedSources() -> [APKSynthesizedHttpSource] {
        store.activeCatalogueSources().sorted { lhs, rhs in
            let lhsPinned = store.pinnedSourceIds.contains(lhs.id), rhsPinned = store.pinnedSourceIds.contains(rhs.id)
            if lhsPinned != rhsPinned { return lhsPinned }
            if lhs.lang != rhs.lang { return MihonLanguageOrder.precedes(lhs.lang, rhs.lang) }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private struct SearchKey: Equatable {
        var query: String
        var sourceIds: [Int64]
    }

    /// All sources at once; a new query cancels the previous search (`task(id:)`). Coming back to the screen, or a
    /// source appearing, asks only the sources still without an answer, as upstream's screen model keeps its results.
    private func search(_ query: String, in sources: [APKSynthesizedHttpSource]) async {
        guard !query.isEmpty else { return }
        if query != resultsQuery {
            resultsQuery = query
            results = [:]
        }
        let pending = sources.filter { source in
            if case .loading = results[source.id] ?? .loading { return true }
            return false
        }
        guard !pending.isEmpty else { return }
        for source in pending { results[source.id] = .loading }
        await withTaskGroup(of: (Int64, SourceResult).self) { group in
            for source in pending {
                group.addTask {
                    do {
                        let page = try await source.getSearchManga(page: 1, query: query, filters: source.getFilterList())
                        return (source.id, .found(page.mangas))
                    } catch {
                        return (source.id, .failed(error.localizedDescription))
                    }
                }
            }
            for await (id, result) in group where !Task.isCancelled {
                results[id] = result
            }
        }
    }

    /// `GlobalSearchResultItem`: source name and language (opens that source's own search), then its results.
    private func row(_ source: APKSynthesizedHttpSource, _ result: SourceResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(source.name)
                        .font(MihonType.titleMedium)
                        .foregroundStyle(colors.onSurface)
                    Text(MihonLanguage.displayName(source.lang))
                        .font(MihonType.bodyMedium)
                        .foregroundStyle(colors.onSurface.opacity(MihonAlpha.secondary))
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 18))
                    .foregroundStyle(colors.onSurfaceVariant)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .mihonClickable {
                // Migrating, a source's own page would leave the migration: its results are picked here.
                if migratingMangaId == nil { navigator.push(.source(sourceId: source.id, listing: .search, query: submitted)) }
            }
            .mihonTestAnchor("globalSearch.\(source.name).\(source.lang)")

            switch result {
            case .loading:
                MihonCircularProgress(size: 24, lineWidth: 3)
                    .frame(maxWidth: .infinity, minHeight: 64)
            case .failed(let message):
                resultMessage(message)
            case .found(let mangas) where mangas.isEmpty:
                resultMessage("没有结果")
            case .found(let mangas):
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(migrationCandidates(mangas, in: source.id).prefix(20), id: \.url) { manga in
                            if migratingMangaId != nil {
                                let inLibrary = store.mangas.contains { $0.source == source.id && $0.url == manga.url && $0.favorite }
                                MigrationResultItem(manga: manga, inLibrary: inLibrary) {
                                    migrationTarget = MigrationTarget(manga: manga, sourceId: source.id)
                                }
                                .frame(width: 112)
                            } else {
                                BrowseSourceGridItem(manga: manga, sourceId: source.id)
                                    .frame(width: 112)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .mihonTestAnchor("globalSearch.results.\(source.id)")
            }
        }
    }

    /// Migrating, the title itself is no target (upstream marks it; picking it would do nothing).
    private func migrationCandidates(_ mangas: [SManga], in sourceId: Int64) -> [SManga] {
        guard let migratingMangaId, let current = store.manga(id: migratingMangaId), current.source == sourceId else { return mangas }
        return mangas.filter { $0.url != current.url }
    }

    private func resultMessage(_ text: String) -> some View {
        Text(text)
            .font(MihonType.bodyMedium)
            .foregroundStyle(colors.onSurface.opacity(MihonAlpha.secondary))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }
}

/// A search result to migrate to: its cover and title; tapping it asks how (upstream's migrate dialog).
private struct MigrationResultItem: View {
    let manga: SManga
    let inLibrary: Bool
    let onPick: () -> Void
    @Environment(\.mihonColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MangaCoverView(title: manga.title, thumbnailUrl: manga.thumbnailUrl)
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    if inLibrary {
                        MihonBadgeGroup {
                            MihonBadge(text: "在书架中", color: colors.secondary, contentColor: colors.onSecondary)
                        }
                        .padding(4)
                    }
                }
            Text(manga.title)
                .font(MihonType.bodySmall)
                .lineLimit(2)
        }
        .padding(4)
        .mihonClickable(cornerRadius: MihonShape.small, onClick: onPick)
        .mihonTestAnchor("migrate.target.\(manga.url)")
    }
}

/// Upstream `MigrateDialog`: what to carry over, then copy (both stay) or migrate (the new one replaces the old).
private struct MigrationDialog: View {
    let current: Manga
    let target: SManga
    let sourceId: Int64
    let onFinished: (Bool) -> Void
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("迁移")
                .font(MihonType.titleLarge)
                .foregroundStyle(colors.onSurface)
                .padding(.horizontal, 24)
                .padding(.top, 24)
            Text("「\(current.title)」（\(store.sourceName(for: current.source))）→「\(target.title)」（\(store.sourceName(for: sourceId))）")
                .font(MihonType.bodyMedium)
                .foregroundStyle(colors.onSurfaceVariant)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            ForEach(MihonRepositoryStore.MigrationFlag.allCases, id: \.self) { flag in
                MihonCheckboxItem(flag.rawValue, checked: store.migrationFlags.contains(flag)) {
                    if store.migrationFlags.contains(flag) {
                        store.migrationFlags.remove(flag)
                    } else {
                        store.migrationFlags.insert(flag)
                    }
                }
                .disabled(running)
            }
            HStack(spacing: MihonPadding.small) {
                if running { MihonCircularProgress(size: 20, lineWidth: 2) }
                Spacer()
                Button("取消") { onFinished(false) }
                    .buttonStyle(MihonButtonStyle(.text))
                Button("复制") { run(replace: false) }
                    .buttonStyle(MihonButtonStyle(.text))
                    .mihonTestAnchor("dialog.复制")
                Button("迁移") { run(replace: true) }
                    .buttonStyle(MihonButtonStyle(.filled))
                    .mihonTestAnchor("dialog.迁移")
            }
            .disabled(running)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            Spacer(minLength: 0)
        }
        .background(colors.surface)
        // Upstream blocks the screen while it migrates.
        .interactiveDismissDisabled(running)
    }

    private func run(replace: Bool) {
        guard !running else { return }
        running = true
        Task {
            let migrated = await store.migrateManga(currentId: current.id, to: target, sourceId: sourceId, replace: replace)
            running = false
            onFinished(migrated)
        }
    }
}
