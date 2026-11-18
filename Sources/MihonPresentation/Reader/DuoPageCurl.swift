import SwiftUI
import MihonDomain
#if canImport(UIKit)
import UIKit
#endif

// MARK: - iPhone Duo page curl (a chapter turned like a printed book)

/// A chapter laid out as a book for the iPhone Duo spread: page slots in a book's left-to-right order, two per
/// spread. Slot `2k + 1` (a right page) and slot `2k + 2` (the next left page) are the two faces of one sheet, so a
/// sheet turned forward shows on its back the page that lands on the other side — what a middle-spine,
/// double-sided `UIPageViewController` animates. A right-to-left book is the same book read from the other end.
struct DuoBookLayout: Equatable {
    enum Slot: Hashable {
        case page(Int)
        case blank
        case previousChapter
        case nextChapter
        /// Paper beyond a chapter card: turning onto it moves into that chapter, whose spread there it shows once
        /// fetched ahead (`openingSpread`).
        case chapterEdge(next: Bool)
    }

    /// Left to right, two per spread.
    let slots: [Slot]
    let rightToLeft: Bool

    /// In reading order: a sheet to turn into the previous chapter, the previous chapter's card where turning back
    /// lands it, the cover alone where a closed book's front cover is (`shiftCover`), the pages, a blank finishing
    /// the last sheet, the next chapter's card where turning on lands it, and a sheet to turn into the next chapter.
    /// The page pairs match the slide reader's spreads.
    init(pageCount: Int, shiftCover: Bool, rightToLeft: Bool) {
        var reading: [Slot] = [.chapterEdge(next: false), .chapterEdge(next: false), .blank, .previousChapter]
        if shiftCover && pageCount > 0 { reading.append(.blank) }
        reading += (0..<max(0, pageCount)).map(Slot.page)
        if reading.count % 2 == 1 { reading.append(.blank) }
        reading += [.nextChapter, .blank, .chapterEdge(next: true), .chapterEdge(next: true)]
        slots = rightToLeft ? reading.reversed() : reading
        self.rightToLeft = rightToLeft
    }

    var spreadCount: Int { slots.count / 2 }

    /// The two slots of a spread, as they sit on the screens.
    func spread(_ index: Int) -> (left: Slot, right: Slot) {
        (slots[2 * index], slots[2 * index + 1])
    }

    /// Spreads in reading order: 0 is the previous chapter's card, then the chapter, then the next chapter's card
    /// (`nextCardReading`); -1 and `nextCardReading + 1` are the sheets that turn into the neighbouring chapters.
    func layoutSpread(forReading reading: Int) -> Int {
        rightToLeft ? spreadCount - 2 - reading : reading + 1
    }

    func readingSpread(forLayout layout: Int) -> Int {
        rightToLeft ? spreadCount - 2 - layout : layout - 1
    }

    var nextCardReading: Int { spreadCount - 3 }

    /// The spread this chapter opens on when moved into from a neighbour: its first, entered from the start (the
    /// next chapter), or its last, entered from the end (paging back). The sheet past a card shows it, so the turn
    /// and the chapter opening after it show the same pages.
    func openingSpread(fromStart: Bool) -> (left: Slot, right: Slot) {
        spread(layoutSpread(forReading: fromStart ? 1 : nextCardReading - 1))
    }

    /// The pages of a spread in reading order.
    func pages(inLayoutSpread index: Int) -> [Int] {
        let (left, right) = spread(index)
        let pages = [left, right].compactMap { slot -> Int? in
            if case .page(let page) = slot { return page }
            return nil
        }
        return pages.sorted()
    }
}

#if canImport(UIKit)

