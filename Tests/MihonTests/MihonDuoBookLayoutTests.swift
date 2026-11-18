import XCTest
import MihonDomain
@testable import MihonData
@testable import MihonPresentation

/// The iPhone Duo page curl turns a chapter like a printed book: every sheet has a page on each face, and what a
/// turn shows on the back of a sheet is the page that lands on the other side.
final class MihonDuoBookLayoutTests: XCTestCase {
    private typealias Slot = DuoBookLayout.Slot

    /// The slide reader's spreads (`MangaReaderScreen.spreads`), which the curl must pair the same way.
    private func readerSpreads(pageCount: Int, shiftCover: Bool) -> [[Int]] {
        var result: [[Int]] = []
        var index = 0
        if shiftCover && pageCount > 0 {
            result.append([0])
            index = 1
        }
        while index < pageCount {
            result.append(index + 1 < pageCount ? [index, index + 1] : [index])
            index += index + 1 < pageCount ? 2 : 1
        }
        return result
    }

    private func describe(_ slot: Slot) -> String {
        switch slot {
        case .page(let page): return "\(page + 1)"
        case .blank: return "_"
        case .previousChapter: return "上一章"
        case .nextChapter: return "下一章"
        case .chapterEdge: return "·"
        }
    }

    private func spreads(_ layout: DuoBookLayout) -> [String] {
        (0..<layout.spreadCount).map { index in
            let (left, right) = layout.spread(index)
            return "\(describe(left))|\(describe(right))"
        }
    }

    func testLeftToRightBookWithCoverAlone() {
        let layout = DuoBookLayout(pageCount: 6, shiftCover: true, rightToLeft: false)
        // The cover on the right like a book's first page, the last page alone on the left (the back of the last sheet).
        XCTAssertEqual(spreads(layout), ["·|·", "_|上一章", "_|1", "2|3", "4|5", "6|_", "下一章|_", "·|·"])
    }

    func testLeftToRightBookWithoutCover() {
        let layout = DuoBookLayout(pageCount: 5, shiftCover: false, rightToLeft: false)
        XCTAssertEqual(spreads(layout), ["·|·", "_|上一章", "1|2", "3|4", "5|_", "下一章|_", "·|·"])
    }

    func testRightToLeftBookIsTheSameBookFromTheOtherEnd() {
        // Manga: the earlier page on the right, the cover alone on the left, turned from the left page.
        let withCover = DuoBookLayout(pageCount: 6, shiftCover: true, rightToLeft: true)
        XCTAssertEqual(spreads(withCover), ["·|·", "_|下一章", "_|6", "5|4", "3|2", "1|_", "上一章|_", "·|·"])
        let withoutCover = DuoBookLayout(pageCount: 5, shiftCover: false, rightToLeft: true)
        XCTAssertEqual(spreads(withoutCover), ["·|·", "_|下一章", "_|5", "4|3", "2|1", "上一章|_", "·|·"])
    }

    /// Every sheet's two faces are neighbours in reading order: turning never skips or repeats a page.
    func testEverySheetCarriesConsecutivePages() {
        for pageCount in 0...13 {
            for shiftCover in [false, true] {
                for rightToLeft in [false, true] {
                    let layout = DuoBookLayout(pageCount: pageCount, shiftCover: shiftCover, rightToLeft: rightToLeft)
                    XCTAssertEqual(layout.slots.count % 2, 0)
                    let pages = layout.slots.compactMap { slot -> Int? in
                        if case .page(let page) = slot { return page }
                        return nil
                    }
                    // Each page exactly once, in order along the book.
                    XCTAssertEqual(pages, rightToLeft ? Array((0..<pageCount).reversed()) : Array(0..<pageCount))
                    // A sheet: the right page of one spread and the left page of the next.
                    for sheet in stride(from: 1, to: layout.slots.count - 1, by: 2) {
                        if case .page(let front) = layout.slots[sheet], case .page(let back) = layout.slots[sheet + 1] {
                            XCTAssertEqual(abs(front - back), 1, "sheet \(sheet) of \(pageCount) pages: \(front + 1) / \(back + 1)")
                        }
                    }
                }
            }
        }
    }

