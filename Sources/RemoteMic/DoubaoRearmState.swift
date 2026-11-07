import Foundation

/// A physical press is protected only if the previous real Fn owns a verified
/// Doubao capture. PCM stays in RC003HeldFnSession's existing bounded FIFO.
final class DoubaoRearmState {
    struct Scope: Equatable {
        let remoteBinding: UInt64
        let destinationPID: Int32
        let focusRevision: UInt64
        let imePID: Int32
        let imeIncarnation: UInt64
        let outputDevice: UInt32
    }
    enum Reader { case active, idle, unknown }
    enum Panel: Equatable { case absent, unique(UInt32), ambiguous, notQueried }
    enum Demand { case none, window, reader }
    struct Sample {
        let begin: UInt64
        let end: UInt64
        let before: Reader
        let panel: Panel
        let after: Reader

        var clear: Bool { before == .idle && after == .idle && panel == .absent }
        var capturing: Bool { before == .active && after == .active }
    }
    struct Admission: Equatable {
        let id: UInt64
        let gated: Bool
    }
    enum Action: Equatable {
        case down(UInt64)
        case audio(UInt64)
        case cancel([UInt64], String)
    }
    /// Observations relative to this guarded key's actual edges. They describe
    /// what the sampler saw, including an unanchored panel after release.
    enum WindowObservation: String {
        case beforeReader = "first_panel=before_confirmed_reader"
        case withReader = "first_panel=with_active_reader_sample"
        case afterReader = "first_panel=after_reader_before_up"
        case afterUp = "first_panel=after_up"
        case visibleBeforeUp = "window_at_up=previously_observed"
        case unseenAtUp = "window_at_up=unobserved"
    }
    var onGuardedWindow: ((UInt64, WindowObservation) -> Void)?
    private final class Press {
        let admission: Admission
        var permittedToPress: Bool
        var initialObservationComplete: Bool
        var audioConfirmed: Bool
        var down: UInt64?
        var up: UInt64?
        var window: UInt32?
        var occupiedAtFirstObservation = false
        var loggedFirstWindow = false
        var sawAbsent = false
        var readerClosedAfterUp = false

        init(_ admission: Admission) {
            self.admission = admission
            permittedToPress = !admission.gated
            initialObservationComplete = admission.gated // Its predecessor was freshly confirmed clear.
            audioConfirmed = !admission.gated
        }
    }
    private var presses: [Press] = []
    private var nextID: UInt64 = 0
    private var baseline = false
    private var lastSampleEnd: UInt64 = 0
    private(set) var epoch: UInt64 = 0
    var hasBaseline: Bool { baseline }
    func contains(_ token: UInt64) -> Bool { presses.contains { $0.admission.id == token } }
    var sawUnattributedOccupancy: Bool { presses.first?.occupiedAtFirstObservation == true }
    var hasWitnessedCapture: Bool { presses.first?.window != nil }
    var seekingFirstWindow: Bool {
        guard let p = presses.first else { return false }
        return !p.admission.gated && p.down != nil && p.up == nil && p.window == nil
    }
    var headID: UInt64? { presses.first?.admission.id }

