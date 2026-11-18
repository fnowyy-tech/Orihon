import SwiftUI
import UniformTypeIdentifiers
import MihonDomain
import MihonData

// MARK: - Mihon logo (`R.drawable.ic_mihon`, viewport 148 × 141)

public struct MihonLogoMark: Shape {
    private static let pathData = "M20.3,27.59L19.22,2.63C22.47,3.25 26.35,3.41 35.18,3.41C45.87,3.41 59.97,2.79 67.26,1.86C70.36,1.55 71.6,1.08 73.61,0L90.35,14.26C88.8,16.43 88.34,17.36 86.63,21.7C85.24,25.11 78.88,44.79 76.4,53.16C87.87,55.48 94.22,57.19 102.9,60.75C103.99,53.16 104.14,49.13 104.14,35.33C104.14,31.77 103.99,29.75 103.52,26.5L130.49,27.43C129.71,31.15 129.56,32.7 129.4,38.74C128.78,53.31 128.16,60.28 126.61,70.82C137.31,76.25 137.31,76.25 142.73,79.19C145.52,80.74 146.14,81.05 148,81.67L139.01,110.65C134.67,106.78 128.63,102.59 119.79,97.63C112.05,116.07 99.18,129.56 79.66,140.25C73.15,131.57 68.19,126.3 60.28,120.11C71.75,114.68 77.02,111.27 83.07,105.54C88.96,99.8 92.83,94.22 96.55,85.86C86.63,81.36 80.28,79.35 69.27,77.02C62.92,95.93 57.81,108.02 53.31,115.3C47.27,125.06 39.05,130.18 29.6,130.18C22.32,130.18 14.88,126.92 9.45,121.35C3.25,114.99 0,106.16 0,95.93C0,80.74 7.28,67.57 19.99,59.35C28.21,54.09 36.88,51.76 50.68,50.99C53.47,41.84 55.79,33.94 57.96,25.11C51.14,25.73 42.62,26.19 32.23,26.66C26.66,26.81 24.8,26.97 20.3,27.59ZM43.86,74.7C36.57,75.94 32.23,78.26 28.36,83.22C25.42,86.63 24.02,90.66 24.02,95C24.02,99.8 26.35,103.37 29.29,103.37C32.85,103.37 36.88,95.31 43.86,74.7Z"

    /// Tiny parser for the absolute `M/L/C/Z` commands used by the vector drawable.
    private static let unitPath: Path = {
        var path = Path()
        var command: Character = "M"
        var numbers: [CGFloat] = []
        var token = ""

        func flushToken() {
            if let value = Double(token) { numbers.append(CGFloat(value)) }
            token = ""
        }

        func apply() {
            switch command {
            case "M":
                while numbers.count >= 2 {
                    path.move(to: CGPoint(x: numbers[0], y: numbers[1]))
                    numbers.removeFirst(2)
                    command = "L"
                }
            case "L":
                while numbers.count >= 2 {
                    path.addLine(to: CGPoint(x: numbers[0], y: numbers[1]))
                    numbers.removeFirst(2)
                }
            case "C":
                while numbers.count >= 6 {
                    path.addCurve(
                        to: CGPoint(x: numbers[4], y: numbers[5]),
                        control1: CGPoint(x: numbers[0], y: numbers[1]),
                        control2: CGPoint(x: numbers[2], y: numbers[3])
                    )
                    numbers.removeFirst(6)
                }
            default:
                break
            }
        }

        for char in pathData {
            if "MLCZ".contains(char) {
                flushToken()
                apply()
                if char == "Z" {
                    path.closeSubpath()
                    numbers.removeAll()
                }
                command = char
            } else if char == "," || char == " " {
                flushToken()
            } else if char == "-" && !token.isEmpty {
                flushToken()
                token = "-"
            } else {
                token.append(char)
            }
        }
        flushToken()
        apply()
        return path
    }()

    public init() {}

    public func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 148, rect.height / 141)
        let offsetX = rect.minX + (rect.width - 148 * scale) / 2
        let offsetY = rect.minY + (rect.height - 141 * scale) / 2
        return Self.unitPath.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offsetX, ty: offsetY))
    }
}

/// `LogoHeader`
struct MihonLogoHeader: View {
    @Environment(\.mihonColors) private var colors

    var body: some View {
        VStack(spacing: 0) {
            MihonLogoMark()
                .fill(colors.onSurface)
                .frame(width: 64, height: 61)
                .padding(.vertical, 32)
            MihonDivider()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 1:1 Mihon "More" tab

public struct MoreScreen: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @Environment(\.mihonNavigator) private var navigator
    @Environment(\.openURL) private var openURL

    public init() {}

    public var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(spacing: 0) {
                MihonLogoHeader()
                MihonSwitchPreference(
                    title: "仅限已下载内容",
                    subtitle: "筛选书架里的全部作品",
                    systemImage: "icloud.slash",
                    isOn: $store.downloadedOnlyMode
                )
                MihonSwitchPreference(
                    title: "无痕模式",
                    subtitle: "暂停记录阅读历史",
                    systemImage: "eyeglasses",
                    isOn: $store.incognitoMode
                )
                MihonDivider()
                link(title: "下载队列", subtitle: store.downloadQueue.isEmpty ? nil : "剩余 \(store.downloadQueue.count) 章", icon: "arrow.down.circle", page: .downloadQueue)
                link(title: "分类", icon: "tag", page: .categories)
                link(title: "统计", icon: "chart.bar.xaxis", page: .statistics)
                link(title: "数据与存储", icon: "externaldrive", page: .dataStorage)
                MihonDivider()
                link(title: "设置", icon: "gearshape", page: .main)
                link(title: "关于", icon: "info.circle", page: .about)
                MihonPreferenceRow(title: "帮助", systemImage: "questionmark.circle") {
                    if let url = URL(string: "https://mihon.app/docs/guides/troubleshooting/") { openURL(url) }
                }
            }
        }
        .background(colors.background)
    }

