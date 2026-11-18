import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Test anchors (DEBUG-only hit targets for the in-process UI self-test)
//
// SwiftUI only builds its accessibility tree while an assistive client is attached, so an in-process driver
// cannot rely on it. Instead, interactive views publish their on-screen frame under a stable identifier
// (much like `accessibilityIdentifier`). The self-test then injects real mouse events at those positions,
// so hit-testing, gestures and presentations still run through the normal event pipeline.
// Anchors are inert unless a test enables the registry before building views.

@MainActor
public final class MihonTestAnchorRegistry {
    public static let shared = MihonTestAnchorRegistry()
    /// Read while views are built; only tests flip it.
    public nonisolated(unsafe) static var isEnabled = false

    /// Resolves the window an anchor lives in (a `.sheet` is a separate window on macOS).
    @MainActor
    final class WindowBox {
        #if os(macOS)
        weak var view: NSView?
        var windowNumber: Int? { view?.window?.windowNumber }
        #else
        var windowNumber: Int? { nil }
        #endif
    }

    /// One live view publishing an identifier. Several may share it — the same title on two library pages,
    /// every screen's back arrow, home tabs kept alive behind the selected one — so each is tracked separately
    /// and only visible ones are reachable; among those the most recently shown wins.
    private struct Instance {
        var frame: CGRect
        var isVisible: Bool
        var sequence: Int
        let window: WindowBox
    }

    private var instances: [String: [UUID: Instance]] = [:]
    private var sequence = 0

    func update(_ id: String, owner: UUID, frame: CGRect, isVisible: Bool, window: WindowBox, appeared: Bool) {
        var entries = instances[id, default: [:]]
        let order: Int
        if let existing = entries[owner], !appeared {
            order = existing.sequence
        } else {
            sequence += 1
            order = sequence
        }
        entries[owner] = Instance(frame: frame, isVisible: isVisible, sequence: order, window: window)
        instances[id] = entries
    }

    func remove(_ id: String, owner: UUID) {
        instances[id]?[owner] = nil
        if instances[id]?.isEmpty == true { instances[id] = nil }
    }

    private func reachable(_ id: String, windowNumber: Int?) -> Instance? {
        instances[id]?.values
            .filter { $0.isVisible && (windowNumber == nil || $0.window.windowNumber == windowNumber) }
            .max { $0.sequence < $1.sequence }
    }

    /// Visible part of the anchor in its hosting view's coordinates (top-left origin).
    public func frame(_ id: String, windowNumber: Int? = nil) -> CGRect? {
        reachable(id, windowNumber: windowNumber)?.frame
    }

    public func identifiers(withPrefix prefix: String, windowNumber: Int? = nil) -> [String] {
        instances.keys
            .filter { $0.hasPrefix(prefix) && reachable($0, windowNumber: windowNumber) != nil }
            .sorted()
    }

    public func reset() {
        instances.removeAll()
    }
}

extension EnvironmentValues {
    /// Content that is kept alive but not shown (home tabs behind the selected one).
    public var mihonContentHidden: Bool {
        get { self[MihonContentHiddenKey.self] }
        set { self[MihonContentHiddenKey.self] = newValue }
    }
}

private struct MihonContentHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

#if DEBUG
private struct MihonTestAnchorModifier: ViewModifier {
    let id: String
    @Environment(\.mihonContentHidden) private var contentHidden
    @State private var owner = UUID()
    @State private var window = MihonTestAnchorRegistry.WindowBox()

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                let geometry = MihonAnchorGeometry(proxy, hidden: contentHidden)
                Color.clear
                    .onAppear { publish(geometry, appeared: true) }
                    .onChange(of: geometry) { _, newValue in publish(newValue, appeared: false) }
                    // An identifier that changes in place (`action.heart` → `action.heart.fill`) moves the anchor.
                    .onChange(of: id) { oldId, _ in
                        MihonTestAnchorRegistry.shared.remove(oldId, owner: owner)
                        publish(geometry, appeared: true)
                    }
                    .onDisappear { MihonTestAnchorRegistry.shared.remove(id, owner: owner) }
            }
            #if os(macOS)
            .background(MihonAnchorWindowProbe(box: window))
            #endif
        }
    }

    private func publish(_ geometry: MihonAnchorGeometry, appeared: Bool) {
        MihonTestAnchorRegistry.shared.update(
            id, owner: owner, frame: geometry.visibleFrame, isVisible: geometry.isVisible, window: window, appeared: appeared
        )
    }
}

/// The on-screen part of a view: its bounds clipped by the enclosing horizontal and vertical scroll views, so
/// pager pages and rows scrolled out of the viewport (still alive in lazy containers) are not clickable.
private struct MihonAnchorGeometry: Equatable {
    let visibleFrame: CGRect
    let isVisible: Bool

    init(_ proxy: GeometryProxy, hidden: Bool) {
        var visible = CGRect(origin: .zero, size: proxy.size)
        for axis in [Axis.horizontal, .vertical] {
            if let viewport = proxy.bounds(of: .scrollView(axis: axis)) {
                visible = visible.intersection(viewport)
            }
        }
        let origin = proxy.frame(in: .global).origin
        visibleFrame = visible.isNull ? .zero : visible.offsetBy(dx: origin.x, dy: origin.y)
        isVisible = !hidden && visibleFrame.width > 1 && visibleFrame.height > 1
    }
}

#if os(macOS)
/// Zero-cost marker view that lets the registry tell which window (main window or a sheet) an anchor is in.
private struct MihonAnchorWindowProbe: NSViewRepresentable {
    let box: MihonTestAnchorRegistry.WindowBox

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
#endif

extension View {
    /// Publishes this view's frame for the UI self-test. A no-op in release builds and in normal runs.
    @ViewBuilder
    func mihonTestAnchor(_ id: String) -> some View {
        #if DEBUG
        if MihonTestAnchorRegistry.isEnabled {
            self.modifier(MihonTestAnchorModifier(id: id))
        } else {
            self
        }
        #else
        self
        #endif
    }
}
