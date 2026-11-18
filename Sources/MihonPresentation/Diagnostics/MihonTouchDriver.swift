#if DEBUG && canImport(UIKit)
import UIKit
import OSLog
import MihonDomain

/// DEBUG: finger drags in the simulator, which takes touches only from the Mac's mouse. `MIHON_TOUCH_SCRIPT` runs
/// once the reader opened by `MIHON_OPEN_READER` has had `MIHON_TOUCH_DELAY` seconds (6) to load:
///
///     wait 1.5; drag 0.2,0.5 0.8,0.5 0.4; drag 0.8,0.5 0.45,0.5 0.3 0.45,0.5 1 0.8,0.5 0.3
///
/// `drag` presses at the first point (fractions of the window), moves to each next point over its seconds (the same
/// point twice holds still) and lifts at the last. UIKit's private touch path, as KIF drives it: one `UITouch` moved
/// through its phases inside the application's touches event, each event carrying the IOHIDEvent that gesture
/// recognizers read. Every step is logged (the bundle id / `TouchDriver`).
@MainActor
enum MihonTouchDriver {
    static let log = Logger(subsystem: MihonAppIdentity.bundleId, category: "TouchDriver")

    static func runFromEnvironment() async {
        let environment = ProcessInfo.processInfo.environment
        guard let script = environment["MIHON_TOUCH_SCRIPT"] else { return }
        let delay = environment["MIHON_TOUCH_DELAY"].flatMap(Double.init) ?? 6
        try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
        for command in script.split(separator: ";") {
            let words = command.split(separator: " ").map(String.init)
            guard let verb = words.first else { continue }
            switch verb {
            case "wait":
                let seconds = words.dropFirst().first.flatMap(Double.init) ?? 1
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            case "drag":
                // A point, then (seconds, point) pairs.
                let rest = Array(words.dropFirst())
                guard let start = point(rest.first) else { continue }
                var legs: [(seconds: Double, to: CGPoint)] = []
                var index = 1
                while index + 1 < rest.count, let seconds = Double(rest[index]), let to = point(rest[index + 1]) {
                    legs.append((seconds, to))
                    index += 2
                }
                await drag(from: start, legs: legs)
            default:
                log.error("unknown command \(verb, privacy: .public)")
            }
        }
        log.notice("script finished")
    }

    private static func point(_ word: String?) -> CGPoint? {
        let parts = word?.split(separator: ",").compactMap { Double($0) } ?? []
        return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
    }

    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    /// Presses, moves along the legs at 60 Hz and lifts.
    private static func drag(from start: CGPoint, legs: [(seconds: Double, to: CGPoint)]) async {
        guard let window else {
            log.error("no key window")
            return
        }
        let size = window.bounds.size
        func inWindow(_ fraction: CGPoint) -> CGPoint { CGPoint(x: fraction.x * size.width, y: fraction.y * size.height) }
        var location = inWindow(start)
        let touch = UITouch()
        guard begin(touch, at: location, in: window) else { return }
        log.notice("down \(Int(location.x)),\(Int(location.y))")
        for leg in legs {
            let from = location
            let to = inWindow(leg.to)
            let steps = max(1, Int(leg.seconds * 60))
            for step in 1...steps {
                try? await Task.sleep(nanoseconds: 16_666_667)
                let t = CGFloat(step) / CGFloat(steps)
                location = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                move(touch, to: location, phase: from == to ? .stationary : .moved)
            }
            log.notice("at \(Int(location.x)),\(Int(location.y))")
        }
        try? await Task.sleep(nanoseconds: 16_666_667)
        move(touch, to: location, phase: .ended)
        log.notice("up \(Int(location.x)),\(Int(location.y))")
    }

    // MARK: UIKit's touch path