    private func link(title: String, subtitle: String? = nil, icon: String, page: MihonSettingsPage) -> some View {
        MihonPreferenceRow(title: title, subtitle: subtitle, systemImage: icon) {
            navigator.push(.settings(page))
        }
    }
}

/// Resolves `MihonRoute.settings` pages.
struct MihonSettingsDestination: View {
    let page: MihonSettingsPage

    var body: some View {
        switch page {
        case .downloadQueue: DownloadQueueScreen()
        case .categories: CategoriesManagementScreen()
        case .statistics: StatisticsDashboardScreen()
        case .dataStorage: BackupAndStorageScreen()
        case .main: SettingsMainScreen()
        case .appearance: AppearanceSettingsScreen()
        case .library: LibrarySettingsScreen()
        case .reader: ReaderPreferencesScreen()
        case .duo: DuoSettingsScreen()
        case .download: DownloadSettingsScreen()
        case .tracking: TrackerServicesSettingsScreen()
        case .browse: BrowseSettingsScreen()
        case .extensionRepos: ExtensionReposScreen()
        case .security: SecurityAndAdvancedSettingsScreen()
        case .about: AboutMihonScreen()
        }
    }
}

/// Settings sub-screen scaffold: Material app bar with back arrow + scrolling content.
struct MihonSettingsScaffold<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @Environment(\.mihonColors) private var colors
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            MihonTopAppBar(title: title, navigation: .back { dismiss() })
            ScrollView {
                VStack(spacing: 0, content: content)
                    .padding(.bottom, 24)
            }
        }
        .background(colors.background)
    }
}

// MARK: - 1. Download queue (1:1 with `DownloadQueueScreen`)

public struct DownloadQueueScreen: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            MihonTopAppBar(
                title: "下载队列",
                subtitle: store.downloadQueue.isEmpty ? nil : "剩余 \(store.downloadQueue.count) 章",
                navigation: .back { dismiss() }
            ) {
                MihonIconButton("trash", isEnabled: !store.downloadQueue.isEmpty) { store.clearDownloadQueue() }
                    .help("清除")
            }
            if store.downloadQueue.isEmpty {
                MihonEmptyScreen(message: "无下载任务")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let groups = Dictionary(grouping: store.downloadQueue, by: \.sourceName)
                        ForEach(groups.keys.sorted(), id: \.self) { sourceName in
                            MihonListGroupHeader("\(sourceName) (\(groups[sourceName]?.count ?? 0))")
                            ForEach(groups[sourceName] ?? []) { task in
                                DownloadQueueItem(task: task)
                            }
                        }
                    }
                    .padding(.bottom, 96)
                }
            }
        }
        .background(colors.background)
        .overlay(alignment: .bottomTrailing) {
            if !store.downloadQueue.isEmpty {
                MihonExtendedFAB(
                    text: store.isDownloaderRunning ? "暂停" : "继续",
                    systemImage: store.isDownloaderRunning ? "pause.fill" : "play.fill"
                ) {
                    store.toggleDownloaderRunning()
                }
                .padding(16)
            }
        }
    }
}

private struct DownloadQueueItem: View {
    let task: MihonDownloadTask
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(task.manga.title)
                    .font(MihonType.bodyMedium)
                    .foregroundStyle(colors.onSurface)
                    .lineLimit(1)
                Text(task.chapter.name)
                    .font(MihonType.bodySmall)
                    .foregroundStyle(colors.onSurfaceVariant)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    MihonLinearProgress(progress: task.status == .queue ? 0 : task.progress)
                        .clipShape(Capsule())
                    Text(task.totalPages > 0 ? "\(task.downloadedPages)/\(task.totalPages)" : "—")
                        .font(MihonType.labelSmall)
                        .foregroundStyle(colors.onSurfaceVariant)
                        .monospacedDigit()
                }
            }
            Menu {
                Button("取消", role: .destructive) { store.cancelDownload(chapterId: task.id) }
            } label: {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
                    .foregroundStyle(colors.onSurfaceVariant)
                    .frame(width: 40, height: 40)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - 2. Categories (1:1 with `CategoryScreen`)

public struct CategoriesManagementScreen: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @Environment(\.dismiss) private var dismiss
    @State private var editing: MangaCategory?
    @State private var deleting: MangaCategory?
    @State private var showCreate = false
    @State private var draftName = ""

    public init() {}

    public var body: some View {
        let categories = store.categories.filter { !$0.isSystemCategory }.sorted { $0.order < $1.order }
        VStack(spacing: 0) {
            MihonTopAppBar(title: "编辑分类", navigation: .back { dismiss() })
            if categories.isEmpty {
                MihonEmptyScreen(message: "没有分类。点按“添加”按钮以创建分类，用于整理书架。")
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                            VStack(spacing: 0) {
                                HStack(spacing: 16) {
                                    Image(systemName: "tag")
                                        .foregroundStyle(colors.onSurfaceVariant)
                                    Text(category.name)
                                        .font(MihonType.bodyLarge)
                                        .foregroundStyle(colors.onSurface)
                                    Spacer()
                                    Text("\(store.libraryItems(forCategory: category.id, searchQuery: "").count)")
                                        .font(MihonType.bodySmall)
                                        .foregroundStyle(colors.onSurfaceVariant)
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 16)
                                .padding(.bottom, 8)
                                HStack(spacing: 0) {
                                    MihonIconButton("arrow.up", isEnabled: index > 0) { store.moveCategory(id: category.id, by: -1) }
                                    MihonIconButton("arrow.down", isEnabled: index < categories.count - 1) { store.moveCategory(id: category.id, by: 1) }
                                    Spacer()
                                    MihonIconButton("pencil") {
                                        draftName = category.name
                                        editing = category
                                    }
                                    MihonIconButton("trash") { deleting = category }
                                }
                                .padding(.horizontal, 4)
                            }
                            .background(RoundedRectangle(cornerRadius: MihonShape.medium).fill(colors.surfaceContainerHigh))
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 80)
                }
            }
        }
        .background(colors.background)
        .overlay(alignment: .bottomTrailing) {
            MihonExtendedFAB(text: "添加", systemImage: "plus") {
                draftName = ""
                showCreate = true
            }
            .padding(16)
        }
        .alert("添加分类", isPresented: $showCreate) {
            TextField("名称", text: $draftName)
            Button("取消", role: .cancel) {}
            Button("添加") { store.addCategory(name: draftName) }
        }
        .alert("删除分类", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                if let deleting { store.deleteCategory(id: deleting.id) }
                deleting = nil
            }
        } message: {
            Text("确定要删除分类「\(deleting?.name ?? "")」吗？其中的作品会移到「默认」。")
        }
        .alert("重命名分类", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("名称", text: $draftName)
            Button("取消", role: .cancel) { editing = nil }
            Button("确定") {
                if let editing { store.renameCategory(id: editing.id, name: draftName) }
                editing = nil
            }
        }
    }
}