    /// The curl pairs pages exactly as the slide reader does, so switching styles keeps the place.
    func testSpreadsMatchTheSlideReader() {
        for pageCount in 1...13 {
            for shiftCover in [false, true] {
                for rightToLeft in [false, true] {
                    let layout = DuoBookLayout(pageCount: pageCount, shiftCover: shiftCover, rightToLeft: rightToLeft)
                    let expected = readerSpreads(pageCount: pageCount, shiftCover: shiftCover)
                    XCTAssertEqual(layout.spreadCount, expected.count + 4, "plus the chapter cards and the sheets past them")
                    XCTAssertEqual(layout.nextCardReading, expected.count + 1)
                    XCTAssertEqual(layout.spread(layout.layoutSpread(forReading: -1)).left, .chapterEdge(next: false))
                    XCTAssertEqual(layout.spread(layout.layoutSpread(forReading: -1)).right, .chapterEdge(next: false))
                    XCTAssertEqual(layout.spread(layout.layoutSpread(forReading: expected.count + 2)).left, .chapterEdge(next: true))
                    XCTAssertEqual(layout.spread(layout.layoutSpread(forReading: expected.count + 2)).right, .chapterEdge(next: true))
                    for (index, pair) in expected.enumerated() {
                        let spread = layout.layoutSpread(forReading: index + 1)
                        XCTAssertEqual(layout.pages(inLayoutSpread: spread), pair, "\(pageCount) pages, cover \(shiftCover), rtl \(rightToLeft)")
                        XCTAssertEqual(layout.readingSpread(forLayout: spread), index + 1)
                    }
                    XCTAssertEqual(layout.spread(layout.layoutSpread(forReading: 0)).left == .previousChapter
                                   || layout.spread(layout.layoutSpread(forReading: 0)).right == .previousChapter, true)
                    let last = layout.spread(layout.layoutSpread(forReading: expected.count + 1))
                    XCTAssertTrue(last.left == .nextChapter || last.right == .nextChapter)
                }
            }
        }
    }

    /// The sheet past a card shows the neighbouring chapter's opening spread, and turning onto it opens that chapter
    /// on the same spread: the next one's first, the previous one's last — the slide reader's pairs either way.
    func testTheSheetPastACardShowsWhereTheNeighbourOpens() {
        for pageCount in 1...9 {
            for shiftCover in [false, true] {
                for rightToLeft in [false, true] {
                    let neighbor = DuoBookLayout(pageCount: pageCount, shiftCover: shiftCover, rightToLeft: rightToLeft)
                    let pairs = readerSpreads(pageCount: pageCount, shiftCover: shiftCover)
                    for fromStart in [true, false] {
                        let shown = neighbor.openingSpread(fromStart: fromStart)
                        // Where the reader opens it: the first spread (page one) or the last (paged back).
                        let opened = neighbor.spread(neighbor.layoutSpread(forReading: fromStart ? 1 : pairs.count))
                        XCTAssertEqual(shown.left, opened.left)
                        XCTAssertEqual(shown.right, opened.right)
                        let pages = [shown.left, shown.right].compactMap { slot -> Int? in
                            if case .page(let page) = slot { return page }
                            return nil
                        }.sorted()
                        XCTAssertEqual(pages, fromStart ? pairs.first : pairs.last, "\(pageCount) pages, cover \(shiftCover), rtl \(rightToLeft)")
                        XCTAssertEqual(pages, ReaderSpreads.opening(pageCount: pageCount, shiftCover: shiftCover, fromStart: fromStart))
                    }
                }
            }
        }
        XCTAssertEqual(ReaderSpreads.pairs(pageCount: 5, shiftCover: true), readerSpreads(pageCount: 5, shiftCover: true))
        XCTAssertEqual(ReaderSpreads.pairs(pageCount: 0, shiftCover: true), [])
    }

