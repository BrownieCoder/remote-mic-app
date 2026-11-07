import Foundation
import Testing
@testable import RemoteMic

struct RC003VoiceHIDScopeTests {
    final class Service {
        let id: UInt64
        var mappings = [RemoteVoiceFunctionMappingPolicy.remoteVoiceKey]
        var accepts = true
        var writes = 0
        init(_ id: UInt64) { self.id = id }
        var service: RemoteVoiceMappingService {
            .init(registryID: id, readMappings: { self.mappings }, setMappings: { updated in
                self.writes += 1
                if self.accepts { self.mappings = updated }
                // Some HID services accept a write without retaining it.
                return true
            })
        }
    }

    @Test func scopesWritesAndRestorationToThePhysicalDeviceAncestor() {
        let mine = Service(1), other = Service(2)
        let services = [mine.service, other.service]
        let targets = RC003VoiceHIDScope.targets(for: "mine", devices: [
            .init(registryID: 17, fingerprint: "mine"), .init(registryID: 18, fingerprint: "other"),
        ], services: services, ancestry: { $0 == 1 ? [1, 8, 17, 23] : [2, 9, 18, 23] })
        #expect(targets.compactMap(\.registryID) == [1])
        let mapper = RemoteNativeKeyMapper(
            mappings: [RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey],
            serviceProvider: { services }, defaults: UserDefaults(suiteName: UUID().uuidString)!,
            bootSession: "test", writeState: { _ in true }, logger: { _ in }
        )
        #expect(mapper.prepare(scopedTargets: targets))
        #expect(mapper.hasVerifiedMappings(in: targets))
        #expect(!mapper.hasVerifiedMappings(in: services))
        #expect(mine.mappings == [RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey])
        #expect(other.writes == 0)
        mine.mappings.append(.init(source: 22, destination: 23))
        mapper.restore()
        #expect(mine.mappings == [.init(source: 22, destination: 23), RemoteVoiceFunctionMappingPolicy.remoteVoiceKey])
        #expect(other.writes == 0)
    }

    @Test func unknownAmbiguousOrNonDescendantServicesDoNotArm() {
        let service = Service(1)
        let mine = RC003VoiceHIDScope.Device(registryID: 17, fingerprint: "mine")
        let ambiguous = RC003VoiceHIDScope.Device(registryID: 18, fingerprint: "mine")
        #expect(RC003VoiceHIDScope.targets(for: "mine", devices: [mine, ambiguous], services: [service.service], ancestry: { _ in [1, 17] }).isEmpty)
        #expect(RC003VoiceHIDScope.targets(for: "mine", devices: [mine], services: [service.service], ancestry: { _ in [1, 9, 23] }).isEmpty)
        #expect(RC003VoiceHIDScope.targets(for: "unknown", devices: [mine], services: [service.service], ancestry: { _ in [1, 17] }).isEmpty)
        #expect(service.writes == 0)
    }

    @Test func historicalOrAmbiguousBluetoothBindingsCannotClaimTheSelectedHID() {
        let mappings = RemoteDeviceMappings(buttonBindings: [:], buttonShortcuts: [:], secondaryButtonBindings: [:])
        let selected = RemoteDeviceProfile(model: .rc003, bluetoothIdentifier: UUID(), hidFingerprint: "a", mappings: mappings)
        #expect(RC003VoiceHIDScope.isUnambiguousProfile(selected, among: [selected]))
        let otherBluetooth = RemoteDeviceProfile(model: .unknown, bluetoothIdentifier: UUID(), mappings: mappings)
        let oldHID = RemoteDeviceProfile(model: .rc001, hidFingerprint: "z", mappings: mappings)
        let duplicate = RemoteDeviceProfile(model: .rc003, bluetoothIdentifier: selected.bluetoothIdentifier, hidFingerprint: "b", mappings: mappings)
        for other in [otherBluetooth, oldHID, duplicate] {
            #expect(!RC003VoiceHIDScope.isUnambiguousProfile(selected, among: [selected, other]))
        }
        let siri = RemoteDeviceProfile(model: .appleSiriRemoteA2854, hidFingerprint: "s", mappings: mappings)
        #expect(RC003VoiceHIDScope.isUnambiguousProfile(selected, among: [selected, siri]))
    }

    @Test func partialReadbackFailureRestoresAllAppliedInterfaces() {
        let first = Service(1), second = Service(2), sibling = Service(3)
        second.accepts = false
        let all = [first.service, second.service, sibling.service]
        let mapper = RemoteNativeKeyMapper(
            mappings: [RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey],
            serviceProvider: { all }, defaults: UserDefaults(suiteName: UUID().uuidString)!,
            bootSession: "test", writeState: { _ in true }, logger: { _ in }
        )
        #expect(!mapper.prepare(scopedTargets: [first.service, second.service]))
        #expect(!mapper.isPrepared)
        #expect(first.mappings == [RemoteVoiceFunctionMappingPolicy.remoteVoiceKey])
        #expect(sibling.writes == 0)
    }
}