// MARK: - 3. Statistics (1:1 with `StatsScreen`)

public struct StatisticsDashboardScreen: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors

    public init() {}

    public var body: some View {
        let stats = store.computeStatistics()
        MihonSettingsScaffold(title: "统计") {
            VStack(spacing: 16) {
                section("概览") {
                    statItem("\(stats.inLibraryCount)", "书架中", icon: "books.vertical")
                    statItem(durationText(stats.totalReadDurationSeconds), "阅读时长", icon: "clock")
                    statItem(bytesText(), "存储使用", icon: "externaldrive")
                }
                section("作品") {
                    statItem("\(stats.inLibraryCount)", "书架中")
                    statItem("\(stats.completedMangaCount)", "已完结")
                    statItem("\(stats.startedMangaCount)", "阅读过")
                    if store.showsDemoFeatures {
                        statItem("\(stats.localMangaCount)", "本地")
                    }
                }
                section("章节") {
                    statItem("\(stats.totalChaptersCount)", "全部")
                    statItem("\(stats.readChaptersCount)", "已读")
                    statItem("\(stats.downloadedChaptersCount)", "已下载")
                }
                if store.showsDemoFeatures {
                    section("进度记录") {
                        statItem("\(stats.trackedMangaCount)", "已记录进度")
                        statItem(stats.meanTrackerScore > 0 ? String(format: "%.2f ★", stats.meanTrackerScore) : "—", "平均评分")
                        statItem("\(stats.trackerCount)", "已使用的记录平台")
                    }
                }
            }
            .padding(16)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(MihonType.titleSmall)
                .foregroundStyle(colors.onSurfaceVariant)
                .padding(.leading, 8)
            HStack(alignment: .top, spacing: 0, content: content)
                .padding(.vertical, 16)
                .background(RoundedRectangle(cornerRadius: MihonShape.medium).fill(colors.surfaceContainerHigh))
        }
    }

    private func statItem(_ value: String, _ label: String, icon: String? = nil) -> some View {
        VStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(colors.primary)
            }
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(colors.onSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(MihonType.bodySmall)
                .foregroundStyle(colors.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
    }

    private func durationText(_ seconds: Int64) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours) 小时 \(minutes) 分" : "\(minutes) 分钟"
    }

    private func bytesText() -> String {
        ByteCountFormatter.string(fromByteCount: MihonTwoTierImageCache.shared.diskCacheSizeBytes(), countStyle: .file)
    }
}

// MARK: - 4. Data & storage (1:1 with `SettingsDataScreen`)