    var demand: Demand {
        guard let current = presses.first else { return baseline ? .none : .window }
        guard current.down != nil else { return .none }
        if current.up != nil || current.window == nil { return .window }
        return current.admission.gated ? .reader : .none
    }
    /// Deadlines cancel a pending target transition. A's existing playback
    /// watchdog owns its actual release, however long its valid backlog is.
    var deadlinePhase: UInt64? {
        guard let p = presses.first else { return nil }
        if p.up != nil || (p.admission.gated && p.down != nil && !p.audioConfirmed) { return epoch }
        return nil
    }
    var confirmedReader: UInt64? {
        guard let p = presses.first, p.admission.gated, p.audioConfirmed, p.down != nil, p.up == nil else { return nil }
        return p.admission.id
    }
    var awaitNewReader: Bool {
        guard let p = presses.first else { return false }
        return p.admission.gated && p.down != nil && !p.audioConfirmed
    }
    func physicalStart() -> Admission? {
        if let current = presses.first {
            // A never provided a known capture and window: it did not enroll.
            // A press already accepted behind a proven predecessor remains FIFO.
            if !current.admission.gated && current.window == nil {
                _ = invalidate("unqualified_initial_capture")
                return nil
            }
        } else if !baseline { return nil }
        nextID &+= 1
        let admission = Admission(id: nextID, gated: !presses.isEmpty)
        presses.append(Press(admission))
        if !admission.gated { baseline = false; advance() }
        return admission
    }
    func unaccepted(_ id: UInt64) {
        // The native queue's existing limit and duplicate-START decision prevail.
        if presses.last?.admission.id == id { presses.removeLast() }
    }
    func key(_ id: UInt64, down: Bool, at time: UInt64) {
        guard let current = presses.first, current.admission.id == id else { return }
        if down, current.permittedToPress, current.down == nil { current.down = time; advance() }
        if !down, current.down != nil, current.up == nil {
            current.up = time
            advance()
            if current.admission.gated {
                onGuardedWindow?(id, current.loggedFirstWindow ? .visibleBeforeUp : .unseenAtUp)
            }
        }
    }
    func observe(_ s: Sample, epoch inputEpoch: UInt64, canOpen: (UInt64)->Bool) -> Action? {
        guard epoch == inputEpoch, s.begin < s.end, s.begin >= lastSampleEnd else { return nil }
        lastSampleEnd = s.end
        guard let p = presses.first else { baseline = s.clear; return nil }
        guard let down = p.down, s.begin >= down else { return nil }
        if s.before == .unknown || s.after == .unknown { return invalidate("target_reader_unknown") }
        if s.panel == .ambiguous { return invalidate("target_window_ambiguous") }
        if let up = p.up, s.begin < up { return nil }
        if p.admission.gated, !p.loggedFirstWindow, case .unique(let window) = s.panel, window > 0 {
            p.loggedFirstWindow = true
            let event: WindowObservation
            if p.up != nil { event = .afterUp }
            else if p.audioConfirmed { event = .afterReader }
            else { event = s.capturing ? .withReader : .beforeReader }
            onGuardedWindow?(p.admission.id, event)
        }
        if p.up != nil {
            if p.readerClosedAfterUp && s.before == .active || s.before == .idle && s.after == .active {
                return invalidate("target_reader_reopened")
            }
            if s.before == .idle || s.after == .idle { p.readerClosedAfterUp = true }
            guard p.window != nil else {
                // B's audio has already drained. Observe only until the first
                // clear, ambiguity or deadline. A window first seen after up
                // cannot establish which utterance it belonged to or open C.
                return s.clear ? invalidate("target_window_unconfirmed") : nil
            }
            switch s.panel {
            case .unique(let id):
                guard p.window == id, !p.sawAbsent else { return invalidate("target_window_changed") }
            case .absent:
                // W was positively observed in a running capture while this key
                // was held. A fresh post-up absence establishes that it is gone,
                // even when it disappeared before the first post-up poll.
                p.sawAbsent = true
            default:
                return nil
            }
            guard s.clear else { return nil }
            guard presses.count >= 2 else { presses.removeAll(); baseline = true; advance(); return nil }
            let next = presses[1]
            guard canOpen(next.admission.id) else { return nil }
            presses.removeFirst()
            next.permittedToPress = true
            advance()
            return .down(next.admission.id)
        }
        if !p.initialObservationComplete {
            if s.clear { p.initialObservationComplete = true; return nil }
            if s.capturing, case .unique(let id) = s.panel, id > 0 {
                // This may be an older occupation of the same target. A remains
                // immediate. Its successor must wait for this exact window and
                // reader to clear and independently confirm its own new reader.
                p.occupiedAtFirstObservation = true
                p.window = id
                p.initialObservationComplete = true
            }
            return nil
        }
        if case .unique(let id) = s.panel {
            guard id > 0, p.window == nil || p.window == id else { return invalidate("target_window_changed") }
            if s.capturing { p.window = id }
        }
        if p.admission.gated && !p.audioConfirmed && s.capturing {
            p.audioConfirmed = true
            return .audio(p.admission.id)
        }
        if p.admission.gated, p.audioConfirmed, s.before == .idle || s.after == .idle {
            return invalidate("target_reader_closed")
        }
        return nil
    }
    func rejectedByQueue(_ id: UInt64, reason: String) -> Action? {
        guard let index = presses.firstIndex(where: { $0.admission.id == id }) else { return nil }
        // A newest press exceeding the shared preroll cap cannot revoke older
        // accepted presses. Only successors depend on a missing predecessor.
        let affected = presses.dropFirst(index + 1).map { $0.admission.id }
        presses.removeSubrange(index...)
        if index == 0 { baseline = false; advance() }
        return affected.isEmpty ? nil : .cancel(affected, reason)
    }
    func invalidate(_ reason: String) -> Action? {
        let affected = presses.compactMap { p in
            p.admission.gated && p.up == nil ? p.admission.id : nil
        }
        presses.removeAll(); baseline = false; advance()
        return affected.isEmpty ? nil : .cancel(affected, reason)
    }
    private func advance() { epoch &+= 1; lastSampleEnd = 0 }
}
