import Foundation
import IOKit.hid
import IOKit.hidsystem

enum RC003VoiceHIDScope {
    struct Device {
        let registryID: UInt64
        let fingerprint: String?
    }

    struct Binding {
        let deviceID: UInt64
        let services: [RemoteVoiceMappingService]

        var observedIDs: Set<UInt64> { Set(services.compactMap(\.registryID)).union([deviceID]) }
    }

    /// The keyboard event service is a descendant of its IOHIDDevice. Siblings on
    /// the same Bluetooth bus can share ancestors, product, or location properties.
    static func binding(for fingerprint: String) -> Binding? {
        guard !fingerprint.isEmpty else { return nil }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x2717,
            kIOHIDProductIDKey: 0x32B8,
        ] as CFDictionary)
        let hidDevices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        // Bluetooth-to-HID binding in older profiles can be inferred. More than
        // one live Xiaomi device makes that inference insufficient for this opt-in.
        guard hidDevices.count == 1 else { return nil }
        var devices: [Device] = []
        for device in hidDevices {
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id) == KERN_SUCCESS else {
                return nil
            }
            devices.append(Device(registryID: id, fingerprint: HIDRemoteMonitor.physicalFingerprint(for: device)))
        }
        let services = targets(for: fingerprint, devices: devices,
                               services: RemoteVoiceFunctionMapper.systemServices(), ancestry: ancestorIDs)
        guard let device = devices.first, !services.isEmpty else { return nil }
        return Binding(deviceID: device.registryID, services: services)
    }

    static func isUnambiguousProfile(_ profile: RemoteDeviceProfile, among profiles: [RemoteDeviceProfile]) -> Bool {
        guard profile.model == .rc003, let identifier = profile.bluetoothIdentifier,
              let fingerprint = profile.hidFingerprint, !fingerprint.isEmpty else { return false }
        return !profiles.contains { other in
            guard other.id != profile.id else { return false }
            if other.bluetoothIdentifier == identifier || other.hidFingerprint == fingerprint { return true }
            return !other.model.usesPrivateAdapter && (other.bluetoothIdentifier != nil || other.hidFingerprint != nil)
        }
    }

    static func targets(
        for fingerprint: String,
        devices: [Device],
        services: [RemoteVoiceMappingService],
        ancestry: (UInt64) -> [UInt64]
    ) -> [RemoteVoiceMappingService] {
        let selected = devices.filter { $0.fingerprint == fingerprint }
        guard !fingerprint.isEmpty, selected.count == 1, let owner = selected.first else { return [] }
        let deviceIDs = Set(devices.map(\.registryID))
        var result: [RemoteVoiceMappingService] = []
        for service in services {
            guard let id = service.registryID,
                  let nearestDevice = ancestry(id).first(where: deviceIDs.contains) else { return [] }
            if nearestDevice == owner.registryID { result.append(service) }
        }
        return result
    }

    private static func ancestorIDs(of id: UInt64) -> [UInt64] {
        guard let matching = IORegistryEntryIDMatching(id) else { return [] }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        var ids: [UInt64] = []
        while entry != 0 {
            var registryID: UInt64 = 0
            var parent: io_registry_entry_t = 0
            let read = IORegistryEntryGetRegistryEntryID(entry, &registryID)
            let ascended = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            if read == KERN_SUCCESS { ids.append(registryID) }
            entry = ascended == KERN_SUCCESS ? parent : 0
        }
        return ids
    }
}

/// A passive IORegistry observer. Only arm the cache when the notification
/// iterators demonstrably cover every verified event service on this Mac.
final class RC003HIDTopologyMonitor {
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var onChange: (() -> Void)?

    func start(serviceIDs: Set<UInt64>, onChange: @escaping () -> Void) -> Bool {
        stop()
        guard !serviceIDs.isEmpty, let port = IONotificationPortCreate(kIOMainPortDefault) else { return false }
        self.port = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        var observed = Set<UInt64>()
        for serviceClass in ["IOHIDDevice", "IOHIDEventService"] {
            for notification in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                guard let matching = IOServiceMatching(serviceClass) else {
                    stop()
                    return false
                }
                var iterator: io_iterator_t = 0
                let result = IOServiceAddMatchingNotification(
                    port, notification, matching, { context, iterator in
                        let changed = RC003HIDTopologyMonitor.consume(iterator)
                        guard !changed.isEmpty, let context else { return }
                        Unmanaged<RC003HIDTopologyMonitor>.fromOpaque(context).takeUnretainedValue().onChange?()
                    }, Unmanaged.passUnretained(self).toOpaque(), &iterator
                )
                guard result == KERN_SUCCESS else {
                    stop()
                    return false
                }
                iterators.append(iterator)
                let initial = Self.consume(iterator)
                if notification == kIOFirstMatchNotification { observed.formUnion(initial) }
            }
        }
        guard serviceIDs.isSubset(of: observed) else {
            stop()
            return false
        }
        self.onChange = onChange
        return true
    }

    func stop() {
        onChange = nil
        if let port { IONotificationPortSetDispatchQueue(port, nil) }
        iterators.forEach { IOObjectRelease($0) }
        iterators.removeAll()
        if let port { IONotificationPortDestroy(port) }
        port = nil
    }

    private static func consume(_ iterator: io_iterator_t) -> Set<UInt64> {
        var ids = Set<UInt64>()
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS { ids.insert(id) }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return ids
    }

    deinit { stop() }
}