public struct BackupAndStorageScreen: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    /// A backup being saved through the system's file exporter (Files, iCloud Drive, AirDrop …).
    @State private var exportedBackup: MihonBackupDocument?
    /// A `.tachibk` being encoded (off the main thread) before the exporter opens.
    @State private var isPreparingBackup = false
    @State private var showImporter = false
    /// A backup file read and checked, waiting for the user to confirm the restore.
    @State private var pendingRestore: (backup: TachiyomiBackupDecoder.Result, titles: Int)?
    @State private var cacheSize: Int64 = 0

    public init() {}

    /// Sources the backup names that this build lacks (upstream `BackupFileValidator`'s missing sources).
    private var missingSourceCount: Int {
        pendingRestore?.backup.sourceNames.keys.filter { store.sourceDescriptor(for: $0) == nil }.count ?? 0
    }

    private static func backupFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return "Orihon_\(formatter.string(from: Date())).json"
    }

    public var body: some View {
        MihonSettingsScaffold(title: "数据与存储") {
            MihonPreferenceGroupHeader("备份与恢复")
            MihonPreferenceRow(title: "创建备份", subtitle: "把书架、分类、阅读进度与历史保存为文件", systemImage: "square.and.arrow.up", isEnabled: !isPreparingBackup) {
                do {
                    exportedBackup = MihonBackupDocument(data: try store.createBackupJSONData(), contentType: .json, fileName: Self.backupFileName())
                } catch {
                    store.showStatusBanner("无法创建备份：\(error.localizedDescription)")
                }
            }
            // Upstream's own format, for moving the library to Mihon / Tachiyomi on Android.
            MihonPreferenceRow(
                title: "导出为 Mihon 备份",
                subtitle: isPreparingBackup ? "正在生成备份…" : "安卓上的 Mihon / Tachiyomi 能恢复的 .tachibk 文件",
                systemImage: "arrow.up.doc",
                isEnabled: !isPreparingBackup
            ) {
                guard !isPreparingBackup else { return }
                isPreparingBackup = true
                Task {
                    defer { isPreparingBackup = false }
                    do {
                        let data = try await store.createTachiyomiBackupData()
                        // Another file panel opened meanwhile: this one would land on top of it.
                        guard exportedBackup == nil, !showImporter else { return }
                        exportedBackup = MihonBackupDocument(
                            data: data,
                            contentType: MihonBackupDocument.tachibk,
                            fileName: TachiyomiBackupEncoder.fileName()
                        )
                    } catch {
                        store.showStatusBanner("无法创建备份：\(error.localizedDescription)")
                    }
                }
            }
            MihonPreferenceRow(title: "恢复备份", subtitle: "把备份文件合并到书架", systemImage: "arrow.counterclockwise", isEnabled: !isPreparingBackup) {
                showImporter = true
            }
            // Upstream "Automatic backups": checked at launch and when leaving the app.
            MihonChipRow("自动备份（保留最近 4 份，在「文件」App › 我的 iPhone › Orihon › autobackup）") {
                ForEach(MihonAutoBackup.intervalChoices, id: \.self) { hours in
                    MihonFilterChip(label: MihonAutoBackup.title(hours: hours), selected: store.autoBackupInterval == hours) {
                        store.autoBackupInterval = hours
                    }
                }
            }
            MihonPreferenceGroupHeader("存储")
            MihonPreferenceRow(
                title: "已使用的存储空间",
                subtitle: "图片缓存：\(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)) · 已下载 \(store.downloadedChapterIds.count) 章"
            )
            MihonPreferenceRow(title: "清除章节缓存", subtitle: "清除封面与章节图片的磁盘缓存", systemImage: "trash") {
                MihonTwoTierImageCache.shared.clearAllCaches()
                cacheSize = MihonTwoTierImageCache.shared.diskCacheSizeBytes()
                store.showStatusBanner("已清除缓存")
            }
            MihonPreferenceRow(title: "删除已下载章节", subtitle: "移除所有离线章节", systemImage: "arrow.down.circle") {
                store.removeAllDownloads()
                store.showStatusBanner("已删除已下载章节")
            }
        }
        .task {
            cacheSize = await Task.detached(priority: .utility) {
                MihonTwoTierImageCache.shared.diskCacheSizeBytes()
            }.value
        }
        .fileExporter(
            isPresented: Binding(get: { exportedBackup != nil }, set: { if !$0 { exportedBackup = nil } }),
            document: exportedBackup,
            contentType: exportedBackup?.contentType ?? .json,
            defaultFilename: exportedBackup?.fileName
        ) { result in
            switch result {
            case .success: store.showStatusBanner("备份已保存")
            case .failure(let error): store.showStatusBanner("无法保存备份：\(error.localizedDescription)")
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: MihonBackupDocument.restorableTypes) { result in
            guard case .success(let url) = result else { return }
            Task {
                do {
                    // Off the main thread: a whole Mihon library is megabytes of protobuf.
                    let backup = try await Task.detached(priority: .userInitiated) {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        return try MihonRepositoryStore.decodeBackup(Data(contentsOf: url))
                    }.value
                    pendingRestore = (backup, backup.payload.backupManga.filter(\.favorite).count)
                } catch {
                    store.showStatusBanner("无法读取备份：\(error.localizedDescription)")
                }
            }
        }
        .alert("恢复备份", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })) {
            Button("取消", role: .cancel) { pendingRestore = nil }
            Button("恢复") {
                if let pendingRestore { store.restore(pendingRestore.backup) }
                pendingRestore = nil
            }
        } message: {
            Text("备份的书架里有 \(pendingRestore?.titles ?? 0) 部作品。恢复会合并到当前书架：已有的作品和进度都保留，并补上备份里的作品、分类、阅读进度和历史。"
                 + (missingSourceCount > 0 ? "\n备份里有 \(missingSourceCount) 个本应用没有的图源，它们的作品会显示为「图源未安装」。" : ""))
        }
    }
}

extension MihonBackupDocument {
    /// Upstream's backup file; no app declares the type, so it is known by its extension.
    static let tachibk = UTType(filenameExtension: "tachibk", conformingTo: .data) ?? .data
    /// What 恢复备份 opens: this port's JSON, and upstream's `.tachibk` (Tachiyomi's older `.proto.gz` too).
    static let restorableTypes: [UTType] = [.json, tachibk, .gzip]
}

/// A backup as a file: this port's JSON, or upstream's `.tachibk` for Mihon on Android.
struct MihonBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, tachibk] }

    var data: Data
    var contentType: UTType = .json
    var fileName: String?

    init(data: Data, contentType: UTType, fileName: String) {
        self.data = data
        self.contentType = contentType
        self.fileName = fileName
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
        contentType = configuration.contentType
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - 5. Settings main (1:1 with `SettingsMainScreen`)

public struct SettingsMainScreen: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonNavigator) private var navigator

    public init() {}

    public var body: some View {
        MihonSettingsScaffold(title: "设置") {
            settingsLink("外观", "主题、日期和时间格式", "paintpalette", .appearance)
            settingsLink("书架", "分类、全局更新、章节滑动", "books.vertical", .library)
            settingsLink("阅读器", "阅读模式、显示、导航", "book", .reader)
            settingsLink("iPhone Duo 双屏", "屏幕形态、双页书本、铰链避让", "rectangle.split.2x1", .duo)
            settingsLink("下载", "自动下载、提前下载", "arrow.down.circle", .download)
            if store.showsDemoFeatures {
                settingsLink("进度记录", "单向进度同步、加强同步", "arrow.triangle.2.circlepath", .tracking)
            }
            settingsLink("浏览", store.showsDemoFeatures ? "图源、插件、全局搜索" : "图源、全局搜索", "safari", .browse)
            settingsLink("数据与存储", "手动和自动备份、存储空间", "externaldrive", .dataStorage)
            settingsLink("隐私", "应用锁、安全屏幕", "lock.shield", .security)
            settingsLink("关于", nil, "info.circle", .about)
        }
    }

    private func settingsLink(_ title: String, _ subtitle: String?, _ icon: String, _ page: MihonSettingsPage) -> some View {
        MihonPreferenceRow(title: title, subtitle: subtitle, systemImage: icon) {
            navigator.push(.settings(page))
        }
    }
}

