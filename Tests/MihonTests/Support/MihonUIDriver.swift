import AppKit
import SwiftUI
import XCTest
@testable import MihonPresentation

/// In-process UI driver for macOS: hosts a SwiftUI hierarchy in an offscreen window, finds elements through
/// test anchors (see `mihonTestAnchor`) and injects real `NSEvent`s (like Lyft's Hammer does with touches on iOS),
/// so gestures, hit-testing, scroll views and presentations run through the same code paths as user input.
@MainActor
final class MihonUIDriver {
    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    let window: NSWindow
    private var eventNumber = 0

    init<V: View>(_ view: V, size: CGSize, dark: Bool = true) {
        // Anchors must be enabled before the hierarchy is built.
        MihonTestAnchorRegistry.isEnabled = true
        MihonTestAnchorRegistry.shared.reset()
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = KeyableWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        window.makeKey()
        self.window = window
    }

    func close() {
        for sheet in window.sheets { window.endSheet(sheet) }
        // Tear the hierarchy down now so its `onDisappear` cannot unregister anchors of the next driver.
        window.contentView = nil
        window.orderOut(nil)
        MihonTestAnchorRegistry.shared.reset()
    }

    /// The front-most window of the hierarchy (a presented `.sheet` lives in its own window on macOS,
    /// and a sheet presented from a sheet is attached to that sheet window).
    var activeWindow: NSWindow {
        var current = window
        while let sheet = current.attachedSheet { current = sheet }
        return current
    }