/// The middle-spine page curl of iOS (Apple Books' two-page view) over a `DuoBookLayout`: drag a page's corner,
/// or tap a side (the reader's own tap zones), and the sheet curls over the spine. The reader's spread position
/// stays the single source of truth: a turn by hand reports the new spread, a new position animates there.
struct DuoPageCurlView: UIViewControllerRepresentable {
    let layout: DuoBookLayout
    /// Bumped when the chapter or its pages change: the pages are laid out afresh.
    let layoutToken: Int
    /// The reading spread on screen (`DuoBookLayout.layoutSpread(forReading:)`).
    let readingSpread: Int
    /// Off while zoomed: dragging pans the page instead of turning it.
    let allowsTurning: Bool
    /// A single tap then waits to tell itself from a double tap (as the slide reader's taps do).
    let doubleTapZooms: Bool
    /// Everything the pages show: they are rebuilt when it changes, not on every render of the reader.
    let contentKey: String
    let page: (DuoBookLayout.Slot, _ isLeft: Bool) -> AnyView
    let onTurn: (_ readingSpread: Int) -> Void
    /// Turned past a chapter card (`forward`: past the next chapter's): true when another chapter opens; otherwise
    /// the card turns back into view.
    let onTurnPastCard: (_ forward: Bool) -> Bool
    let onTap: (CGPoint, CGSize) -> Void
    let onDoubleTap: (CGPoint, CGSize) -> Void
    /// The slide reader's swipe down to close.
    let onSwipeDown: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: [.spineLocation: NSNumber(value: UIPageViewController.SpineLocation.mid.rawValue)]
        )
        // A middle spine shows both faces of every sheet.
        controller.isDoubleSided = true
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.view.backgroundColor = .clear
        // The reader's tap zones (menu in the middle, turns at the sides) replace the curl's own edge taps.
        for recognizer in controller.gestureRecognizers where recognizer is UITapGestureRecognizer {
            recognizer.isEnabled = false
        }
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        controller.view.addGestureRecognizer(tap)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.isEnabled = doubleTapZooms
        controller.view.addGestureRecognizer(doubleTap)
        tap.require(toFail: doubleTap)
        context.coordinator.doubleTap = doubleTap
        // A drag that starts clearly downward closes the reader; any other fails at once, so the curl's own drag
        // follows the finger from its first movement.
        let pullDown = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pulledDown(_:)))
        pullDown.delegate = context.coordinator
        controller.view.addGestureRecognizer(pullDown)
        for recognizer in controller.gestureRecognizers where recognizer is UIPanGestureRecognizer {
            recognizer.require(toFail: pullDown)
        }
        context.coordinator.pullDown = pullDown
        context.coordinator.token = layoutToken
        context.coordinator.contentKey = contentKey
        context.coordinator.show(layoutSpread: layout.layoutSpread(forReading: readingSpread), in: controller, animated: false)
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        for recognizer in controller.gestureRecognizers where !(recognizer is UITapGestureRecognizer) {
            recognizer.isEnabled = allowsTurning
        }
        // Disabled, it fails at once, so single taps stop waiting for it.
        coordinator.doubleTap?.isEnabled = doubleTapZooms
        coordinator.apply(in: controller)
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
        var parent: DuoPageCurlView
        var layout: DuoBookLayout
        var token = 0
        var currentLayoutSpread = -1
        var contentKey = ""
        /// A turn by hand is under way: the reader's position follows it, not the other way round, and a new layout
        /// or position waits for it to end (`apply`).
        var isTurning = false
        /// When a turn to a new position began animating: the next waits for it (one begun meanwhile left the pages
        /// on the sheet before while the position moved on), for two seconds at most should UIKit never report the end.
        var animatingSince: Date?
        /// Hosting controllers by slot, so a page decoded once is not rebuilt while a sheet is being turned.
        var controllers: [Int: SlotController] = [:]
        weak var doubleTap: UITapGestureRecognizer?
        weak var pullDown: UIPanGestureRecognizer?

        init(_ parent: DuoPageCurlView) {
            self.parent = parent
            self.layout = parent.layout
        }

        /// A page of the book: a plain controller holding the SwiftUI page as a child. The curl adds its own effect
        /// views to the pages it turns, and SwiftUI does not allow views added to a hosting controller's view.
        final class SlotController: UIViewController {
            var slot = 0
            /// The layout the page belongs to: a turn ending on a page from before a new layout is not reported.
            var token = 0
            private let host: UIHostingController<AnyView>

            var rootView: AnyView {
                get { host.rootView }
                set { host.rootView = newValue }
            }

            init(rootView: AnyView) {
                host = UIHostingController(rootView: rootView)
                super.init(nibName: nil, bundle: nil)
            }

            required init?(coder: NSCoder) { nil }

            override func viewDidLoad() {
                super.viewDidLoad()
                view.backgroundColor = .clear
                addChild(host)
                host.view.backgroundColor = .clear
                host.view.frame = view.bounds
                host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                view.addSubview(host.view)
                host.didMove(toParent: self)
            }
        }

        /// Brings the pages in line with the reader: a new layout (chapter, pages, settings) laid out afresh, a new
        /// position turned to, new content redrawn. Not while a sheet is being turned by hand.
        func apply(in pageController: UIPageViewController) {
            guard !isTurning else { return }
            if let since = animatingSince, Date().timeIntervalSince(since) < 2 { return }
            animatingSince = nil
            let target = parent.layout.layoutSpread(forReading: parent.readingSpread)
            if token != parent.layoutToken || layout != parent.layout {
                token = parent.layoutToken
                layout = parent.layout
                contentKey = parent.contentKey
                controllers.removeAll()
                currentLayoutSpread = -1
                show(layoutSpread: target, in: pageController, animated: false)
                return
            }
            if contentKey != parent.contentKey {
                contentKey = parent.contentKey
                for (slot, controller) in controllers {
                    controller.rootView = parent.page(layout.slots[slot], slot % 2 == 0)
                }
            }
            if currentLayoutSpread != target {
                show(layoutSpread: target, in: pageController, animated: true)
            }
        }

        func controller(at slot: Int) -> SlotController? {
            guard layout.slots.indices.contains(slot) else { return nil }
            if let existing = controllers[slot] { return existing }
            let controller = SlotController(rootView: parent.page(layout.slots[slot], slot % 2 == 0))
            controller.slot = slot
            controller.token = token
            controllers[slot] = controller
            // Only the sheets around the open spread stay alive.
            let keep = (slot - 4)...(slot + 4)
            for stale in controllers.keys where !keep.contains(stale) && !visibleSlots.contains(stale) {
                controllers[stale] = nil
            }
            return controller
        }

        private var visibleSlots: Set<Int> {
            currentLayoutSpread < 0 ? [] : [2 * currentLayoutSpread, 2 * currentLayoutSpread + 1]
        }

        func show(layoutSpread: Int, in pageController: UIPageViewController, animated: Bool) {
            let spread = min(max(0, layoutSpread), max(0, layout.spreadCount - 1))
            guard let left = controller(at: 2 * spread), let right = controller(at: 2 * spread + 1) else { return }
            let direction: UIPageViewController.NavigationDirection = spread >= currentLayoutSpread ? .forward : .reverse
            let animate = animated && currentLayoutSpread >= 0 && abs(spread - currentLayoutSpread) == 1
            currentLayoutSpread = spread
            guard animate else {
                pageController.setViewControllers([left, right], direction: direction, animated: false)
                return
            }
            animatingSince = Date()
            pageController.setViewControllers([left, right], direction: direction, animated: true) { [weak self, weak pageController] _ in
                guard let self, let pageController else { return }
                self.animatingSince = nil
                // Where the turn really ended (an interrupted one stays put), then a position that arrived meanwhile.
                if let first = pageController.viewControllers?.first as? SlotController, first.token == self.token {
                    self.currentLayoutSpread = first.slot / 2
                }
                self.apply(in: pageController)
            }
        }

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let slot = (viewController as? SlotController)?.slot else { return nil }
            return controller(at: slot - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let slot = (viewController as? SlotController)?.slot else { return nil }
            return controller(at: slot + 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
            isTurning = true
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            isTurning = false
            // A chapter opened during the turn (a key on the card): the turn was through the old one's pages.
            if completed, token == parent.layoutToken,
               let first = pageViewController.viewControllers?.first as? SlotController, first.token == token {
                currentLayoutSpread = first.slot / 2
                let reading = layout.readingSpread(forLayout: currentLayoutSpread)
                if reading < 0 || reading > layout.nextCardReading {
                    // The sheet past a chapter card: into that chapter, or (no chapter there) back to the card.
                    if parent.onTurnPastCard(reading > 0) { return }
                } else if reading != parent.readingSpread {
                    parent.onTurn(reading)
                    // The reader's update brings the new position (and whatever arrived during the turn) to `apply`.
                    // Applied now, `parent` still holds the position from before the turn and the sheet turned back.
                    return
                }
            }
            // What arrived during the turn (a chapter's pages, a tap's position), or the place a cancelled turn left.
            apply(in: pageViewController)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                spineLocationFor orientation: UIInterfaceOrientation) -> UIPageViewController.SpineLocation {
            .mid
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            parent.onTap(recognizer.location(in: view), view.bounds.size)
        }

        @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            parent.onDoubleTap(recognizer.location(in: view), view.bounds.size)
        }

        @objc func pulledDown(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            if translation.y > 120, abs(translation.x) < translation.y / 2 { parent.onSwipeDown() }
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard recognizer === pullDown, let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return true }
            let velocity = pan.velocity(in: view)
            return velocity.y > 0 && velocity.y > abs(velocity.x) * 2
        }
    }
}

#endif