// MARK: - Appearance (1:1 with `SettingsAppearanceScreen` theme picker)

public struct AppearanceSettingsScreen: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @Environment(\.colorScheme) private var systemScheme

    public init() {}

    public var body: some View {
        @Bindable var store = store
        MihonSettingsScaffold(title: "外观") {
            MihonPreferenceGroupHeader("主题")
            HStack(spacing: 0) {
                ForEach(DarkModePreference.allCases, id: \.self) { mode in
                    let selected = store.darkMode == mode
                    Button {
                        store.darkMode = mode
                    } label: {
                        HStack(spacing: 6) {
                            if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)) }
                            Text(mode.rawValue).font(MihonType.labelLarge)
                        }
                        .foregroundStyle(selected ? colors.onSecondaryContainer : colors.onSurface)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(selected ? colors.secondaryContainer : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if mode != DarkModePreference.allCases.last {
                        Rectangle().fill(colors.outline).frame(width: 1, height: 40)
                    }
                }
            }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(colors.outline, lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(MihonThemePalette.allCases) { palette in
                        ThemePreviewCard(
                            palette: palette,
                            dark: systemScheme == .dark,
                            pureBlack: store.pureBlackDarkMode,
                            selected: store.themePalette == palette
                        ) {
                            store.themePalette = palette
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .clipped()
            MihonSwitchPreference(title: "纯黑深色模式", isOn: $store.pureBlackDarkMode)
        }
    }
}

/// Miniature app preview per theme (upstream `AppThemePreviewItem`).
private struct ThemePreviewCard: View {
    let palette: MihonThemePalette
    let dark: Bool
    let pureBlack: Bool
    let selected: Bool
    let action: () -> Void
    @Environment(\.mihonColors) private var colors

    var body: some View {
        let scheme = MihonColorScheme(palette: palette, dark: dark, pureBlack: pureBlack)
        Button(action: action) {
            VStack(spacing: 8) {
                VStack(spacing: 6) {
                    HStack {
                        RoundedRectangle(cornerRadius: 3).fill(scheme.onSurface.opacity(0.7)).frame(width: 36, height: 8)
                        Spacer()
                        Circle().fill(scheme.onSurfaceVariant.opacity(0.6)).frame(width: 8, height: 8)
                    }
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 4).fill(scheme.onSurface.opacity(0.12))
                            .overlay(alignment: .topLeading) {
                                HStack(spacing: 0) {
                                    Rectangle().fill(scheme.tertiary).frame(width: 8, height: 6)
                                    Rectangle().fill(scheme.secondary).frame(width: 8, height: 6)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 1.5))
                                .padding(3)
                            }
                        RoundedRectangle(cornerRadius: 4).fill(scheme.onSurface.opacity(0.12))
                    }
                    .frame(height: 64)
                    Spacer(minLength: 0)
                    HStack {
                        ForEach(0..<3, id: \.self) { i in
                            Capsule().fill(i == 0 ? scheme.secondaryContainer : .clear).frame(width: 18, height: 8)
                                .overlay(Circle().fill(i == 0 ? scheme.onSecondaryContainer : scheme.onSurfaceVariant).frame(width: 5, height: 5))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 6)
                    .background(scheme.surfaceContainer)
                    .padding(.horizontal, -8)
                    .padding(.bottom, -8)
                }
                .padding(8)
                .frame(width: 100, height: 160)
                .background(scheme.background)
                .clipShape(RoundedRectangle(cornerRadius: 17))
                .overlay(
                    RoundedRectangle(cornerRadius: 17)
                        .strokeBorder(selected ? colors.primary : colors.outlineVariant, lineWidth: selected ? 4 : 1)
                )
                Text(palette.rawValue)
                    .font(MihonType.bodySmall)
                    .foregroundStyle(colors.onSurface)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .mihonTestAnchor("theme.\(palette.rawValue)")
    }
}

// MARK: - Library / Reader / Duo / Download / Browse settings

private struct LibrarySettingsScreen: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonNavigator) private var navigator
    @Environment(\.mihonColors) private var colors
    @State private var showsUpdateCategories = false

    var body: some View {
        @Bindable var store = store
        MihonSettingsScaffold(title: "书架") {
            MihonPreferenceGroupHeader("分类")
            MihonPreferenceRow(title: "编辑分类", subtitle: "\(store.categories.count - 1) 个分类") {
                navigator.push(.settings(.categories))
            }
            // Upstream "Default category": where a title added to the library goes.
            MihonChipRow("默认分类") {
                MihonFilterChip(label: "每次都问", selected: store.defaultLibraryCategory == -1) {
                    store.defaultLibraryCategory = -1
                }
                MihonFilterChip(label: "默认", selected: store.defaultLibraryCategory == MangaCategory.defaultCategoryId) {
                    store.defaultLibraryCategory = MangaCategory.defaultCategoryId
                }
                ForEach(store.categories.filter { !$0.isSystemCategory }.sorted { $0.order < $1.order }) { category in
                    MihonFilterChip(label: category.name, selected: store.defaultLibraryCategory == category.id) {
                        store.defaultLibraryCategory = category.id
                    }
                }
            }
            MihonPreferenceGroupHeader("全局更新")
            // iOS decides when a background refresh runs: the interval is the earliest, not a promise.
            MihonChipRow("自动更新") {
                ForEach(MihonLibraryUpdateInterval.choices, id: \.self) { hours in
                    MihonFilterChip(label: MihonLibraryUpdateInterval.title(hours: hours), selected: store.autoUpdateInterval == hours) {
                        store.autoUpdateInterval = hours
                        MihonLibraryUpdateScheduler.schedule(store)
                        if hours > 0 {
                            Task { await MihonLibraryUpdateScheduler.requestNotificationPermission() }
                        }
                    }
                }
            }
            // Upstream shows the device restrictions only while automatic updates are on.
            if store.autoUpdateInterval > 0 {
                MihonChipRow("自动更新的系统限制") {
                    ForEach(LibraryUpdateDeviceRestriction.allCases, id: \.self) { restriction in
                        MihonFilterChip(label: restriction.title, selected: store.libraryUpdateDeviceRestrictions.contains(restriction)) {
                            store.libraryUpdateDeviceRestrictions.formSymmetricDifference([restriction])
                        }
                    }
                }
            }
            MihonPreferenceRow(title: "分类", subtitle: updateCategoriesLabel) {
                showsUpdateCategories = true
            }
            .mihonTestAnchor("settings.updateCategories")
            MihonSwitchPreference(
                title: "自动刷新作品信息",
                subtitle: "更新书架时一并检查封面和简介的变动",
                isOn: $store.libraryUpdateRefreshesMetadata
            )
            // Upstream's "Smart update": every library update, manual or automatic, skips these titles.
            MihonChipRow("智能更新") {
                ForEach(LibraryUpdateMangaRestriction.allCases, id: \.self) { rule in
                    MihonFilterChip(label: rule.title, selected: store.libraryUpdateMangaRestrictions.contains(rule)) {
                        store.libraryUpdateMangaRestrictions.formSymmetricDifference([rule])
                    }
                }
            }
            MihonPreferenceRow(title: "立即更新书架", subtitle: store.isUpdatingLibrary ? "正在更新书架…" : nil) {
                Task { await store.refreshLibraryUpdates() }
            }
            MihonPreferenceGroupHeader("显示")
            MihonSwitchPreference(title: "显示分类标签", isOn: $store.showCategoryTabs)
            MihonSwitchPreference(title: "显示作品数", isOn: $store.showMangaCountInCategory)
            MihonSwitchPreference(title: "继续阅读按钮", isOn: $store.showContinueReadingButton)
        }
        .sheet(isPresented: $showsUpdateCategories) {
            MihonCategoryTriStateSheet(
                message: "排除优先于包含，同时属于包含和排除分类的作品不会自动更新。",
                anchorPrefix: "updateCategories",
                included: store.libraryUpdateIncludedCategories,
                excluded: store.libraryUpdateExcludedCategories,
                onSave: { included, excluded in
                    store.libraryUpdateIncludedCategories = included
                    store.libraryUpdateExcludedCategories = excluded
                }
            ) { showsUpdateCategories = false }
                .environment(store)
                .mihonSheetChrome(colors)
        }
    }

    /// Upstream `getCategoriesLabel`: 包含：… / 排除：…
    private var updateCategoriesLabel: String {
        let all = store.categories.sorted { $0.order < $1.order }
        let included = all.filter { store.libraryUpdateIncludedCategories.contains($0.id) }
        let excluded = all.filter { store.libraryUpdateExcludedCategories.contains($0.id) }
        let allExcluded = excluded.count == all.count
        let includedText: String
        if !included.isEmpty && included.count != all.count {
            includedText = included.map(\.visualName).joined(separator: "、")
        } else if included.count == all.count {
            includedText = "全部"
        } else {
            includedText = allExcluded ? "无" : "全部"
        }
        let excludedText = excluded.isEmpty ? "无" : allExcluded ? "全部" : excluded.map(\.visualName).joined(separator: "、")
        return "包含：\(includedText)\n排除：\(excludedText)"
    }
}

