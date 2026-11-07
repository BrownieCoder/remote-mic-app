import ApplicationServices
import CoreAudio
import Foundation

// Only opaque focus references, public window numbers, and Core Audio route metadata.
enum DoubaoRearmMetadata {
    typealias Gate = DoubaoRearmState
    static let ime = "com.bytedance.inputmethod.doubaoime"

    // Strong process-local references, no attribute values describing a field.
    // Discard both at the end of the watch. Identity is compared off-main.
    struct Focus {
        let process: pid_t
        let window: AXUIElement
        let element: AXUIElement
        static func capture(_ pid: pid_t) -> Self? {
            // Asking an inactive app for its "focused" field can return its
            // previous field. Check only the identity of the system focus owner.
            var focusedApp: CFTypeRef?
            let system = AXUIElementCreateSystemWide()
            guard
                AXUIElementCopyAttributeValue(
                    system, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
                let focusedApp, CFGetTypeID(focusedApp) == AXUIElementGetTypeID()
            else { return nil }
            let app = focusedApp as! AXUIElement
            var owner: pid_t = 0
            guard AXUIElementGetPid(app, &owner) == .success, owner == pid,
                AXUIElementSetMessagingTimeout(app, 0.15) == .success
            else { return nil }
            func reference(_ key: CFString) -> AXUIElement? {
                var result: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, key, &result) == .success,
                    let result, CFGetTypeID(result) == AXUIElementGetTypeID()
                else { return nil }
                let ref = result as! AXUIElement
                var owner: pid_t = 0
                guard AXUIElementGetPid(ref, &owner) == .success, owner == pid else { return nil }
                return ref
            }
            guard let window = reference(kAXFocusedWindowAttribute as CFString),
                let element = reference(kAXFocusedUIElementAttribute as CFString),
                !CFEqual(app, element), !CFEqual(window, element)
            else { return nil }
            return Self(process: pid, window: window, element: element)
        }
        func isCurrent() -> Bool {
            guard let live = Self.capture(process) else { return false }
            return CFEqual(window, live.window) && CFEqual(element, live.element)
        }
    }
    private static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope
    ) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func ids(
        _ parent: AudioObjectID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [UInt32]? {
        var a = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectHasProperty(parent, &a),
            AudioObjectGetPropertyDataSize(parent, &a, 0, nil, &size) == noErr,
            size <= 8192, size % 4 == 0
        else { return nil }
        if size == 0 { return [] }
        var out = [UInt32](repeating: 0, count: Int(size / 4))
        let ok = out.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(parent, &a, 0, nil, &size, $0.baseAddress!) == noErr
        }
        return ok ? Array(out.prefix(Int(size / 4))) : nil
    }
    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector)
        -> String?
    {
        var a = address(selector, kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectHasProperty(id, &a),
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr
        else { return nil }
        return value?.takeRetainedValue() as String?
    }
    static func supportedUniqueFixture(_ device: AudioDeviceID) -> Bool {
        guard #available(macOS 14.2, *), device != 0,
            let devices = ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        else { return false }
        return devices.filter {
            string($0, kAudioDevicePropertyDeviceUID) == DoubaoAudioDevicePolicy.deviceUID
        } == [device]
            && ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
                != nil
    }
    static func reader(_ scope: Gate.Scope) -> Gate.Reader {
        guard #available(macOS 14.2, *),
            let processes = ids(
                AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList),
            string(scope.outputDevice, kAudioDevicePropertyDeviceUID) == DoubaoAudioDevicePolicy.deviceUID
        else { return .unknown }
        var found = false
        var active = false
        for process in processes {
            guard let pid = ids(process, kAudioProcessPropertyPID)?.first,
                let running = ids(process, kAudioProcessPropertyIsRunningInput)?.first
            else { return .unknown }
            let isTarget = pid == UInt32(bitPattern: scope.imePID)
            if isTarget {
                guard string(process, kAudioProcessPropertyBundleID) == ime, !found else { return .unknown }
                found = true
            }
            if running == 0 { continue }
            guard let inputs = ids(process, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput),
                !inputs.isEmpty
            else { return .unknown }
            if isTarget {
                guard inputs.allSatisfy({ $0 == scope.outputDevice }) else { return .unknown }
                active = true
            } else if inputs.contains(scope.outputDevice)
                || string(process, kAudioProcessPropertyBundleID) == ime
            {
                return .unknown
            }
        }
        return found ? (active ? .active : .idle) : .unknown
    }
    // A visible destination metadata witness is distinct from AX focus. Avoid
    // private AX-to-CG window numbering and do not infer focus from z-order.
    static func windows(destination: pid_t, ime: pid_t) -> (destination: UInt32, panel: Gate.Panel)? {
        guard
            let rows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[CFString: Any]]
        else { return nil }
        return classifyWindows(rows, destination: destination, ime: ime)
    }

    static func classifyWindows(_ rows: [[CFString: Any]], destination: pid_t, ime: pid_t)
        -> (destination: UInt32, panel: Gate.Panel)?
    {
        guard destination != ime else { return nil }
        var receiver: UInt32?
        var target: UInt32?
        for row in rows {
            guard let pid = (row[kCGWindowOwnerPID] as? NSNumber)?.int32Value else { return nil }
            guard pid == destination || pid == ime else { continue }
            guard let id = (row[kCGWindowNumber] as? NSNumber)?.uint32Value, id > 0 else { return nil }
            if pid == destination {
                guard receiver == nil else { return nil }
                receiver = id
            } else {
                guard target == nil else { return nil }
                target = id
            }
        }
        guard let receiver else { return nil }
        return (receiver, target.map(Gate.Panel.unique) ?? .absent)
    }

    static func panel(_ scope: Gate.Scope, destinationWitness: UInt32) -> Gate.Panel {
        guard let observed = windows(destination: scope.destinationPID, ime: scope.imePID),
            observed.destination == destinationWitness
        else { return .ambiguous }
        return observed.panel
    }
}

// A receiving app must implement both focus notifications. No field/window
// attributes or callback elements are read here. A failed registration makes
// the target ineligible. The OS may still omit notifications for some apps.
final class DoubaoFocusNotifications {
    private let observer: AXObserver
    private static var handlers: [UInt: () -> Void] = [:]  // main run loop only
    private static func key(_ observer: AXObserver) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(observer).toOpaque())
    }
    private init(_ observer: AXObserver) { self.observer = observer }

    static func prepareOffMain(receiver: pid_t) -> DoubaoFocusNotifications? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        var observer: AXObserver?
        let callback: AXObserverCallback = { observer, _, _, _ in
            DoubaoFocusNotifications.handlers[DoubaoFocusNotifications.key(observer)]?()
        }
        guard AXObserverCreate(receiver, callback, &observer) == .success, let observer else {
            return nil
        }
        let app = AXUIElementCreateApplication(receiver)
        guard
            AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, nil)
                == .success,
            AXObserverAddNotification(
                observer, app, kAXFocusedUIElementChangedNotification as CFString, nil) == .success
        else { return nil }
        return DoubaoFocusNotifications(observer)
    }
    func attachOnMain(_ invalidate: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        Self.handlers[Self.key(observer)] = invalidate
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
    func detachOnMain() {
        dispatchPrecondition(condition: .onQueue(.main))
        Self.handlers.removeValue(forKey: Self.key(observer))
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}
