import ApplicationServices
import Foundation
import Testing
@testable import RemoteMic

struct DoubaoRearmTests {
    typealias State = DoubaoRearmState

    /// Exercises the actual managed-key and PCM FIFO with metadata delivered
    /// separately from physical START/STOP and the device-presentation fence.
    private final class Rig {
        let state = State()
        var tick: UInt64 = 0
        var events: [String] = []
        var pending: Set<Int> = []
        var deferred: [() -> Void] = []
        var reset: (() -> Void)?
        lazy var session = RC003HeldFnSession(
            playback: { .init(pendingSamples: self.pending.contains($0) ? 1 : 0, interrupted: false) },
            now: { 0 }, schedule: { _, callback in self.deferred.append(callback) },
            onAbort: { self.events.append("abort-\($0)") }
        )
        init() {
            session.resetGuardedOutput = { self.reset = $0; self.events.append("reset-isolated") }
            session.onGuardedRejection = { [weak self] id, reason in
                guard let self, self.state.contains(id) else { return }
                self.apply(self.state.rejectedByQueue(id, reason: reason))
            }
        }
        @discardableResult func start(_ n: Int) -> State.Admission? {
            let ad = state.physicalStart()
            let accepted = session.start(targetGate: ad?.gated == true ? ad?.id : nil) { down in
                self.tick += 1
                self.events.append("\(n)\(down ? "+" : "-")")
                if let ad { self.state.key(ad.id, down: down, at: self.tick) }
                return true
            }
            if !accepted, let ad { state.unaccepted(ad.id) }
            return ad
        }
        func audio(_ n: Int) {
            _ = session.deliver([Int16(n), 0], enqueue: { samples in
                self.events.append("audio-\(samples[0])-\(samples.count)")
                self.pending.insert(n)
                return true
            }, discardWithReason: { count,reason in self.events.append("drop-\(n)-\(count)-\(reason)") })
        }
        func presented(_ n: Int) {
            pending.remove(n)
            let callbacks = deferred
            deferred.removeAll()
            callbacks.forEach { $0() }
        }
        func stop(_ n: Int) { session.stop(deliveryGeneration: n) }
        func observe(_ before: State.Reader, _ panel: State.Panel, _ after: State.Reader? = nil,
                     epoch: UInt64? = nil) {
            tick += 2
            apply(state.observe(.init(begin: tick - 1, end: tick, before: before, panel: panel, after: after ?? before),
                                epoch: epoch ?? state.epoch, canOpen: session.canOpenGuarded))
        }
        func apply(_ action: State.Action?) {
            switch action {
            case .down(let token): _ = session.openGuarded(token)
            case .audio(let token): session.confirmGuardedReader(token)
            case .cancel(let ids, let reason):
                for id in ids.reversed() { session.rejectGuarded(id, reason: reason) }
            case nil: break
            }
        }
        func verifiedA() {
            observe(.idle, .absent)
            _ = start(1)
            observe(.idle, .absent)
            observe(.active, .unique(47))
            audio(1)
            stop(1)
        }
    }

    @Test func windowsAreUniqueForBothProcessesAndMatchTheActualReceiver() {
        func row(_ pid: Int, _ id: Int) -> [CFString: Any] {
            [kCGWindowOwnerPID: NSNumber(value: pid), kCGWindowNumber: NSNumber(value: id)]
        }
        let single = [row(11, 91), row(99, 92)]
        #expect(DoubaoRearmMetadata.classifyWindows(single, destination: 11, ime: 22)?.panel == .absent)
        #expect(DoubaoRearmMetadata.classifyWindows(single + [row(22, 93)], destination: 11, ime: 22)?.panel == .unique(93))
        #expect(DoubaoRearmMetadata.classifyWindows(single + [row(22, 93), row(22, 94)], destination: 11, ime: 22) == nil)
        #expect(DoubaoRearmMetadata.classifyWindows(single + [row(11, 95)], destination: 11, ime: 22) == nil)
        #expect(DoubaoRearmMetadata.classifyWindows([row(22, 93)], destination: 11, ime: 22) == nil)
    }