/// Upstream's tri-state category list: each category included, excluded or neither. As `TriStateListDialog`
/// (library updates) it saves on 确定; as the upcoming filter (`appliesImmediately`) every tap applies.
struct MihonCategoryTriStateSheet: View {
    var message: String?
    /// Test anchors: `<prefix>.save`, `<prefix>.<category>`.
    let anchorPrefix: String
    var appliesImmediately = false
    let onSave: (_ included: Set<Int64>, _ excluded: Set<Int64>) -> Void
    let onDone: () -> Void
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @State private var included: Set<Int64>
    @State private var excluded: Set<Int64>

    /// Starts on the saved choices, so its first frame is not all unchecked.
    init(
        message: String? = nil,
        anchorPrefix: String,
        appliesImmediately: Bool = false,
        included: Set<Int64>,
        excluded: Set<Int64>,
        onSave: @escaping (_ included: Set<Int64>, _ excluded: Set<Int64>) -> Void,
        onDone: @escaping () -> Void
    ) {
        self.message = message
        self.anchorPrefix = anchorPrefix
        self.appliesImmediately = appliesImmediately
        _included = State(initialValue: included)
        _excluded = State(initialValue: excluded)
        self.onSave = onSave
        self.onDone = onDone
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if !appliesImmediately {
                    Button("取消") { onDone() }
                        .buttonStyle(MihonButtonStyle(.text))
                }
                Spacer()
                Text("分类")
                    .font(MihonType.titleMedium)
                    .foregroundStyle(colors.onSurface)
                Spacer()
                Button(appliesImmediately ? "完成" : "确定") {
                    onSave(included, excluded)
                    onDone()
                }
                .buttonStyle(MihonButtonStyle(.filled))
                .mihonTestAnchor("\(anchorPrefix).save")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            MihonDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let message {
                        Text(message)
                            .font(MihonType.bodyMedium)
                            .foregroundStyle(colors.onSurfaceVariant)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                    }
                    ForEach(store.categories.sorted { $0.order < $1.order }) { category in
                        MihonTriStateItem(category.visualName, state: state(of: category.id))
                            .mihonTestAnchor("\(anchorPrefix).\(category.visualName)")
                    }
                }
            }
        }
    }

    /// The immediate variant saves each tap (upstream `cycleCategory`), so a swipe down keeps it too.
    private func applyIfImmediate() {
        if appliesImmediately { onSave(included, excluded) }
    }

    /// Unchecked → included → excluded, as upstream's tri-state checkbox.
    private func state(of id: Int64) -> Binding<TriStateFilter> {
        Binding(
            get: { included.contains(id) ? .include : excluded.contains(id) ? .exclude : .disabled },
            set: { state in
                included.remove(id)
                excluded.remove(id)
                switch state {
                case .include: included.insert(id)
                case .exclude: excluded.insert(id)
                case .disabled: break
                }
                applyIfImmediate()
            }
        )
    }
}