    private static func begin(_ touch: UITouch, at location: CGPoint, in window: UIWindow) -> Bool {
        let view = window.hitTest(location, with: nil)
        // The window first: setting it resets other values.
        guard setObject(touch, "setWindow:", window) else {
            log.error("UITouch has no setWindow:")
            return false
        }
        setInteger(touch, "setTapCount:", 1)
        setLocation(touch, location, resetPrevious: true)
        setObject(touch, "setView:", view)
        setObject(touch, "setGestureView:", view)
        setBool(touch, "_setIsTapToClick:", false)
        setInteger(touch, "setPhase:", UITouch.Phase.began.rawValue)
        setDouble(touch, "setTimestamp:", ProcessInfo.processInfo.systemUptime)
        if let hidEvent = HIDEvent.make(for: touch, at: location) {
            setPointer(touch, "_setHidEvent:", hidEvent)
            HIDEvent.release(hidEvent)
        }
        send(touch, at: location)
        return true
    }

    private static func move(_ touch: UITouch, to location: CGPoint, phase: UITouch.Phase) {
        setDouble(touch, "setTimestamp:", ProcessInfo.processInfo.systemUptime)
        setLocation(touch, location, resetPrevious: false)
        setInteger(touch, "setPhase:", phase.rawValue)
        send(touch, at: location)
    }

    private static func send(_ touch: UITouch, at location: CGPoint) {
        let application = UIApplication.shared
        let touchesEvent = NSSelectorFromString("_touchesEvent")
        guard application.responds(to: touchesEvent),
              let event = application.perform(touchesEvent)?.takeUnretainedValue() as? UIEvent else {
            log.error("no touches event")
            return
        }
        callPlain(event, "_clearTouches")
        if let hidEvent = HIDEvent.make(for: touch, at: location) {
            setPointer(event, "_setHIDEvent:", hidEvent)
            HIDEvent.release(hidEvent)
        }
        addTouch(event, touch)
        application.sendEvent(event)
    }

    // MARK: Private setters (through their implementations: Swift cannot `perform` with scalars)

    @discardableResult
    private static func setObject(_ target: NSObject, _ name: String, _ value: AnyObject?) -> Bool {
        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        guard let imp = implementation(target, name) else { return false }
        unsafeBitCast(imp, to: Setter.self)(target, NSSelectorFromString(name), value)
        return true
    }

    private static func setInteger(_ target: NSObject, _ name: String, _ value: Int) {
        typealias Setter = @convention(c) (AnyObject, Selector, Int) -> Void
        guard let imp = implementation(target, name) else { return }
        unsafeBitCast(imp, to: Setter.self)(target, NSSelectorFromString(name), value)
    }

    private static func setDouble(_ target: NSObject, _ name: String, _ value: Double) {
        typealias Setter = @convention(c) (AnyObject, Selector, Double) -> Void
        guard let imp = implementation(target, name) else { return }
        unsafeBitCast(imp, to: Setter.self)(target, NSSelectorFromString(name), value)
    }

    private static func setBool(_ target: NSObject, _ name: String, _ value: Bool) {
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        guard let imp = implementation(target, name) else { return }
        unsafeBitCast(imp, to: Setter.self)(target, NSSelectorFromString(name), value)
    }

    private static func setPointer(_ target: NSObject, _ name: String, _ value: UnsafeMutableRawPointer) {
        typealias Setter = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Void
        guard let imp = implementation(target, name) else { return }
        unsafeBitCast(imp, to: Setter.self)(target, NSSelectorFromString(name), value)
    }

    private static func setLocation(_ touch: UITouch, _ location: CGPoint, resetPrevious: Bool) {
        typealias Setter = @convention(c) (AnyObject, Selector, CGPoint, Bool) -> Void
        let name = "_setLocationInWindow:resetPrevious:"
        guard let imp = implementation(touch, name) else { return }
        unsafeBitCast(imp, to: Setter.self)(touch, NSSelectorFromString(name), location, resetPrevious)
    }

