import SwiftUI
import CoreGraphics
import MihonDomain
import MihonData

// MARK: - Remote image view backed by the two-tier pipeline

/// Loads through `MihonTwoTierImageCache` (memory → disk → network, decode off-main).
/// A memory hit is resolved synchronously in `init`, so cells re-entering the viewport never flash a placeholder.
public struct MihonRemoteImage: View {
    let url: String?
    let target: MihonImageTarget
    var contentMode: ContentMode = .fill
    var placeholder: Color?
    var showsErrorIcon = true
    @State private var image: CGImage?
    @State private var loadedUrl: String?
    @State private var failed = false
    @Environment(\.mihonColors) private var colors

    public init(url: String?, target: MihonImageTarget, contentMode: ContentMode = .fill, placeholder: Color? = nil, showsErrorIcon: Bool = true) {
        self.url = url
        self.target = target
        self.contentMode = contentMode
        self.placeholder = placeholder
        self.showsErrorIcon = showsErrorIcon
        let cached = url.flatMap { MihonTwoTierImageCache.shared.cachedImage(url: $0, target: target) }
        _image = State(initialValue: cached)
        _loadedUrl = State(initialValue: cached == nil ? nil : url)
    }

    public var body: some View {
        // `Color.clear` takes the proposed size so the bitmap never influences layout.
        (placeholder ?? MangaCoverView.placeholderColor)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: contentMode)
                        .transition(.opacity)
                } else if failed && showsErrorIcon {
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundStyle(colors.onSurfaceVariant.opacity(0.5))
                }
            }
            .clipped()
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            image = nil
            return
        }
        if loadedUrl == url, image != nil { return }
        if let hit = MihonTwoTierImageCache.shared.cachedImage(url: url, target: target) {
            image = hit
            loadedUrl = url
            return
        }
        failed = false
        let loaded = await MihonTwoTierImageCache.shared.image(url: url, target: target)
        guard !Task.isCancelled else { return }
        if let loaded {
            withAnimation(.easeOut(duration: 0.3)) {
                image = loaded
            }
            loadedUrl = url
        } else {
            failed = true
        }
    }
}

// MARK: - 1:1 Mihon `MangaCover` (2:3 book / 1:1 square, 4pt corners, `0x1F888888` placeholder)

public struct MangaCoverView: View {
    public let title: String
    public let thumbnailUrl: String?
    public let cornerRadius: CGFloat

    static let placeholderColor = Color(hex: 0x888888, alpha: 0x1F / 255.0)

    public init(title: String, thumbnailUrl: String?, cornerRadius: CGFloat = MihonShape.extraSmall) {
        self.title = title
        self.thumbnailUrl = thumbnailUrl
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        MihonRemoteImage(url: Self.resolveCoverUrl(thumbnailUrl), target: .cover)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityLabel(Text(title))
    }

    /// `mihon-cover://N` is emitted by offline (synthesized) APK catalogues; map it to real artwork.
    public static func resolveCoverUrl(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") || raw.hasPrefix(Page.localImagePrefix)
            || MihonCustomCovers.isCustomCoverUrl(raw) { return raw }
        if raw.hasPrefix("mihon-cover://"), let idx = Int(raw.dropFirst("mihon-cover://".count)) {
            return demoCatalogueCovers[abs(idx) % demoCatalogueCovers.count]
        }
        return nil
    }

