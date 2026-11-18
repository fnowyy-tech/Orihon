import Foundation
import MihonDomain
import MihonAPKEngine

// MARK: - Local source (upstream `source-local`)

/// Upstream's local source (id 0): manga the user keeps as files. Each folder in the local directory is a title; its
/// folders of images and its ZIP / CBZ archives are the chapters. `cover.*` in the title folder is the cover (else
/// the first page of the first chapter); `ComicInfo.xml` — in the folder or in a chapter archive — or a legacy
/// `details.json` fills in the details. Files are read where they are and never cached or deleted by the app.
public struct MihonLocalSource: LiveSourceEngine {
    public static let sourceId: Int64 = 0
    public static let baseUrl = Page.localImagePrefix
    public static let helpUrl = "https://mihon.app/docs/guides/local-source/"
    /// Upstream's "latest": titles changed within a week.
    static let latestThreshold: TimeInterval = 7 * 24 * 3600
    public static let archiveExtensions: Set<String> = ["zip", "cbz", "epub"]
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "jfif", "png", "gif", "webp", "avif", "heic", "heif", "bmp", "jxl", "jp2", "tif", "tiff",
    ]
    /// One page; stops a damaged archive from claiming gigabytes.
    static let maxPageSize = 64 << 20

    public static func handles(baseUrl: String) -> Bool { baseUrl == Self.baseUrl }

    let root: URL

    public init(root: URL = MihonLocalStorage.defaultRootDirectory) {
        self.root = root
    }

    public func popularManga(page: Int) async throws -> MangasPage {
        try await searchManga(page: page, query: "", filters: [])
    }

    public func latestUpdates(page: Int) async throws -> MangasPage {
        let limit = Date().addingTimeInterval(-Self.latestThreshold)
        let titles = Self.items(in: root)
            .filter { $0.isDirectory && $0.modified >= limit }
            .sorted { $0.modified > $1.modified }
        return MangasPage(mangas: page > 1 ? [] : titles.map(manga(for:)), hasNextPage: false)
    }

    public func searchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let titles = Self.items(in: root)
            .filter { $0.isDirectory && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return MangasPage(mangas: page > 1 ? [] : titles.map(manga(for:)), hasNextPage: false)
    }

    public func mangaDetails(manga: SManga) async throws -> SManga {
        guard let directory = resolve(manga.url), Self.isDirectory(directory) else {
            throw MihonLocalSourceError.titleNotFound(manga.url)
        }
        var details = manga
        details.initialized = true
        let items = Self.items(in: directory)
        details.thumbnailUrl = coverUrl(titleUrl: manga.url, items: items) ?? manga.thumbnailUrl
        if let xml = items.first(where: { !$0.isDirectory && $0.name.caseInsensitiveCompare("ComicInfo.xml") == .orderedSame }),
           let data = try? Data(contentsOf: xml.url) {
            Self.apply(comicInfo: data, to: &details)
        } else if let json = items.first(where: { !$0.isDirectory && $0.pathExtension == "json" }),
                  let data = try? Data(contentsOf: json.url) {
            Self.apply(legacyDetails: data, to: &details)
        } else if let data = Self.comicInfoInArchives(items) {
            Self.apply(comicInfo: data, to: &details)
        }
        return details
    }

    public func chapterList(manga: SManga) async throws -> [SChapter] {
        guard let directory = resolve(manga.url), Self.isDirectory(directory) else {
            throw MihonLocalSourceError.titleNotFound(manga.url)
        }
        // Upstream: by name (after the chapters' own metadata renamed them), newest (last) first — not by number,
        // which restarts each season or volume.
        return Self.items(in: directory).filter(Self.isChapter).map { item in
            var chapter = SChapter(
                url: "\(manga.url)/\(item.name)",
                name: item.chapterName,
                dateUpload: item.modified,
                chapterNumber: ChapterRecognition.parseChapterNumber(mangaTitle: manga.title, chapterName: item.chapterName)
            )
            if item.pathExtension == "epub" {
                if let archive = try? MihonZipArchive.cached(at: item.url) { Self.applyEpubMetadata(archive, to: &chapter) }
            } else if let data = Self.chapterComicInfo(item) {
                Self.apply(chapterComicInfo: data, to: &chapter)
            }
            return chapter
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
    }

    public func pageList(chapter: SChapter) async throws -> [Page] {
        guard let file = resolve(chapter.url), FileManager.default.fileExists(atPath: file.path) else {
            throw MihonLocalSourceError.chapterNotFound(chapter.url)
        }
        return try Self.pageUrls(chapterPath: chapter.url, file: file, isDirectory: Self.isDirectory(file))
            .enumerated()
            .map { Page(index: $0.offset, url: chapter.url, imageUrl: $0.element) }
    }

    public func mangaWebUrl(manga: SManga) -> String { "" }

    // MARK: Titles, chapters, pages

    struct Item {
        let url: URL
        let name: String
        let isDirectory: Bool
        let modified: Date

        var pathExtension: String { (name as NSString).pathExtension.lowercased() }
        /// Upstream names a chapter after its folder, or its file without the extension.
        var chapterName: String { isDirectory ? name : (name as NSString).deletingPathExtension }
    }

    /// The visible entries of a folder (no dot files, so no `.DS_Store` or AppleDouble `._` files, and no
    /// `__MACOSX` folder from archives made on a Mac). Symbolic links count as what they point at.
    static func items(in directory: URL) -> [Item] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory.resolvingSymlinksInPath(), includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter { $0.lastPathComponent != "__MACOSX" }.map { url in
            let target = url.resolvingSymlinksInPath()
            return Item(
                url: url,
                name: url.lastPathComponent,
                isDirectory: isDirectory(target),
                modified: (try? target.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            )
        }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func isChapter(_ item: Item) -> Bool {
        item.isDirectory || archiveExtensions.contains(item.pathExtension)
    }

    /// By file name, as upstream's `ImageUtil.isImage`; macOS's `__MACOSX` / `._` resource forks are not pages.
    static func isImageName(_ name: String) -> Bool {
        let fileName = (name as NSString).lastPathComponent
        guard !fileName.hasPrefix("."), !name.hasPrefix("__MACOSX/") else { return false }
        return imageExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    /// Pages in upstream's order: case-insensitive natural order of the file (or archive entry) names.
    static func pageUrls(chapterPath: String, file: URL, isDirectory: Bool) throws -> [String] {
        if isDirectory {
            return items(in: file)
                .filter { !$0.isDirectory && isImageName($0.name) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { pageUrl(path: "\(chapterPath)/\($0.name)", version: version(of: $0.url)) }
        }
        let archive = try MihonZipArchive.cached(at: file)
        let archiveVersion = version(of: file)
        if file.pathExtension.lowercased() == "epub" {
            return epubImages(archive).map { pageUrl(path: chapterPath, entry: $0, version: archiveVersion) }
        }
        return archive.entries
            .filter { !$0.isDirectory && isImageName($0.name) }
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { pageUrl(path: chapterPath, entry: $0, version: archiveVersion) }
    }

    /// Modification time and size: a file replaced under the same name gets new page URLs.
    static func version(of file: URL) -> String? {
        guard let values = try? file.resolvingSymlinksInPath().resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate else { return nil }
        return "\(Int64(modified.timeIntervalSince1970 * 1000))-\(values.fileSize ?? 0)"
    }

    func manga(for title: Item) -> SManga {
        SManga(
            url: title.name,
            title: title.name,
            thumbnailUrl: coverUrl(titleUrl: title.name, items: Self.items(in: title.url)),
            initialized: false
        )
    }

    /// `cover.*` (upstream `LocalCoverManager.find`), else the first page of the first chapter. Upstream copies that
    /// page into the folder as `cover.jpg`; pointing at it instead leaves the user's folder as it was.
    func coverUrl(titleUrl: String, items: [Item]) -> String? {
        if let cover = items.first(where: {
            !$0.isDirectory && ($0.name as NSString).deletingPathExtension.lowercased() == "cover" && Self.isImageName($0.name)
        }) {
            return Self.pageUrl(path: "\(titleUrl)/\(cover.name)", version: Self.version(of: cover.url))
        }
        // The first chapter in upstream's (name) order.
        let chapters = items.filter(Self.isChapter).sorted { $0.chapterName.localizedStandardCompare($1.chapterName) == .orderedAscending }
        for chapter in chapters.prefix(3) {
            let pages = try? Self.pageUrls(chapterPath: "\(titleUrl)/\(chapter.name)", file: chapter.url, isDirectory: chapter.isDirectory)
            if let first = pages?.first { return first }
        }
        return nil
    }

    /// A path from a manga / chapter URL, inside the local folder only.
    func resolve(_ relativePath: String) -> URL? {
        Self.resolve(relativePath, root: root)
    }

    static func resolve(_ relativePath: String, root: URL) -> URL? {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }

    // MARK: Page URLs

    /// `mihon-local:/<title>/<chapter>` for a file, `…#<entry>` for an entry of a ZIP / CBZ, with `?v=<version>`
    /// before that so a replaced file is not shown from the cache. Relative to the local folder: iOS moves the app's
    /// container on reinstall.
    public static func pageUrl(path: String, entry: String? = nil, version: String? = nil) -> String {
        var url = baseUrl + (path.addingPercentEncoding(withAllowedCharacters: urlAllowed) ?? path)
        if let version { url += "?v=" + version }
        guard let entry else { return url }
        return url + "#" + (entry.addingPercentEncoding(withAllowedCharacters: urlAllowed) ?? entry)
    }

    static let urlAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")

    static func parse(_ url: String) -> (path: String, entry: String?)? {
        guard url.hasPrefix(baseUrl) else { return nil }
        let parts = url.dropFirst(baseUrl.count).split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        // A literal "?" starts the version (one in a file name is percent-encoded).
        let encodedPath = parts.first.map { $0.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0] }
        guard let path = encodedPath.flatMap({ String($0).removingPercentEncoding }), !path.isEmpty else { return nil }
        let entry = parts.count > 1 ? String(parts[1]).removingPercentEncoding : nil
        return (path, entry)
    }

    /// The bytes behind a page URL: a file in the local folder or an entry of an archive there; nil when gone.
    public static func data(forUrl url: String, root: URL = MihonLocalStorage.defaultRootDirectory) -> Data? {
        guard let (path, entryName) = parse(url), let file = resolve(path, root: root) else { return nil }
        guard let entryName else {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= maxPageSize else { return nil }
            return try? Data(contentsOf: file)
        }
        guard let archive = try? MihonZipArchive.cached(at: file),
              let entry = archive.entries.first(where: { $0.name == entryName }) else { return nil }
        return try? archive.data(for: entry, limit: maxPageSize)
    }

    // MARK: Metadata

    /// The first chapter archive's `ComicInfo.xml` (upstream copies it next to the chapters; it is only read here).
    static func comicInfoInArchives(_ items: [Item]) -> Data? {
        let archives = items
            .filter { !$0.isDirectory && archiveExtensions.contains($0.pathExtension) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for item in archives.prefix(5) {
            guard let archive = try? MihonZipArchive.cached(at: item.url),
                  let entry = archive.entries.first(where: { $0.name.caseInsensitiveCompare("ComicInfo.xml") == .orderedSame })
            else { continue }
            return try? archive.data(for: entry, limit: 1 << 20)
        }
        return nil
    }

    // MARK: Chapter metadata

    /// A chapter's own `ComicInfo.xml`: in its folder, or in its archive (upstream `getComicInfoForChapter`).
    static func chapterComicInfo(_ item: Item) -> Data? {
        if item.isDirectory {
            guard let file = items(in: item.url).first(where: { !$0.isDirectory && $0.name.caseInsensitiveCompare("ComicInfo.xml") == .orderedSame })
            else { return nil }
            return try? Data(contentsOf: file.url)
        }
        guard let archive = try? MihonZipArchive.cached(at: item.url),
              let entry = archive.entries.first(where: { $0.name.caseInsensitiveCompare("ComicInfo.xml") == .orderedSame })
        else { return nil }
        return try? archive.data(for: entry, limit: 1 << 20)
    }

    /// Upstream `setChapterDetailsFromComicInfoFile`: title, number, translator and a (partial) date.
    static func apply(chapterComicInfo data: Data, to chapter: inout SChapter) {
        let values = ComicInfoReader.values(of: data)
        if let title = values["Title"] { chapter.name = title }
        if let number = values["Number"].flatMap(Double.init) { chapter.chapterNumber = number }
        if let translator = values["Translator"] { chapter.scanlator = translator }
        // Only with a year; month and day default to the first.
        guard let year = values["Year"].flatMap(Int.init), year > 0 else { return }
        var parts = DateComponents()
        parts.year = year
        parts.month = min(max(values["Month"].flatMap(Int.init) ?? 1, 1), 12)
        parts.day = min(max(values["Day"].flatMap(Int.init) ?? 1, 1), 31)
        if let date = Calendar.current.date(from: parts) { chapter.dateUpload = date }
    }

    // MARK: EPUB (upstream `EpubReader`)

    /// The package document's path: META-INF/container.xml's rootfile, else upstream's guess.
    static func epubPackagePath(_ archive: MihonZipArchive) -> String {
        if let data = epubEntry(archive, "META-INF/container.xml"),
           let path = EpubXMLReader.read(data).attributes(of: "rootfile").first?["full-path"], !path.isEmpty {
            return path
        }
        return "OEBPS/content.opf"
    }

    /// Upstream `getImagesFromPages`: the spine's XHTML pages in order, and every `img` / SVG `image` on them.
    static func epubImages(_ archive: MihonZipArchive) -> [String] {
        let packagePath = epubPackagePath(archive)
        guard let package = epubEntry(archive, packagePath) else { return [] }
        let opf = EpubXMLReader.read(package)
        var pagesById: [String: String] = [:]
        for item in opf.attributes(of: "item") where item["media-type"] == "application/xhtml+xml" {
            if let id = item["id"], let href = item["href"] { pagesById[id] = href }
        }
        let pages = opf.attributes(of: "itemref").compactMap { $0["idref"].flatMap { pagesById[$0] } }
        let base = parentDirectory(packagePath)
        var images: [String] = []
        for page in pages {
            let entryPath = resolve(page, from: base)
            guard let data = epubEntry(archive, entryPath) else { continue }
            let imageBase = parentDirectory(entryPath)
            let document = HTMLDocument(html: String(decoding: data, as: UTF8.self))
            func walk(_ element: HTMLElement) {
                switch element.tag {
                case "img": images.append(resolve(element.attr("src"), from: imageBase))
                case "image": images.append(resolve(element.attr("xlink:href"), from: imageBase))
                default: break
                }
                element.children.forEach(walk)
            }
            walk(document.root)
        }
        return images.filter { !$0.isEmpty }
    }

    /// Upstream `fillMetadata`: the chapter's name, scanlator (publisher, else creator) and date.
    static func applyEpubMetadata(_ archive: MihonZipArchive, to chapter: inout SChapter) {
        guard let package = epubEntry(archive, epubPackagePath(archive)) else { return }
        let opf = EpubXMLReader.read(package)
        if let title = opf.text(of: "title") { chapter.name = title }
        if let scanlator = opf.text(of: "publisher") ?? opf.text(of: "creator") { chapter.scanlator = scanlator }
        let date = opf.text(of: "date") ?? opf.metaText(property: "dcterms:modified")
        if let date, let parsed = ISO8601DateFormatter().date(from: date) { chapter.dateUpload = parsed }
    }

    /// An entry by name, percent-escapes undone (hrefs are URLs).
    static func epubEntry(_ archive: MihonZipArchive, _ name: String) -> Data? {
        let decoded = name.removingPercentEncoding ?? name
        guard let entry = archive.entries.first(where: { $0.name == decoded || $0.name == name }) else { return nil }
        return try? archive.data(for: entry, limit: maxPageSize)
    }

    /// Upstream `resolveZipPath`: a relative href against a folder in the archive (`..` and `.` folded).
    static func resolve(_ href: String, from base: String) -> String {
        let clean = href.components(separatedBy: "#")[0].removingPercentEncoding ?? href
        guard !clean.isEmpty else { return "" }
        var parts = clean.hasPrefix("/") ? [] : base.split(separator: "/").map(String.init)
        for part in clean.split(separator: "/").map(String.init) {
            switch part {
            case ".", "": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }

    static func parentDirectory(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// Upstream `SManga.copyFromComicInfo`.
    static func apply(comicInfo data: Data, to manga: inout SManga) {
        let values = ComicInfoReader.values(of: data)
        func list(_ keys: [String], separator: String) -> [String] {
            var seen: Set<String> = []
            return keys.compactMap { values[$0] }
                .flatMap { $0.components(separatedBy: separator) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        if let series = values["Series"] { manga.title = series }
        if let writer = values["Writer"] { manga.author = writer }
        if let summary = values["Summary"] { manga.description = summary }
        let genres = list(["Genre", "Tags", "Categories"], separator: ",")
        if !genres.isEmpty { manga.genre = genres }
        let artists = list(["Penciller", "Inker", "Colorist", "Letterer", "CoverArtist"], separator: ", ")
        if !artists.isEmpty { manga.artist = artists.joined(separator: ", ") }
        manga.status = publishingStatus(values["PublishingStatusTachiyomi"])
    }

    /// Upstream `ComicInfoPublishingStatus`.
    static func publishingStatus(_ value: String?) -> MangaStatus {
        switch value?.lowercased() {
        case "ongoing": return .ongoing
        case "completed": return .completed
        case "licensed": return .licensed
        case "publishing finished": return .publishingFinished
        case "cancelled": return .cancelled
        case "on hiatus": return .onHiatus
        default: return .unknown
        }
    }

    /// Tachiyomi's old `details.json` (title, author, artist, description, genre[], status 0–6 as number or text).
    static func apply(legacyDetails data: Data, to manga: inout SManga) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        func text(_ key: String) -> String? {
            (object[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        if let title = text("title") { manga.title = title }
        if let author = text("author") { manga.author = author }
        if let artist = text("artist") { manga.artist = artist }
        if let description = text("description") { manga.description = description }
        if let genre = object["genre"] as? [String], !genre.isEmpty { manga.genre = genre }
        let status = (object["status"] as? Int) ?? (object["status"] as? String).flatMap(Int.init)
        if let status, let value = MangaStatus(rawValue: status) { manga.status = value }
    }
}

public enum MihonLocalSourceError: Error, LocalizedError {
    case titleNotFound(String)
    case chapterNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .titleNotFound(let name): return "找不到本地作品「\(name)」的文件夹"
        case .chapterNotFound(let path): return "找不到本地章节「\(path)」"
        }
    }
}

/// An EPUB's XML (container, package document): elements by local name with their attributes and text.
final class EpubXMLReader: NSObject, XMLParserDelegate {
    private var elements: [(name: String, attributes: [String: String], text: String)] = []
    private var open: [Int] = []

    static func read(_ data: Data) -> EpubXMLReader {
        let reader = EpubXMLReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader
    }

    func attributes(of name: String) -> [[String: String]] {
        elements.filter { $0.name == name }.map(\.attributes)
    }

    func text(of name: String) -> String? {
        elements.first { $0.name == name && !$0.text.isEmpty }?.text
    }

    func metaText(property: String) -> String? {
        elements.first { $0.name == "meta" && $0.attributes["property"] == property && !$0.text.isEmpty }?.text
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        open.append(elements.count)
        elements.append((name, attributeDict, ""))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if let index = open.last { elements[index].text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if let index = open.popLast() {
            elements[index].text = elements[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// The text of each element of a `ComicInfo.xml`, by local name (`ty:PublishingStatusTachiyomi` →
/// `PublishingStatusTachiyomi`); the first occurrence wins.
final class ComicInfoReader: NSObject, XMLParserDelegate {
    private var values: [String: String] = [:]
    private var text = ""

    static func values(of data: Data) -> [String: String] {
        let reader = ComicInfoReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.values
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let key = elementName.split(separator: ":").last.map(String.init) ?? elementName
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty && values[key] == nil { values[key] = value }
        text = ""
    }
}

// MARK: - Local folder & import

/// Where the local source keeps titles: `Documents/local` on iOS — the Files app lists it under
/// 「我的 iPhone › Orihon」 (`UIFileSharingEnabled`) — and Application Support on a Mac. Under XCTest it is a
/// temporary folder, like `MihonTwoTierImageCache.shared`.
public enum MihonLocalStorage {
    public static let defaultRootDirectory: URL = {
        let fileManager = FileManager.default
        if NSClassFromString("XCTestCase") != nil {
            return fileManager.temporaryDirectory
                .appendingPathComponent("MihonTests-\(ProcessInfo.processInfo.processIdentifier)/local", isDirectory: true)
        }
        #if os(iOS)
        let base = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("local", isDirectory: true)
        #else
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("Mihon-iOS/local", isDirectory: true)
        #endif
    }()

    /// Created at launch, so the folder is there to drop files into before anything was imported.
    public static func createRootDirectory(_ root: URL = defaultRootDirectory) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public struct ImportResult: Sendable, Equatable {
        /// The title folders that received chapters.
        public var titles: [String] = []
        public var chapters = 0
        /// Chapters already there (by file name): never overwritten.
        public var skipped = 0
        /// Picked files that are neither folders nor ZIP / CBZ archives, or could not be copied.
        public var failed = 0

        public init() {}
    }

    /// Copies picked files into the local folder. A picked folder becomes a title — its folders and archives the
    /// chapters, or itself the only chapter when it holds just images; picked archives become chapters of `title`.
    /// Blocking file I/O: call it off the main thread.
    public static func importItems(_ urls: [URL], intoTitle title: String?, root: URL = defaultRootDirectory) -> ImportResult {
        var result = ImportResult()
        let fileManager = FileManager.default
        createRootDirectory(root)
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        func copy(_ source: URL, into titleName: String, as name: String? = nil) {
            let titleDirectory = root.appendingPathComponent(titleName, isDirectory: true)
            let destination = titleDirectory.appendingPathComponent(name ?? source.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                result.skipped += 1
                return
            }
            do {
                try fileManager.createDirectory(at: titleDirectory, withIntermediateDirectories: true)
                try fileManager.copyItem(at: source, to: destination)
                if !result.titles.contains(titleName) { result.titles.append(titleName) }
                result.chapters += 1
            } catch {
                result.failed += 1
            }
        }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // The local folder, a title in it, or a folder holding it (the app's own folder in Files): copying it
            // into itself would nest without end.
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            if path == rootPath || path.hasPrefix(rootPath + "/") || rootPath.hasPrefix(path + "/") {
                result.failed += 1
                continue
            }
            if MihonLocalSource.isDirectory(url) {
                let titleName = sanitizedTitle(url.lastPathComponent)
                let children = MihonLocalSource.items(in: url)
                let hasArchives = children.contains { !$0.isDirectory && MihonLocalSource.isChapter($0) }
                let hasPages = children.contains {
                    !$0.isDirectory && MihonLocalSource.isImageName($0.name) && ($0.name as NSString).deletingPathExtension.lowercased() != "cover"
                }
                if hasPages && !hasArchives {
                    // Pages right in the folder: it is a chapter (of a title named after it), whatever else it holds.
                    copy(url, into: titleName)
                } else if children.contains(where: MihonLocalSource.isChapter) {
                    for child in children where MihonLocalSource.isChapter(child) {
                        copy(child.url, into: titleName)
                    }
                    // The title's own files: cover and metadata.
                    for child in children where !child.isDirectory && !MihonLocalSource.isChapter(child) {
                        let base = (child.name as NSString).deletingPathExtension.lowercased()
                        let destination = root.appendingPathComponent(titleName).appendingPathComponent(child.name)
                        if (base == "cover" || base == "comicinfo" || child.pathExtension == "json"),
                           !fileManager.fileExists(atPath: destination.path) {
                            try? fileManager.copyItem(at: child.url, to: destination)
                        }
                    }
                } else {
                    result.failed += 1
                }
            } else if MihonLocalSource.archiveExtensions.contains(url.pathExtension.lowercased()) {
                copy(url, into: sanitizedTitle(title ?? suggestedTitle(for: [url])))
            } else {
                result.failed += 1
            }
        }
        return result
    }

    /// A title for picked archives: the first one's `ComicInfo.xml` series, else its name without volume or chapter
    /// numbering (「海贼王 第01卷」→「海贼王」, "Blame! v01 (2016) [Digital]" → "Blame!").
    public static func suggestedTitle(for urls: [URL]) -> String {
        guard let first = urls.first else { return "" }
        let scoped = first.startAccessingSecurityScopedResource()
        defer { if scoped { first.stopAccessingSecurityScopedResource() } }
        if let archive = try? MihonZipArchive(url: first),
           let entry = archive.entries.first(where: { $0.name.caseInsensitiveCompare("ComicInfo.xml") == .orderedSame }),
           let data = try? archive.data(for: entry, limit: 1 << 20),
           let series = ComicInfoReader.values(of: data)["Series"] {
            return series
        }
        let name = first.deletingPathExtension().lastPathComponent
        var title = name
        func strip(_ pattern: String, repeatedly: Bool) {
            while let range = title.range(of: pattern, options: [.regularExpression, .caseInsensitive]), !range.isEmpty {
                title.removeSubrange(range)
                if !repeatedly { break }
            }
        }
        let groupPrefix = #"^\s*[\[【][^\[\]【】]*[\]】]\s*"#  // "[Scanlator] …"
        let groupSuffix = #"\s*[\(\[【（][^\(\)\[\]【】（）]*[\)\]】）]\s*$"#  // "… (2016) [Digital]"
        // Once only: "Gantz 2 v03" keeps its "2".
        let numbering = #"[\s_\-.]*(?:vol(?:ume)?|v|ch(?:apter)?|c|ep|第)?[\s_.]*\d+(?:\.\d+)?\s*(?:卷|话|話|集|章|册|冊)?$"#
        strip(groupPrefix, repeatedly: true)
        strip(groupSuffix, repeatedly: true)
        strip(numbering, repeatedly: false)
        strip(groupSuffix, repeatedly: true)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " _-.").union(.whitespacesAndNewlines))
        return title.isEmpty ? name : title
    }

    /// A folder name: no path separators, no leading dot (hidden), never empty.
    public static func sanitizedTitle(_ title: String) -> String {
        var name = title.replacingOccurrences(of: "/", with: "／").replacingOccurrences(of: ":", with: "：")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? "未命名" : name
    }
}

// MARK: - ZIP / CBZ on disk

/// Random access to a ZIP / CBZ file: the central directory is read once, then one entry at a time, so a 500 MB
/// volume never sits in memory (`APKBinaryDexInspector` reads a whole APK, which is small). ZIP64, the UTF-8 flag,
/// Info-ZIP Unicode paths and GBK names (archives made on Chinese Windows) are understood; encrypted entries are not.
public final class MihonZipArchive: @unchecked Sendable {
    public struct Entry: Sendable, Hashable {
        public let name: String
        public let uncompressedSize: UInt64
        let compressedSize: UInt64
        let method: UInt16
        let flags: UInt16
        let localHeaderOffset: UInt64

        public var isDirectory: Bool { name.hasSuffix("/") }
    }

    public enum Failure: Error, LocalizedError {
        case notAZip
        case damaged
        case encrypted
        case unsupportedMethod(UInt16)
        case tooLarge

        public var errorDescription: String? {
            switch self {
            case .notAZip: return "不是有效的 ZIP / CBZ 文件"
            case .damaged: return "压缩包已损坏"
            case .encrypted: return "不支持加密的压缩包"
            case .unsupportedMethod(let method): return "不支持的压缩方式（\(method)）"
            case .tooLarge: return "压缩包里的文件过大"
            }
        }
    }

    public let url: URL
    public let entries: [Entry]

    public init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        // The end record (22 bytes + a comment of up to 64 KB), and the ZIP64 locator just before it.
        let tailLength = min(size, 22 + 65_535 + 20)
        try handle.seek(toOffset: size - tailLength)
        let tail = try handle.read(upToCount: Int(tailLength)) ?? Data()
        guard let end = Self.lastOffset(of: 0x0605_4B50, in: tail, recordLength: 22) else { throw Failure.notAZip }
        var count = UInt64(tail.littleEndian(UInt16.self, at: end + 10))
        var directorySize = UInt64(tail.littleEndian(UInt32.self, at: end + 12))
        var directoryOffset = UInt64(tail.littleEndian(UInt32.self, at: end + 16))
        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF,
           end >= 20, tail.littleEndian(UInt32.self, at: end - 20) == 0x0706_4B50 {
            let recordOffset = tail.littleEndian(UInt64.self, at: end - 20 + 8)
            guard recordOffset < size else { throw Failure.damaged }
            try handle.seek(toOffset: recordOffset)
            let record = try handle.read(upToCount: 56) ?? Data()
            guard record.count == 56, record.littleEndian(UInt32.self, at: 0) == 0x0606_4B50 else { throw Failure.damaged }
            count = record.littleEndian(UInt64.self, at: 32)
            directorySize = record.littleEndian(UInt64.self, at: 40)
            directoryOffset = record.littleEndian(UInt64.self, at: 48)
        }
        guard directoryOffset <= size, directorySize <= size - directoryOffset, directorySize <= 64 << 20 else {
            throw Failure.damaged
        }
        try handle.seek(toOffset: directoryOffset)
        let directory = try handle.read(upToCount: Int(directorySize)) ?? Data()

        var entries: [Entry] = []
        var position = 0
        while UInt64(entries.count) < count, position + 46 <= directory.count,
              directory.littleEndian(UInt32.self, at: position) == 0x0201_4B50 {
            let flags = directory.littleEndian(UInt16.self, at: position + 8)
            let method = directory.littleEndian(UInt16.self, at: position + 10)
            var compressedSize = UInt64(directory.littleEndian(UInt32.self, at: position + 20))
            var uncompressedSize = UInt64(directory.littleEndian(UInt32.self, at: position + 24))
            let nameLength = Int(directory.littleEndian(UInt16.self, at: position + 28))
            let extraLength = Int(directory.littleEndian(UInt16.self, at: position + 30))
            let commentLength = Int(directory.littleEndian(UInt16.self, at: position + 32))
            var localHeaderOffset = UInt64(directory.littleEndian(UInt32.self, at: position + 42))
            let nameStart = position + 46
            let extraStart = nameStart + nameLength
            let extraEnd = extraStart + extraLength
            let next = extraEnd + commentLength
            guard next <= directory.count else { break }

            var unicodeName: String?
            var field = extraStart
            while field + 4 <= extraEnd {
                let id = directory.littleEndian(UInt16.self, at: field)
                let length = Int(directory.littleEndian(UInt16.self, at: field + 2))
                let body = field + 4
                guard body + length <= extraEnd else { break }
                if id == 0x0001 {
                    // ZIP64 sizes and offset: present only for the fields that are at their 32-bit maximum, in order.
                    var cursor = body
                    if uncompressedSize == 0xFFFF_FFFF, cursor + 8 <= body + length {
                        uncompressedSize = directory.littleEndian(UInt64.self, at: cursor); cursor += 8
                    }
                    if compressedSize == 0xFFFF_FFFF, cursor + 8 <= body + length {
                        compressedSize = directory.littleEndian(UInt64.self, at: cursor); cursor += 8
                    }
                    if localHeaderOffset == 0xFFFF_FFFF, cursor + 8 <= body + length {
                        localHeaderOffset = directory.littleEndian(UInt64.self, at: cursor)
                    }
                } else if id == 0x7075, length > 5 {
                    // Info-ZIP Unicode Path: version (1), CRC of the plain name (4), the name in UTF-8.
                    unicodeName = String(data: directory.subdata(in: (body + 5)..<(body + length)), encoding: .utf8)
                }
                field = body + length
            }
            let rawName = directory.subdata(in: nameStart..<extraStart)
            entries.append(Entry(
                name: unicodeName ?? Self.decodeName(rawName, utf8: flags & 0x0800 != 0),
                uncompressedSize: uncompressedSize,
                compressedSize: compressedSize,
                method: method,
                flags: flags,
                localHeaderOffset: localHeaderOffset
            ))
            position = next
        }
        guard !entries.isEmpty || count == 0 else { throw Failure.damaged }
        self.url = url
        self.entries = entries
    }

    /// One entry's bytes (stored or deflated), refused past `limit`.
    public func data(for entry: Entry, limit: Int) throws -> Data {
        guard entry.flags & 0x0001 == 0 else { throw Failure.encrypted }
        guard entry.uncompressedSize <= UInt64(limit), entry.compressedSize <= UInt64(limit) + 65_536 else {
            throw Failure.tooLarge
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: entry.localHeaderOffset)
        let header = try handle.read(upToCount: 30) ?? Data()
        guard header.count == 30, header.littleEndian(UInt32.self, at: 0) == 0x0403_4B50 else { throw Failure.damaged }
        // The local header's name and extra field can differ in length from the central directory's.
        let skip = UInt64(header.littleEndian(UInt16.self, at: 26)) + UInt64(header.littleEndian(UInt16.self, at: 28))
        try handle.seek(toOffset: entry.localHeaderOffset + 30 + skip)
        let raw = try handle.read(upToCount: Int(entry.compressedSize)) ?? Data()
        guard raw.count == Int(entry.compressedSize) else { throw Failure.damaged }
        switch entry.method {
        case 0:
            return raw
        case 8:
            do {
                return try MihonInflate.inflate(raw, sizeHint: Int(entry.uncompressedSize), limit: limit)
            } catch MihonInflate.Failure.tooLarge {
                throw Failure.tooLarge
            } catch {
                throw Failure.damaged
            }
        default:
            throw Failure.unsupportedMethod(entry.method)
        }
    }

    // MARK: Cache

    private final class Cache: @unchecked Sendable {
        let archives = NSCache<NSString, MihonZipArchive>()
        init() { archives.countLimit = 24 }
    }

    private static let cache = Cache()

    /// The archive at `url`, parsed once while the file stays the same (every page of a chapter reads it).
    public static func cached(at url: URL) throws -> MihonZipArchive {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = "\(url.path)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values.fileSize ?? 0)" as NSString
        if let hit = cache.archives.object(forKey: key) { return hit }
        let archive = try MihonZipArchive(url: url)
        cache.archives.setObject(archive, forKey: key)
        return archive
    }

    // MARK: Helpers

    private static func lastOffset(of signature: UInt32, in data: Data, recordLength: Int) -> Int? {
        var offset = data.count - recordLength
        while offset >= 0 {
            if data.littleEndian(UInt32.self, at: offset) == signature { return offset }
            offset -= 1
        }
        return nil
    }

    /// Without the UTF-8 flag a name is in the creator's code page: still UTF-8 from most tools, GBK from Chinese
    /// Windows, CP437 (read as Latin-1) from old ones.
    static func decodeName(_ raw: Data, utf8: Bool) -> String {
        if utf8 || raw.allSatisfy({ $0 < 0x80 }), let name = String(data: raw, encoding: .utf8) { return name }
        if let name = String(data: raw, encoding: .utf8) { return name }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        if let name = String(data: raw, encoding: gb18030) { return name }
        return String(data: raw, encoding: .isoLatin1) ?? String(decoding: raw, as: UTF8.self)
    }
}

private extension Data {
    /// A little-endian integer at `offset` (0 when out of range).
    func littleEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        guard offset >= 0, offset + MemoryLayout<T>.size <= count else { return 0 }
        return withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
}