    @Test func coldOrUnqualifiedFirstSentenceUsesExistingPath() {
        let r = Rig()
        #expect(r.start(1) == nil)
        r.audio(1); r.stop(1); r.presented(1)
        #expect(r.events == ["1+", "audio-1-2", "1-"])
        r.observe(.idle, .absent)
        #expect(r.start(2)?.gated == false)
        r.observe(.active, .absent) // no window has ever been witnessed
        r.audio(2); r.stop(2)
        #expect(r.start(3) == nil)
        r.presented(2)
        #expect(r.events.suffix(2) == ["2-", "3+"])
    }

    @Test func threeAcceptedStopsRollAcrossTwoSeparatelyProvenCaptureRestarts() {
        let r = Rig()
        r.verifiedA()
        #expect(r.start(2)?.gated == true)
        r.audio(2); r.stop(2)
        #expect(r.start(3)?.gated == true)
        r.audio(3); r.stop(3)
        r.presented(1)
        #expect(r.events == ["1+", "audio-1-2", "1-"])
        let prior = r.state.epoch
        r.observe(.active, .unique(47))
        r.observe(.active, .absent, .idle)
        #expect(r.events.last == "1-")
        r.observe(.idle, .absent)
        #expect(r.events.last == "2+")
        r.observe(.active, .unique(56), epoch: prior)
        r.observe(.idle, .absent)
        #expect(r.events.last == "2+")
        r.observe(.active, .unique(56))
        r.observe(.active, .unique(56))
        #expect(r.events.last == "audio-2-2")
        r.presented(2)
        #expect(r.events.last == "2-")
        r.observe(.idle, .unique(56))
        r.observe(.idle, .absent)
        #expect(r.events.last == "3+")
        r.observe(.active, .unique(80))
        r.presented(3)
        #expect(r.events == ["1+", "audio-1-2", "1-", "2+", "audio-2-2", "2-", "3+", "audio-3-2", "3-"])
        r.observe(.idle, .unique(80))
        r.observe(.idle, .absent)
        #expect(r.state.hasBaseline)
        #expect(r.state.demand == .none)
        #expect(r.start(4)?.gated == false)
    }

    @Test func fastInitialOpenIsUnattributedAndRequiresClearAndNewReaderBeforeGivingBAnyPCM() {
        let r = Rig()
        r.observe(.idle, .absent)
        #expect(r.start(1)?.gated == false)
        r.observe(.active, .unique(19))
        #expect(r.state.sawUnattributedOccupancy)
        r.audio(1); r.stop(1)
        #expect(r.start(2)?.gated == true)
        r.audio(2); r.stop(2); r.presented(1)
        r.observe(.idle, .unique(19))
        #expect(r.events == ["1+", "audio-1-2", "1-"])
        r.observe(.idle, .absent)
        #expect(r.events.last == "2+")
        r.observe(.active, .unique(27))
        r.presented(2)
        #expect(r.events.suffix(3) == ["2+", "audio-2-2", "2-"])
    }

    @Test func busyStateAlreadyKnownBeforeInitialKeyDoesNotArmTheNewObservation() {
        let r = Rig()
        r.observe(.idle, .absent)
        r.observe(.active, .unique(19))
        #expect(r.start(1) == nil)
        r.audio(1); r.stop(1); r.presented(1)
        #expect(r.events == ["1+", "audio-1-2", "1-"])
    }

    @Test func clearAfterReleaseOfAnObservedWindowPreservesBAndCButAStraddlingReplyCannotGrant() {
        let r = Rig()
        r.verifiedA()
        _ = r.start(2); r.audio(2); r.stop(2)
        _ = r.start(3); r.audio(3); r.stop(3); r.presented(1)
        r.apply(r.state.observe(.init(begin: r.tick - 1, end: r.tick + 1, before: .idle, panel: .absent, after: .idle),
                                epoch: r.state.epoch, canOpen: r.session.canOpenGuarded))
        #expect(r.events.last == "1-")
        r.observe(.idle, .absent)
        #expect(r.events.last == "2+")
        r.observe(.active, .unique(56)); r.presented(2)
        r.observe(.idle, .absent)
        #expect(r.events.last == "3+")
        r.observe(.active, .unique(57)); r.presented(3)
        #expect(r.events == ["1+", "audio-1-2", "1-", "2+", "audio-2-2", "2-", "3+", "audio-3-2", "3-"])
    }