    private static func callPlain(_ target: NSObject, _ name: String) {
        typealias Method = @convention(c) (AnyObject, Selector) -> Void
        guard let imp = implementation(target, name) else { return }
        unsafeBitCast(imp, to: Method.self)(target, NSSelectorFromString(name))
    }

    private static func addTouch(_ event: UIEvent, _ touch: UITouch) {
        typealias Method = @convention(c) (AnyObject, Selector, AnyObject, Bool) -> Void
        let name = "_addTouch:forDelayedDelivery:"
        guard let imp = implementation(event, name) else { return }
        unsafeBitCast(imp, to: Method.self)(event, NSSelectorFromString(name), touch, false)
    }

    private static func implementation(_ target: NSObject, _ name: String) -> IMP? {
        let selector = NSSelectorFromString(name)
        guard target.responds(to: selector) else {
            log.debug("no \(name, privacy: .public) on \(String(describing: type(of: target)), privacy: .public)")
            return nil
        }
        return target.method(for: selector)
    }
}

/// IOKit's digitizer events (private, looked up at run time): a hand with one finger at the touch's location.
@MainActor
private enum HIDEvent {
    private typealias CreateDigitizer = @convention(c) (
        CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32,
        Double, Double, Double, Double, Double, UInt8, UInt8, UInt32
    ) -> UnsafeMutableRawPointer?
    private typealias CreateFinger = @convention(c) (
        CFAllocator?, UInt64, UInt32, UInt32, UInt32,
        Double, Double, Double, Double, Double, Double, Double, Double, Double, Double, UInt8, UInt8, UInt32
    ) -> UnsafeMutableRawPointer?
    private typealias SetInteger = @convention(c) (UnsafeMutableRawPointer, UInt32, Int32, UInt32) -> Void
    private typealias Append = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32) -> Void

    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let iokit, let pointer = dlsym(iokit, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
    private static let createDigitizer = symbol("IOHIDEventCreateDigitizerEvent", CreateDigitizer.self)
    private static let createFinger = symbol("IOHIDEventCreateDigitizerFingerEventWithQuality", CreateFinger.self)
    private static let setInteger = symbol("IOHIDEventSetIntegerValueWithOptions", SetInteger.self)
    private static let append = symbol("IOHIDEventAppendEvent", Append.self)

    // IOHIDEventTypes.h: hand transducer, range / touch / position masks, digitizer field 25 (display integrated).
    private static let transducerHand: UInt32 = 3
    private static let eventRange: UInt32 = 1 << 0
    private static let eventTouch: UInt32 = 1 << 1
    private static let eventPosition: UInt32 = 1 << 2
    private static let fieldIsDisplayIntegrated: UInt32 = (11 << 16) | 25

    static func make(for touch: UITouch, at location: CGPoint) -> UnsafeMutableRawPointer? {
        guard let createDigitizer, let createFinger, let setInteger, let append else { return nil }
        let time = mach_absolute_time()
        guard let hand = createDigitizer(nil, time, transducerHand, 0, 0, eventTouch, 0, 0, 0, 0, 0, 0, 0, 0, 0) else {
            return nil
        }
        setInteger(hand, fieldIsDisplayIntegrated, 1, 0xF000_0000)
        let moving = touch.phase == .moved
        let touching: UInt8 = touch.phase == .ended || touch.phase == .cancelled ? 0 : 1
        let mask = moving ? eventPosition : eventRange | eventTouch
        if let finger = createFinger(
            nil, time, 1, 2, mask, Double(location.x), Double(location.y), 0, 0, 0, 0, 0, 0, 0, 0,
            touching, touching, 0
        ) {
            setInteger(finger, fieldIsDisplayIntegrated, 1, 0xF000_0000)
            append(hand, finger, 0)
            release(finger)
        }
        return hand
    }

    static func release(_ event: UnsafeMutableRawPointer) {
        Unmanaged<AnyObject>.fromOpaque(event).release()
    }
}
#endif