extension MangaCategory {
    /// Upstream `visualName`: the system category shows as 默认.
    var visualName: String { isSystemCategory ? "默认" : name }
}

private struct ReaderPreferencesScreen: View {
    @Environment(MihonRepositoryStore.self) private var store

    var body: some View {
        @Bindable var store = store
        MihonSettingsScaffold(title: "阅读器") {
            MihonChipRow("默认阅读模式") {
                ForEach(ReadingMode.allCases.filter { $0 != .defaultMode }, id: \.self) { mode in
                    MihonFilterChip(label: mode.shortTitle, selected: store.defaultReadingMode == mode) {
                        store.defaultReadingMode = mode
                    }
                }
            }
            MihonChipRow("点按区域") {
                ForEach(TapZoneType.allCases, id: \.self) { zone in
                    MihonFilterChip(label: zone.localizedTitle, selected: store.readerTapZone == zone) {
                        store.readerTapZone = zone
                    }
                }
            }
            MihonChipRow("背景颜色") {
                ForEach(ReaderBackgroundColor.allCases, id: \.self) { bg in
                    MihonFilterChip(label: bg.rawValue, selected: store.readerBackground == bg) {
                        store.readerBackground = bg
                    }
                }
            }
            MihonSwitchPreference(title: "显示页码", isOn: $store.showPageNumber)
            MihonSwitchPreference(title: "裁剪边缘", isOn: $store.cropBorders)
            MihonSwitchPreference(title: "双击放大", isOn: $store.doubleTapToZoom)
            MihonSwitchPreference(title: "保持屏幕常亮", isOn: $store.keepScreenOn)
            // Upstream's "Reading" group: which chapters previous / next pass over.
            MihonPreferenceGroupHeader("阅读")
            MihonSwitchPreference(title: "跳过已读章节", isOn: $store.skipReadChapters)
            MihonSwitchPreference(title: "跳过筛选掉的章节", isOn: $store.skipFilteredChapters)
            MihonSwitchPreference(title: "跳过重复章节", isOn: $store.skipDuplicateChapters)
        }
    }
}

/// iPhone Duo dual-screen adaptation (no upstream equivalent — styled with the same preference widgets).
private struct DuoSettingsScreen: View {
    @Environment(MihonRepositoryStore.self) private var store

    var body: some View {
        @Bindable var store = store
        MihonSettingsScaffold(title: "iPhone Duo 双屏") {
            MihonChipRow("屏幕形态") {
                ForEach(iPhoneDuoPostureMode.allCases) { posture in
                    MihonFilterChip(label: posture.rawValue, selected: store.duoPostureMode == posture) {
                        withAnimation(.snappy(duration: 0.3)) { store.duoPostureMode = posture }
                    }
                }
            }
            MihonChipRow("双页书本") {
                ForEach(DuoDualPageSpreadBehavior.allCases, id: \.self) { behavior in
                    MihonFilterChip(label: behavior.rawValue, selected: store.duoDualPageBehavior == behavior) {
                        store.duoDualPageBehavior = behavior
                    }
                }
            }
            MihonSwitchPreference(title: "封面单独成页", subtitle: "第 1 页单独显示，之后按 2-3、4-5 配对", isOn: $store.shiftDoublePageCover)
            MihonSwitchPreference(title: "交换左右页顺序", isOn: $store.invertDoublePageOrder)
            MihonSwitchPreference(title: "书脊阴影", subtitle: "在铰链两侧绘制装订处的立体阴影", isOn: $store.showDuoSpineShadow)
            MihonChipRow("翻页效果（仿真卷页：像纸书一样绕书脊翻过去）") {
                ForEach(DuoPageTurnStyle.allCases, id: \.self) { style in
                    MihonFilterChip(label: style.label, selected: store.duoPageTurnStyle == style) {
                        store.duoPageTurnStyle = style
                        store.duoPageTurnStylePicked = true
                    }
                }
            }
            if store.duoPageTurnStyle == .slide {
                MihonSwitchPreference(title: "翻页立体效果", subtitle: "平移时以书脊为轴的 3D 透视", isOn: $store.duoPageTurnEffect)
            }
            MihonSliderItem(
                "铰链宽度",
                value: $store.duoHingeGutterWidth,
                in: 0...36,
                step: 2,
                valueText: "\(Int(store.duoHingeGutterWidth)) pt"
            )
        }
    }
}

private struct DownloadSettingsScreen: View {
    @Environment(MihonRepositoryStore.self) private var store

    var body: some View {
        @Bindable var store = store
        MihonSettingsScaffold(title: "下载") {
            MihonPreferenceGroupHeader("自动下载")
            MihonSwitchPreference(title: "自动下载新章节", subtitle: "书架更新发现新章节时自动下载", isOn: $store.downloadNewChapters)
            // Upstream: only while reading a downloaded chapter whose next one is downloaded too.
            MihonChipRow("阅读时提前下载（正在读已下载的章节时）") {
                ForEach(MihonRepositoryStore.downloadAheadChoices, id: \.self) { count in
                    MihonFilterChip(label: count == 0 ? "关闭" : "\(count) 章", selected: store.downloadAheadCount == count) {
                        store.downloadAheadCount = count
                    }
                }
            }
            MihonPreferenceGroupHeader("删除")
            MihonSwitchPreference(title: "阅读后删除", subtitle: "读完章节后自动删除已下载的章节", isOn: $store.deleteAfterReading)
            MihonPreferenceGroupHeader("MangaDex")
            MihonSwitchPreference(title: "省流模式", subtitle: "使用 data-saver 压缩图片下载与阅读", isOn: $store.mangaDexDataSaver)
        }
    }
}