    /// The webtoon strip runs on from one chapter into the next: every item's id is unique, a card keeps its id
    /// whether or not the chapter below it has joined, and ids decode back to their chapter and page.
    func testWebtoonStripIdsStayPutAsTheNextChapterJoins() {
        func chapter(_ id: Int64) -> Chapter { Chapter(id: id, mangaId: 1, url: "/c/\(id)", name: "第\(id)话") }
        func pages(_ count: Int) -> [Page] { (0..<count).map { Page(index: $0, imageUrl: "https://example.com/\($0).jpg") } }
        let first = ReaderStripChapter(order: 4, chapter: chapter(10), pages: pages(3))
        let alone = ReaderStripItem.items(of: [first]).map(\.id)
        XCTAssertEqual(alone, [4_000_000, 4_000_001, 4_000_002, 4_000_003, 5_000_000])

        let second = ReaderStripChapter(order: 5, chapter: chapter(11), pages: pages(2))
        let joined = ReaderStripItem.items(of: [first, second]).map(\.id)
        XCTAssertEqual(Set(joined).count, joined.count, "no id twice in the strip")
        XCTAssertEqual(Array(joined.prefix(alone.count)), alone, "what was on screen keeps its ids")
        XCTAssertEqual(Array(joined.suffix(3)), [5_000_001, 5_000_002, 6_000_000])

        XCTAssertEqual(ReaderStripID.decode(ReaderStripID.page(2, order: 4)).order, 4)
        XCTAssertEqual(ReaderStripID.decode(ReaderStripID.page(2, order: 4)).page, 2)
        XCTAssertEqual(ReaderStripID.decode(ReaderStripID.card(before: 5)).order, 5)
        XCTAssertNil(ReaderStripID.decode(ReaderStripID.card(before: 5)).page)
        XCTAssertEqual(ReaderStripID.decode(ReaderStripID.page(0, order: 0)).page, 0)
        XCTAssertNil(ReaderStripID.decode(ReaderStripID.card(before: 0)).page)
    }

    /// The chapter cards sit where a turn lands them: forward, on the side the turned sheet's back comes to rest.
    func testChapterCardsLandWhereTheTurnBringsThem() {
        let ltr = DuoBookLayout(pageCount: 4, shiftCover: false, rightToLeft: false)
        XCTAssertEqual(ltr.spread(ltr.layoutSpread(forReading: ltr.nextCardReading)).left, .nextChapter)
        XCTAssertEqual(ltr.spread(ltr.layoutSpread(forReading: 0)).right, .previousChapter)
        let rtl = DuoBookLayout(pageCount: 4, shiftCover: false, rightToLeft: true)
        XCTAssertEqual(rtl.spread(rtl.layoutSpread(forReading: rtl.nextCardReading)).right, .nextChapter)
        XCTAssertEqual(rtl.spread(rtl.layoutSpread(forReading: 0)).left, .previousChapter)
    }

    /// The spread slides by default; a saved curl counts only when picked by hand (build 29 saved curl as its default).
    @MainActor
    func testTurnStyleDefaultsToSlideAndKeepsAPickedCurl() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        XCTAssertEqual(store.duoPageTurnStyle, .slide)
        store.apply(try JSONDecoder().decode(MihonSettingsSnapshot.self, from: Data(#"{"duoPageTurnStyle":"仿真卷页"}"#.utf8)))
        XCTAssertEqual(store.duoPageTurnStyle, .slide, "build 29's default, not a choice")

        store.duoPageTurnStyle = .curl
        store.duoPageTurnStylePicked = true
        let restored = MihonRepositoryStore(bootstrapNetwork: false)
        restored.apply(try JSONDecoder().decode(MihonSettingsSnapshot.self, from: JSONEncoder().encode(store.settingsSnapshot)))
        XCTAssertEqual(restored.duoPageTurnStyle, .curl)
        XCTAssertEqual(DuoPageTurnStyle.curl.label, "仿真卷页（测试中）")
    }
}