    @Test func aWindowFirstSeenAfterBReleaseCannotOpenCOrWithholdB() {
        let r = Rig()
        var observed = [State.WindowObservation]()
        r.state.onGuardedWindow = { _, event in observed.append(event) }
        r.verifiedA()
        _ = r.start(2); r.audio(2); r.stop(2)
        _ = r.start(3); r.audio(3); r.stop(3); r.presented(1)
        r.observe(.idle, .absent); r.observe(.active, .absent); r.presented(2)
        r.observe(.active, .absent); r.observe(.idle, .unique(56))
        #expect(r.events.last == "2-")
        r.observe(.idle, .absent)
        #expect(!r.events.contains("3+"))
        #expect(r.events.contains("audio-2-2"))
        #expect(r.events.last == "drop-3-2-target_window_unconfirmed")
        #expect(observed == [.unseenAtUp, .afterUp])
    }

    @Test func changedWindowAmbiguousRouteOrReceiverWithdrawsDescendantsWithoutDuplicatingFn() {
        for (condition, expected) in [(0, "target_window_changed"), (1, "target_window_ambiguous"),
                                      (2, "target_reader_unknown"), (3, "receiver_focus_changed")] {
            let r = Rig()
            r.verifiedA()
            _ = r.start(2); r.audio(2); r.stop(2)
            _ = r.start(3); r.audio(3)
            r.presented(1)
            switch condition {
            case 0: r.observe(.idle, .unique(48))
            case 1: r.observe(.idle, .ambiguous)
            case 2: r.observe(.unknown, .absent)
            default: r.apply(r.state.invalidate(expected))
            }
            #expect(r.events.suffix(2) == ["drop-3-2-\(expected)", "drop-2-2-\(expected)"])
            r.audio(3); r.stop(3)
            #expect(r.events.last == "drop-3-2-\(expected)")
            #expect(!r.session.isBusy)
            #expect(r.start(4) == nil)
            #expect(r.events.last == "4+")
        }
    }