    /// Polls until `condition` holds (UI updates are asynchronous), pumping display meanwhile.
    func waitFor(timeout: TimeInterval = 2.0, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            await idle(0.05)
        } while Date() < end
        return condition()
    }

    func hasAnchor(_ id: String) -> Bool { anchor(id) != nil }

    func hasAnchor(prefix: String, containing fragment: String = "") -> Bool {
        anchors(withPrefix: prefix).contains { fragment.isEmpty || $0.contains(fragment) }
    }

    /// Identifiers of anchors that are visible in the front-most window.
    func anchors(withPrefix prefix: String) -> [String] {
        pump()
        return MihonTestAnchorRegistry.shared.identifiers(withPrefix: prefix, windowNumber: activeWindow.windowNumber)
    }

    /// Resizes the window like a user dragging its edge (or a device unfolding its second screen).
    func resize(to size: CGSize, settle: TimeInterval = 0.5) async {
        window.setContentSize(size)
        await idle(settle)
    }

    // MARK: Waiting

    /// Offscreen windows are "occluded", and AppKit/SwiftUI skip their display cycles (no body updates, no
    /// accessibility tree). Pump layout + display explicitly so the hierarchy behaves like a visible window.
    func idle(_ seconds: TimeInterval) async {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            dispatchPendingEvents()
            pump()
            try? await Task.sleep(nanoseconds: 16_000_000)
        } while Date() < end
    }

    /// The test runner never calls `NSApp.run()`, so nothing drains the event queue: AppKit-defined events
    /// (window moved/exposed, …) pile up and gesture recognizers stop resetting after a main-thread stall.
    /// Dispatch the queue the way the app's own event loop would.
    func dispatchPendingEvents() {
        while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }

    func pump() {
        for win in [window] + window.sheets + (window.childWindows ?? []) {
            win.contentView?.layoutSubtreeIfNeeded()
            win.contentView?.needsDisplay = true
            win.displayIfNeeded()
        }
    }

    // MARK: Anchor lookup (primary)

    /// Window-coordinate center of the visible part of a registered test anchor (see `mihonTestAnchor`)
    /// in the front-most window.
    func anchor(_ id: String) -> CGPoint? {
        pump()
        let win = activeWindow
        guard let frame = MihonTestAnchorRegistry.shared.frame(id, windowNumber: win.windowNumber),
              let view = win.contentView,
              frame.width > 1, frame.height > 1 else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let local = view.isFlipped ? center : CGPoint(x: center.x, y: view.bounds.height - center.y)
        let point = view.convert(local, to: nil)
        guard view.bounds.insetBy(dx: -1, dy: -1).contains(view.convert(point, from: nil)) else { return nil }
        return point
    }

    @discardableResult
    func tap(_ id: String, settle: TimeInterval = 0.5) async -> Bool {
        guard let point = anchor(id) else { return false }
        await click(at: point, settle: settle)
        return true
    }

    @discardableResult
    func longPress(anchor id: String, settle: TimeInterval = 0.5) async -> Bool {
        guard let point = anchor(id) else { return false }
        await press(at: point, hold: 0.8, settle: settle)
        return true
    }

    // MARK: Event injection

    private static var firstMouseClasses: Set<ObjectIdentifier> = []

    /// The test runner can never be the active app (it must not steal the user's focus), so its window is never
    /// key and AppKit treats every click as a window-activation click: unless the hit view accepts first mouse the
    /// click is swallowed. SwiftUI's root hosting view and buttons accept it, but the views that host `ScrollView`
    /// content (`PlatformGroupContainer`, …) do not, so taps, long presses and drags there would never arrive.
    /// Letting every view on the hit path accept first mouse reproduces a click in the active app's key window.
    private func acceptFirstMouse(at point: CGPoint, in win: NSWindow) {
        let selector = #selector(NSView.acceptsFirstMouse(for:))
        // The frame view spans the window, so it hit-tests in window coordinates.
        var current = win.contentView?.superview?.hitTest(point) ?? win.contentView
        while let view = current {
            let cls: AnyClass = type(of: view)
            if !Self.firstMouseClasses.contains(ObjectIdentifier(cls)), let method = class_getInstanceMethod(cls, selector) {
                let accept: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
                let imp = imp_implementationWithBlock(accept)
                // Add the override on this class (or replace its own), leaving superclasses untouched.
                if !class_addMethod(cls, selector, imp, method_getTypeEncoding(method)) {
                    method_setImplementation(method, imp)
                }
                Self.firstMouseClasses.insert(ObjectIdentifier(cls))
            }
            current = view.superview
        }
    }

    private func makeMouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in win: NSWindow, clickCount: Int = 1) -> NSEvent? {
        eventNumber += 1
        return NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: win.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: clickCount,
            pressure: type == .leftMouseUp ? 0 : 1
        )
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in win: NSWindow, clickCount: Int = 1) {
        pump()
        guard let event = makeMouseEvent(type, at: point, in: win, clickCount: clickCount) else { return }
        NSApp.sendEvent(event)
    }

    /// Press-and-release that also works inside AppKit tracking loops: `NSScrollView` (SwiftUI `ScrollView`)
    /// handles mouse-down by pulling the matching mouse-up from the *event queue*, so the release is queued by a
    /// common-mode timer; if no tracking loop consumed it, `idle` dispatches it like the app's event loop would.
    func press(at point: CGPoint, hold: TimeInterval, settle: TimeInterval) async {
        pump()
        let win = activeWindow
        acceptFirstMouse(at: point, in: win)
        guard let down = makeMouseEvent(.leftMouseDown, at: point, in: win),
              let up = makeMouseEvent(.leftMouseUp, at: point, in: win) else { return }
        let release = Timer(timeInterval: hold, repeats: false) { _ in NSApp.postEvent(up, atStart: false) }
        RunLoop.main.add(release, forMode: .common)
        NSApp.sendEvent(down)
        await idle(hold + 0.05)
        release.invalidate()
        dispatchPendingEvents()
        await idle(settle)
    }

    func click(at point: CGPoint, settle: TimeInterval = 0.5) async {
        await press(at: point, hold: 0.08, settle: settle)
    }

    /// Drags (e.g. a swipe on a chapter row or a pager) from `point` by `delta`.
    func drag(from point: CGPoint, by delta: CGSize, steps: Int = 12, settle: TimeInterval = 0.5) async {
        let win = activeWindow
        acceptFirstMouse(at: point, in: win)
        mouse(.leftMouseDown, at: point, in: win)
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            mouse(.leftMouseDragged, at: CGPoint(x: point.x + delta.width * progress, y: point.y + delta.height * progress), in: win)
            await idle(0.016)
        }
        mouse(.leftMouseUp, at: CGPoint(x: point.x + delta.width, y: point.y + delta.height), in: win)
        await idle(settle)
    }

    /// Scrolls the `ScrollView` under `point` by moving its backing `NSScrollView` (SwiftUI's HostingScrollView),
    /// in small steps so lazy containers, scroll transitions and geometry preferences update as with a real fling.
    @discardableResult
    func scrollContent(at point: CGPoint, by dy: CGFloat, steps: Int = 20, settle: TimeInterval = 0.5) async -> Bool {
        pump()
        func deepestScrollView(in view: NSView) -> NSScrollView? {
            for sub in view.subviews.reversed() {
                if let hit = deepestScrollView(in: sub) { return hit }
            }
            if let scrollView = view as? NSScrollView, !scrollView.isHidden,
               scrollView.convert(scrollView.bounds, to: nil).contains(point) {
                return scrollView
            }
            return nil
        }
        guard let root = activeWindow.contentView, let scrollView = deepestScrollView(in: root) else { return false }
        let clip = scrollView.contentView
        let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
        for _ in 0..<steps {
            var origin = clip.bounds.origin
            origin.y = min(maxY, max(0, origin.y + dy / CGFloat(steps)))
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
            await idle(0.016)
        }
        await idle(settle)
        return true
    }

    /// Scroll-wheel events routed to the window under `point` (positive `dy` scrolls content up).
    func scroll(at point: CGPoint, dy: Int32, dx: Int32 = 0, ticks: Int = 8, settle: TimeInterval = 0.5) async {
        let win = activeWindow
        let screenPoint = win.convertPoint(toScreen: point)
        let screenHeight = NSScreen.screens.first?.frame.height ?? 1080
        for _ in 0..<ticks {
            guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -dy, wheel2: -dx, wheel3: 0) else { continue }
            cgEvent.location = CGPoint(x: screenPoint.x, y: screenHeight - screenPoint.y)
            cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(win.windowNumber))
            cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(win.windowNumber))
            if let event = NSEvent(cgEvent: cgEvent) {
                NSApp.sendEvent(event)
            }
            await idle(0.016)
        }
        await idle(settle)
    }

    func key(_ keyCode: UInt16, characters: String, settle: TimeInterval = 0.4) async {
        let win = activeWindow
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            eventNumber += 1
            if let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: win.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ) {
                NSApp.sendEvent(event)
            }
        }
        await idle(settle)
    }

    // MARK: Reporting

    func snapshot(to path: String) {
        guard let view = activeWindow.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// Runs named steps and attributes every SwiftUI runtime issue to the step during which it was logged.
@MainActor
final class MihonRuntimeIssueRecorder {
    private(set) var findings: [(step: String, issue: MihonRuntimeIssue)] = []
    private(set) var missingElements: [String] = []
    private(set) var executedSteps = 0
    private var checkpoint = MihonRuntimeGuard.checkpoint()
    var driver: MihonUIDriver?
    var artifactsDirectory: String?

    func step(_ name: String, _ action: () async -> Bool) async {
        let ok = await action()
        executedSteps += 1
        if !ok {
            missingElements.append(name)
            if let driver, let dir = artifactsDirectory {
                driver.snapshot(to: "\(dir)/unreachable_\(executedSteps).png")
            }
        }
        // Logging is asynchronous; give the log a moment to flush before reading it back.
        try? await Task.sleep(nanoseconds: 250_000_000)
        let (issues, latest) = MihonRuntimeGuard.scan(after: checkpoint)
        checkpoint = latest
        for issue in issues {
            findings.append((name, issue))
        }
    }

    var report: String {
        if findings.isEmpty { return "no SwiftUI runtime issues" }
        return findings.map { "• [\($0.step)] \($0.issue)" }.joined(separator: "\n")
    }
}