    /// AniList artwork for the 8 entries of the offline demo catalogue (same order as `generateCatalogItems`).
    static let demoCatalogueCovers = [
        "https://s4.anilist.co/file/anilistcdn/media/manga/cover/large/bx118586-CXKgWikBFQgS.jpg", // 葬送的芙莉莲
        "https://s4.anilist.co/file/anilistcdn/media/manga/cover/large/bx86082-MXizJxzbijdd.jpg",  // 迷宫饭
        "https://s4.anilist.co/file/anilistcdn/media/manga/cover/large/bx98263-kIeaTXrAbGkj.jpg",  // 尖帽子的魔法工坊
        "https://s4.anilist.co/file/anilistcdn/media/manga/cover/large/bx132029-prGF4gePdSKv.jpg", // 胆大党
        "https://s4.anilist.co/file/anilistcdn/media/manga/cover/large/bx107237-tyQXghsKmE0t.jpg", // 蓝色时期
        "https://s4.anilist.co/file/anilistcdn/media/manga/cover/large/bx102796-wa9ZYchL991E.jpg", // 镖人
        "https://s4.anilist.co/file/anilistcdn/media/manga/cover/large/bx105778-euxXZEIfDY2u.png", // 电锯人
        "https://s4.anilist.co/file/anilistcdn/media/manga/cover/large/bx111258-JWKMq8VGpdiL.jpg"  // 孤独摇滚！
    ]
}

/// Extension / source icon (`ExtensionIcon` / `SourceIcon`).
public struct MihonSourceIconView: View {
    let iconUrl: String?
    var isLocal = false
    var size: CGFloat = 40
    @Environment(\.mihonColors) private var colors

    public init(iconUrl: String?, isLocal: Bool = false, size: CGFloat = 40) {
        self.iconUrl = iconUrl
        self.isLocal = isLocal
        self.size = size
    }

    public var body: some View {
        Group {
            if isLocal {
                Image(systemName: "folder.fill")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(colors.onTertiary)
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: MihonShape.small).fill(colors.tertiary))
            } else if iconUrl != nil {
                MihonRemoteImage(url: iconUrl, target: .icon, contentMode: .fit)
                    .frame(width: size, height: size)
            } else {
                defaultIcon
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: MihonShape.extraSmall, style: .continuous))
    }

    private var defaultIcon: some View {
        Image(systemName: "puzzlepiece.extension.fill")
            .font(.system(size: size * 0.48))
            .foregroundStyle(colors.onSecondaryContainer)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: MihonShape.small).fill(colors.secondaryContainer))
    }
}

// MARK: - Library cover badges (1:1 with `LibraryBadges.kt`)

/// Start group: downloaded count (tertiary) + unread count (secondary).
public struct MihonLibraryStartBadges: View {
    let downloadCount: Int
    let unreadCount: Int
    let showDownload: Bool
    let showUnread: Bool
    @Environment(\.mihonColors) private var colors

    public init(downloadCount: Int, unreadCount: Int, showDownload: Bool, showUnread: Bool) {
        self.downloadCount = downloadCount
        self.unreadCount = unreadCount
        self.showDownload = showDownload
        self.showUnread = showUnread
    }

    public var body: some View {
        let hasDownload = showDownload && downloadCount > 0
        let hasUnread = showUnread && unreadCount > 0
        if hasDownload || hasUnread {
            MihonBadgeGroup {
                if hasDownload {
                    MihonBadge(text: "\(downloadCount)", color: colors.tertiary, contentColor: colors.onTertiary)
                }
                if hasUnread {
                    MihonBadge(text: "\(unreadCount)", color: colors.secondary, contentColor: colors.onSecondary)
                }
            }
        }
    }
}

/// End group: local folder icon or source language code (tertiary).
public struct MihonLibraryEndBadges: View {
    let isLocal: Bool
    let language: String
    let showLocal: Bool
    let showLanguage: Bool
    @Environment(\.mihonColors) private var colors

    public init(isLocal: Bool, language: String, showLocal: Bool, showLanguage: Bool) {
        self.isLocal = isLocal
        self.language = language
        self.showLocal = showLocal
        self.showLanguage = showLanguage
    }

    public var body: some View {
        if isLocal && showLocal {
            MihonBadgeGroup {
                MihonBadge(systemImage: "folder.fill", color: colors.tertiary, contentColor: colors.onTertiary)
            }
        } else if !isLocal && showLanguage && !language.isEmpty {
            MihonBadgeGroup {
                MihonBadge(text: language.uppercased(), color: colors.tertiary, contentColor: colors.onTertiary)
            }
        }
    }
}