    @Test func excessiveNewestPressPreservesItsAcceptedPredecessors() {
        let r = Rig()
        r.verifiedA()
        _ = r.start(2); r.audio(2); r.stop(2)
        _ = r.start(3)
        let tooLarge = [Int16](repeating: 0, count: RC003HeldFnSession.maximumBufferedSamples)
        #expect(!r.session.deliver(tooLarge, enqueue: { _ in false }, discardWithReason: { _, reason in
            r.events.append(reason)
        }))
        r.stop(3)
        #expect(r.events == ["1+", "audio-1-2", "preroll_full"])
        r.presented(1); r.observe(.idle, .unique(47)); r.observe(.idle, .absent)
        r.observe(.active, .unique(58)); r.presented(2)
        #expect(r.events.suffix(4) == ["1-", "2+", "audio-2-2", "2-"])
    }

    @Test func aReappearingPanelOrUnsolicitedReaderCannotAuthorizeTheNextKey() {
        for oldPanelReappears in [true, false] {
            let r = Rig()
            r.verifiedA()
            _ = r.start(2); r.audio(2); r.stop(2); r.presented(1)
            r.observe(.active, .unique(47))
            if oldPanelReappears {
                r.observe(.active, .absent)
                r.observe(.active, .unique(47))
            } else {
                r.observe(.idle, .unique(47))
                r.observe(.active, .unique(47))
            }
            r.observe(.idle, .absent)
            #expect(!r.events.contains("2+"))
            #expect(r.events.last?.hasPrefix("drop-2-2-target_") == true)
        }
    }

    @Test func positiveHALAndInputSourceReceiptsHaveAnExclusiveMonotonicDeadline() {
        typealias Permit = DoubaoAdjacentDictation.ReaderPermit
        let first = Permit(token: 2, sampleBeganAt: 1_000, sourceCheckedAt: 1_002)
        #expect(first.expires == 1_000 + Permit.maximumAge)
        #expect(first.allows(2, at: first.expires - 1))
        #expect(!first.allows(2, at: first.expires))
        #expect(!first.allows(2, at: first.expires + 1))
        #expect(!first.allows(3, at: first.expires - 1))
        let newerHAL = Permit(token: 2, sampleBeganAt: 90_000_000, sourceCheckedAt: 1_002)
        #expect(newerHAL.expires == 1_002 + Permit.maximumAge)
        let newerSource = Permit(token: 2, sampleBeganAt: 1_000, sourceCheckedAt: 90_000_000)
        #expect(newerSource.expires == first.expires)
    }

    @Test func aLongBufferedHandoffAtTheCutoffDiscardsOnlyUnsubmittedBatchesAndResetsOnce() {
        let r = Rig()
        var now: UInt64 = 0
        let permission = DoubaoAdjacentDictation.ReaderPermit(token: 2, sampleBeganAt: 0, sourceCheckedAt: 0)
        r.session.guardedAudioIsFresh = { permission.allows($0, at: now) }
        r.verifiedA()
        _ = r.start(2)
        for n: Int16 in [21, 22, 23] {
            _ = r.session.deliver([n, 0], enqueue: { samples in
                r.events.append("submitted-\(samples[0])")
                now = permission.expires
                return true
            }, discardWithReason: { count, reason in r.events.append("lost-\(n)-\(count)-\(reason)") })
        }
        r.stop(2); r.presented(1); r.observe(.idle, .absent)
        now = permission.expires - 1
        r.observe(.active, .unique(32))
        #expect(r.events.contains("submitted-21"))
        #expect(!r.events.contains("submitted-22"))
        #expect(r.events.contains("lost-22-2-target_observation_expired"))
        #expect(r.events.contains("lost-23-2-target_observation_expired"))
        #expect(r.events.filter { $0 == "reset-isolated" }.count == 1)
        _ = r.start(3)
        #expect(!r.events.contains("3+"))
        r.reset?(); r.reset = nil
        #expect(r.events.last == "3+")
    }

    @Test func timeoutWithFnAlreadyDownReleasesItOnceAndNeverDeliversUnconfirmedAudio() {
        let r = Rig()
        r.verifiedA()
        _ = r.start(2); r.audio(2); r.stop(2)
        r.presented(1); r.observe(.idle, .unique(47)); r.observe(.idle, .absent)
        let stale = r.state.epoch
        r.apply(r.state.invalidate("target_transition_timeout"))
        r.observe(.active, .unique(66), epoch: stale)
        #expect(r.events.suffix(3) == ["2+", "drop-2-2-target_transition_timeout", "2-"])
        #expect(r.reset == nil)
    }

    @Test func submittedGuardedAudioUsesItsOwnResetFenceBeforeAnIndependentNewKey() {
        let r = Rig()
        r.verifiedA()
        _ = r.start(2); r.audio(2); r.stop(2)
        r.presented(1); r.observe(.idle, .unique(47)); r.observe(.idle, .absent)
        r.observe(.active, .unique(58))
        r.observe(.idle, .notQueried)
        #expect(r.events.suffix(3) == ["audio-2-2", "2-", "reset-isolated"])
        #expect(r.start(3) == nil)
        #expect(r.events.last == "reset-isolated")
        var disconnect: (() -> Void)?
        r.session.waitForOutputReset { disconnect = $0 }
        disconnect?()
        #expect(!r.events.contains("3+"))
        r.reset?(); r.reset = nil
        r.presented(2)
        #expect(r.events.filter { $0 == "2-" }.count == 1)
        #expect(r.events.last == "3+")
    }
}