private struct BrowseSettingsScreen: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @Environment(\.mihonNavigator) private var navigator

    var body: some View {
        @Bindable var store = store
        MihonSettingsScaffold(title: "浏览") {
            if store.showsDemoFeatures {
                MihonPreferenceGroupHeader("插件")
                MihonPreferenceRow(title: "插件仓库", subtitle: "\(store.extensionRepos.count) 个商店") {
                    navigator.push(.settings(.extensionRepos))
                }
            }
            MihonPreferenceGroupHeader("内容过滤")
            MihonSwitchPreference(
                title: "显示 18+ 图源",
                subtitle: store.showsDemoFeatures ? "在列表中显示含有成人内容的图源和插件" : "在列表中显示含有成人内容的图源",
                isOn: $store.showNsfwSources
            )
        }
    }
}

// MARK: - Tracking (1:1 with `SettingsTrackingScreen`)

public struct TrackerServicesSettingsScreen: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors

    public init() {}

    public var body: some View {
        MihonSettingsScaffold(title: "进度记录") {
            MihonPreferenceGroupHeader("服务")
            ForEach(store.trackers) { tracker in
                HStack(spacing: 16) {
                    Image(systemName: tracker.iconSystemName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: MihonShape.small).fill(Color(hexString: tracker.brandColorHex)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tracker.name)
                            .font(.system(size: 16))
                            .foregroundStyle(colors.onSurface)
                        if tracker.isLoggedIn, let username = tracker.username {
                            Text(username)
                                .font(MihonType.bodySmall)
                                .foregroundStyle(colors.onSurfaceVariant)
                        }
                    }
                    Spacer()
                    if tracker.isLoggedIn {
                        Image(systemName: "checkmark")
                            .foregroundStyle(colors.primary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .mihonClickable { store.toggleTrackerLogin(trackerId: tracker.id) }
            }
        }
    }
}

// MARK: - Privacy (1:1 with `SettingsSecurityScreen`)

public struct SecurityAndAdvancedSettingsScreen: View {
    @Environment(MihonRepositoryStore.self) private var store

    public init() {}

    public var body: some View {
        @Bindable var store = store
        MihonSettingsScaffold(title: "隐私") {
            MihonPreferenceGroupHeader("安全")
            // Upstream asks for Face ID / the passcode before the lock is switched either way.
            MihonSwitchPreference(
                title: "需要解锁",
                subtitle: "使用 Face ID 或锁屏密码解锁应用",
                isOn: Binding(get: { store.requireBiometricLock }, set: { enabled in Task { await setRequireUnlock(enabled) } })
            )
            if store.requireBiometricLock {
                MihonChipRow("闲置时锁定") {
                    ForEach(MihonAppLockPolicy.lockAfterChoices, id: \.self) { minutes in
                        MihonFilterChip(label: MihonAppLockPolicy.title(lockAfter: minutes), selected: store.lockAppAfter == minutes) {
                            store.lockAppAfter = minutes
                        }
                    }
                }
            }
            // Upstream also blocks screenshots; iOS only lets an app hide itself in the app switcher.
            MihonChipRow("安全屏幕（切换应用时隐藏内容）") {
                ForEach(SecureScreenMode.allCases) { mode in
                    MihonFilterChip(label: mode.rawValue, selected: store.secureScreen == mode) {
                        store.secureScreen = mode
                    }
                }
            }
            MihonSwitchPreference(title: "无痕模式", subtitle: "暂停记录阅读历史", isOn: $store.incognitoMode)
        }
    }

    private func setRequireUnlock(_ enabled: Bool) async {
        switch await MihonAuthenticator.authenticate(reason: enabled ? "开启应用锁" : "关闭应用锁") {
        case .success:
            store.requireBiometricLock = enabled
        case .unavailable:
            store.showStatusBanner("这台设备没有设置锁屏密码，无法使用应用锁")
        case .failed:
            break
        }
    }
}

// MARK: - About (1:1 with `AboutScreen`)

public struct AboutMihonScreen: View {
    @Environment(\.mihonColors) private var colors
    @Environment(\.openURL) private var openURL

    public init() {}

    /// The installed version and build (e.g. `1.0 (9)`): what a tester quotes when reporting a TestFlight bug.
    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Orihon \(version) (\(build)) · iPhone Duo"
    }

    public var body: some View {
        MihonSettingsScaffold(title: "关于") {
            MihonLogoHeader()
            MihonPreferenceRow(title: "版本", subtitle: Self.versionText)
            // Updates come through TestFlight, with their notes there; rows that would do nothing are left out.
            MihonPreferenceRow(title: "开源许可", subtitle: "Apache License 2.0")
            HStack(spacing: 8) {
                linkIcon("globe", "https://mihon.app")
                linkIcon("chevron.left.forwardslash.chevron.right", "https://github.com/mihonapp/mihon")
                linkIcon("puzzlepiece.extension", "https://keiyoushi.github.io")
            }
            .padding(.vertical, 16)
        }
    }

    private func linkIcon(_ systemName: String, _ urlString: String) -> some View {
        MihonIconButton(systemName, tint: colors.onSurfaceVariant) {
            if let url = URL(string: urlString) { openURL(url) }
        }
    }
}

/// Pushed form of the repository manager (Settings → 浏览 → 插件仓库).
private struct ExtensionReposScreen: View {
    @Environment(\.mihonColors) private var colors
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            MihonTopAppBar(title: "插件仓库", navigation: .back { dismiss() })
            ExtensionRepoAndAPKConfigSheet()
        }
        .background(colors.background)
    }
}