// MARK: - Reader page (real image with progress / retry, or the offline demo renderer)

public struct MangaPageImageView: View {
    let page: Page
    let mangaTitle: String
    let chapterTitle: String
    let totalPages: Int
    let cropBorders: Bool
    let colorFilter: ReaderColorFilterState
    let maxPixelSize: Int
    var fitsWidth: Bool = false
    var onAspectRatio: ((CGFloat) -> Void)?

    @State private var image: CGImage?
    @State private var slices: [CGImage] = []
    @State private var failed = false
    @State private var attempt = 0
    @Environment(\.mihonColors) private var colors

    public init(
        page: Page,
        mangaTitle: String,
        chapterTitle: String,
        totalPages: Int,
        cropBorders: Bool,
        colorFilter: ReaderColorFilterState,
        maxPixelSize: Int,
        fitsWidth: Bool = false,
        onAspectRatio: ((CGFloat) -> Void)? = nil
    ) {
        self.page = page
        self.mangaTitle = mangaTitle
        self.chapterTitle = chapterTitle
        self.totalPages = totalPages
        self.cropBorders = cropBorders
        self.colorFilter = colorFilter
        self.maxPixelSize = maxPixelSize
        self.fitsWidth = fitsWidth
        self.onAspectRatio = onAspectRatio
        let target = MihonImageTarget.page(maxPixelSize: maxPixelSize)
        let cached = page.imageUrl.flatMap { MihonTwoTierImageCache.shared.cachedImage(url: $0, target: target, cropBorders: cropBorders) }
        _image = State(initialValue: cached)
        _slices = State(initialValue: cached.map(Self.slices(for:)) ?? [])
    }

    public var body: some View {
        Group {
            if !page.hasRealImage {
                MangaComicPageCanvas(
                    mangaTitle: mangaTitle,
                    chapterTitle: chapterTitle,
                    pageIndex: page.index,
                    totalPages: totalPages,
                    cropBorders: cropBorders,
                    colorFilter: colorFilter
                )
            } else if let image {
                pageBitmap(image)
            } else if failed {
                errorState
            } else {
                loadingState
            }
        }
        .task(id: "\(page.imageUrl ?? "")#\(cropBorders)#\(attempt)") { await load() }
        .modifier(MihonPageContextMenu(page: page, mangaTitle: mangaTitle, chapterTitle: chapterTitle, enabled: image != nil))
    }

