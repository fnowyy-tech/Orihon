import MihonDomain

// MARK: - Running on from one chapter into the next (upstream's viewers: the neighbouring chapters' pages past a card)

/// The slide reader's spreads: `[[0], [1, 2], [3, 4] …]` with the cover alone, `[[0, 1], [2, 3] …]` otherwise.
enum ReaderSpreads {
    static func pairs(pageCount: Int, shiftCover: Bool) -> [[Int]] {
        var result: [[Int]] = []
        var index = 0
        if shiftCover && pageCount > 0 {
            result.append([0])
            index = 1
        }
        while index < pageCount {
            if index + 1 < pageCount {
                result.append([index, index + 1])
                index += 2
            } else {
                result.append([index])
                index += 1
            }
        }
        return result
    }

    /// What a chapter opens on when moved into from a neighbour: its first spread from the start, its last from the
    /// end — what the pager shows past the card before that chapter opens.
    static func opening(pageCount: Int, shiftCover: Bool, fromStart: Bool) -> [Int] {
        let all = pairs(pageCount: pageCount, shiftCover: shiftCover)
        return (fromStart ? all.first : all.last) ?? []
    }
}

/// A chapter of the webtoon strip; `order` is its place in the reader's chapter list.
struct ReaderStripChapter: Hashable {
    let order: Int
    let chapter: Chapter
    let pages: [Page]
}

/// Ids of the strip's items, unique across its chapters and the same whether or not the chapter below a card is in
/// the strip yet: page `index` of chapter `order` is `order * stride + 1 + index`, the card above chapter `order`
/// (below the one before it) `order * stride`.
enum ReaderStripID {
    static let stride = 1_000_000

    static func page(_ index: Int, order: Int) -> Int { order * stride + 1 + index }

    static func card(before order: Int) -> Int { order * stride }

    /// The chapter an item belongs to and, for a page, its index (a card: the chapter below it, no index).
    static func decode(_ id: Int) -> (order: Int, page: Int?) {
        let remainder = id % stride
        return (id / stride, remainder == 0 ? nil : remainder - 1)
    }
}

/// The webtoon strip top to bottom: the card above its first chapter, then each chapter's pages and the card below
/// it — between it and the next, as upstream's `viewerItems` puts the next chapter's pages after its transition.
enum ReaderStripItem: Identifiable {
    case cardAbove(ReaderStripChapter)
    case page(ReaderStripChapter, index: Int)
    case cardBelow(ReaderStripChapter)

    var id: Int {
        switch self {
        case .cardAbove(let entry): return ReaderStripID.card(before: entry.order)
        case .page(let entry, let index): return ReaderStripID.page(index, order: entry.order)
        case .cardBelow(let entry): return ReaderStripID.card(before: entry.order + 1)
        }
    }

    static func items(of strip: [ReaderStripChapter]) -> [ReaderStripItem] {
        guard let first = strip.first else { return [] }
        return [.cardAbove(first)] + strip.flatMap { entry in
            entry.pages.indices.map { ReaderStripItem.page(entry, index: $0) } + [.cardBelow(entry)]
        }
    }
}