    @ViewBuilder
    private func pageBitmap(_ image: CGImage) -> some View {
        let aspect = CGFloat(image.width) / CGFloat(max(1, image.height))
        Group {
            if slices.count > 1 {
                // GPU-safe slices for very long webtoon strips (1:1 with the tall image splitter).
                VStack(spacing: 0) {
                    ForEach(Array(slices.enumerated()), id: \.offset) { _, slice in
                        Image(decorative: slice, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                    }
                }
                .aspectRatio(aspect, contentMode: .fit)
            } else {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
        }
        .modifier(ReaderColorFilterModifier(filter: colorFilter))
        .onAppear { onAspectRatio?(aspect) }
    }

    private var loadingState: some View {
        Color.clear
            .aspectRatio(fitsWidth ? 0.7 : nil, contentMode: .fit)
            .frame(minHeight: fitsWidth ? 320 : nil)
            .overlay {
                VStack(spacing: 12) {
                    MihonCircularProgress(size: 36, lineWidth: 3.5, color: .white.opacity(0.85), trackColor: .white.opacity(0.15))
                    Text("\(page.index + 1)")
                        .font(MihonType.labelMedium)
                        .foregroundStyle(.white.opacity(0.6))
                        .monospacedDigit()
                }
            }
    }

    private var errorState: some View {
        Color.clear
            .aspectRatio(fitsWidth ? 0.7 : nil, contentMode: .fit)
            .frame(minHeight: fitsWidth ? 320 : nil)
            .overlay {
                VStack(spacing: 16) {
                    Text("图片加载失败")
                        .font(MihonType.bodyMedium)
                        .foregroundStyle(.white.opacity(0.8))
                    Button("重试") { attempt += 1 }
                        .buttonStyle(MihonButtonStyle(.filled))
                }
            }
    }

    private func load() async {
        guard page.hasRealImage, let url = page.imageUrl else { return }
        let target = MihonImageTarget.page(maxPixelSize: maxPixelSize)
        if let image, MihonTwoTierImageCache.shared.cachedImage(url: url, target: target, cropBorders: cropBorders) === image {
            return
        }
        failed = false
        let loaded = await MihonTwoTierImageCache.shared.image(url: url, target: target, cropBorders: cropBorders)
        guard !Task.isCancelled else { return }
        if let loaded {
            let pieces = await Task.detached(priority: .userInitiated) { Self.slices(for: loaded) }.value
            withAnimation(.easeOut(duration: 0.2)) {
                image = loaded
                slices = pieces
            }
        } else {
            failed = true
        }
    }

    nonisolated static func slices(for image: CGImage) -> [CGImage] {
        image.height > 8192 ? MihonImageProcessor.splitTallWebtoonImage(image, maxSliceHeight: 4096) : []
    }
}

/// Grayscale / brightness / tint overlay (1:1 with the reader "Custom filter" page).
struct ReaderColorFilterModifier: ViewModifier {
    let filter: ReaderColorFilterState

    func body(content: Content) -> some View {
        if filter.isEnabled {
            content
                .saturation(filter.grayscale ? 0 : 1)
                .brightness(filter.customBrightness)
                .colorInvert(filter.inverted)
                .overlay {
                    if filter.overlayAlpha > 0 {
                        Color(red: filter.redOverlay, green: filter.greenOverlay, blue: filter.blueOverlay)
                            .opacity(filter.overlayAlpha)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            content
        }
    }
}

private extension View {
    @ViewBuilder
    func colorInvert(_ enabled: Bool) -> some View {
        if enabled { self.colorInvert() } else { self }
    }
}

// MARK: - Offline demo page renderer (used by synthesized sources that have no real page images)

public struct MangaComicPageCanvas: View {
    public let mangaTitle: String
    public let chapterTitle: String
    public let pageIndex: Int
    public let totalPages: Int
    public let cropBorders: Bool
    public let colorFilter: ReaderColorFilterState

    public init(
        mangaTitle: String,
        chapterTitle: String,
        pageIndex: Int,
        totalPages: Int,
        cropBorders: Bool,
        colorFilter: ReaderColorFilterState
    ) {
        self.mangaTitle = mangaTitle
        self.chapterTitle = chapterTitle
        self.pageIndex = pageIndex
        self.totalPages = totalPages
        self.cropBorders = cropBorders
        self.colorFilter = colorFilter
    }

    private var dialogueLines: (topRight: String, middleLeft: String, bottomAction: String) {
        let dialogues: [(String, String, String)] = [
            ("「这就是勇者辛美尔曾经看过的风景吗……」", "「哪怕经过五十年，苍月草依然盛开。」", "—— 记忆的回响 ——"),
            ("「等等！这只魔物如果用黄油香煎的话……」", "「莱欧斯！现在不是研究食谱的时候！」", "—— 滋滋作响的迷宫篝火 ——"),
            ("「魔法不是天生的奇迹，而是由笔尖描绘的法则！」", "「只要画下闭合的圆环，魔力就会苏醒。」", "—— 禁忌工坊的试炼 ——"),
            ("「前方的气场不对，握紧你的刀！」", "「知世郎说过，风暴已经在长安城外聚集了。」", "—— 大漠黄沙 · 破阵之刻 ——")
        ]
        let seed = Int(StableHash.fnv1a64(mangaTitle) % 1024)
        return dialogues[(pageIndex + seed) % dialogues.count]
    }

    public var body: some View {
        let paddingAmount: CGFloat = cropBorders ? 2 : 14

        ZStack {
            Color(white: 0.97)

            VStack(spacing: 8) {
                HStack {
                    Text(mangaTitle)
                        .font(.caption2.bold())
                        .foregroundStyle(.black.opacity(0.6))
                    Spacer()
                    Text("\(chapterTitle) · P.\(pageIndex + 1)/\(totalPages)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.black.opacity(0.6))
                        .lineLimit(1)
                }
                .padding(.horizontal, 4)

                ZStack {
                    Rectangle()
                        .fill(LinearGradient(colors: [Color(white: 0.88), Color(white: 0.95)], startPoint: .top, endPoint: .bottom))
                        .overlay(Rectangle().stroke(Color.black, lineWidth: 2.2))

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: pageIndex % 2 == 0 ? "sparkles" : "wind")
                                .font(.system(size: 38, weight: .black))
                                .foregroundStyle(.black.opacity(0.75))
                            Text("ゴゴゴゴ")
                                .font(.system(size: 13, weight: .heavy, design: .serif))
                                .foregroundStyle(.black.opacity(0.7))
                        }
                        .padding(.leading, 18)

                        Spacer()

                        Text(dialogueLines.topRight)
                            .font(.system(size: 13, weight: .semibold, design: .serif))
                            .foregroundStyle(.black)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 22)
                                    .fill(Color.white)
                                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.black, lineWidth: 1.8))
                            )
                            .frame(maxWidth: 210)
                            .padding(.trailing, 14)
                    }
                }
                .frame(maxHeight: .infinity)

                HStack(spacing: 8) {
                    ZStack {
                        Rectangle()
                            .fill(Color(white: 0.92))
                            .overlay(Rectangle().stroke(Color.black, lineWidth: 2.2))

                        VStack(spacing: 10) {
                            Text(dialogueLines.middleLeft)
                                .font(.system(size: 12, weight: .medium, design: .serif))
                                .foregroundStyle(.black)
                                .padding(10)
                                .background(Ellipse().fill(Color.white).overlay(Ellipse().stroke(Color.black, lineWidth: 1.5)))
                                .padding(.horizontal, 8)

                            Image(systemName: pageIndex % 3 == 0 ? "eye.fill" : "bolt.horizontal.fill")
                                .font(.system(size: 32, weight: .bold))
                                .foregroundStyle(.black.opacity(0.8))
                        }
                    }

                    ZStack {
                        Rectangle()
                            .fill(Color(white: 0.20))
                            .overlay(Rectangle().stroke(Color.black, lineWidth: 2.2))

                        VStack(spacing: 8) {
                            Image(systemName: "moon.stars.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(.white)
                            Text("第 \(pageIndex + 1) 幕")
                                .font(.system(size: 14, weight: .black, design: .serif))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 130)
                }
                .frame(maxHeight: .infinity)

                ZStack {
                    Rectangle()
                        .fill(Color(white: 0.90))
                        .overlay(Rectangle().stroke(Color.black, lineWidth: 2.2))

                    VStack(spacing: 8) {
                        HStack {
                            Text("ドドドド!!")
                                .font(.system(size: 20, weight: .black))
                                .italic()
                                .foregroundStyle(.black)
                            Spacer()
                        }
                        .padding(.horizontal, 16)

                        Text(dialogueLines.bottomAction)
                            .font(.system(size: 13, weight: .bold, design: .serif))
                            .foregroundStyle(.black.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.9))
                            .border(Color.black, width: 1.2)
                    }
                }
                .frame(height: 120)

                Text("— \(pageIndex + 1) —")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(.black.opacity(0.75))
            }
            .padding(paddingAmount)
        }
        .aspectRatio(0.707, contentMode: .fit)
        .modifier(ReaderColorFilterModifier(filter: colorFilter))
    }
}
