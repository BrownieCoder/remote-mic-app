import AppKit
import Carbon

/// Observes the explicitly selected input method while one verified remote is armed.
/// Only the existing managed session can send the key or route a buffer.
final class DoubaoAdjacentDictation {
    typealias State = DoubaoRearmState
    struct Binding: Equatable {
        let remote: UInt64
        let output: UInt32
    }
    /// A positive reader sample and selected input source have independent
    /// expiry times. Neither clock can renew the other or authorize a new key.
    struct ReaderPermit {
        static let maximumAge: UInt64 = 200_000_000
        let token: UInt64
        let sourceCheckedAt: UInt64
        let expires: UInt64

        init(token: UInt64, sampleBeganAt: UInt64, sourceCheckedAt: UInt64) {
            self.token = token
            self.sourceCheckedAt = sourceCheckedAt
            expires = min(sampleBeganAt, sourceCheckedAt) + Self.maximumAge
        }
        func allows(_ press: UInt64, at now: UInt64) -> Bool {
            press == token && now < expires
        }
    }
    private struct Receiver {
        let scope: State.Scope
        let target: NSRunningApplication
        let focus: DoubaoRearmMetadata.Focus
        let window: UInt32
        let notifications: DoubaoFocusNotifications
    }

    private let state = State()
    private let session: RC003HeldFnSession
    private let binding: () -> Binding?
    private let metadata = DispatchQueue(label: "sayall.doubao.capture-metadata", qos: .userInitiated)
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var receiver: Receiver?
    private var revision: UInt64 = 0
    private var enabled = false
    private var prepareQueued = false
    private var preparing = false
    private var reprepare = false
    private var sampling = false
    private var scheduledTick: DispatchWorkItem?
    private var deadline: DispatchWorkItem?
    private var permit: ReaderPermit?
    private var permitExpiry: DispatchWorkItem?
    private var primeUntil: UInt64 = 0
    private var keyHeld = false
    private var unobservedKeyHeld = false
    private var lastStatus: String?

    init(session: RC003HeldFnSession, binding: @escaping () -> Binding?) {
        self.session = session
        self.binding = binding
        state.onGuardedWindow = { token, observation in
            AppLogger.shared.write("RC003 HELD FN target_rearm=guarded_window press=\(token) \(observation.rawValue)")
        }
    }
    func start() {
        guard !enabled else { return }
        enabled = true
        session.guardedAudioIsFresh = { [weak self] token in self?.permit?.allows(token, at: Self.now) == true }
        session.onGuardedRejection = { [weak self] token, reason in
            guard let self, self.state.contains(token) else { return }
            if self.permit?.token == token { self.clearPermit() }
            self.perform(self.state.rejectedByQueue(token, reason: reason))
            if self.state.headID == nil { self.prime() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let observer = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] event in
                if name == NSWorkspace.didLaunchApplicationNotification || name == NSWorkspace.didTerminateApplicationNotification {
                    guard let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          app.bundleIdentifier == DoubaoRearmMetadata.ime else { return }
                }
                self?.environmentChanged("target_environment_changed")
            }
            observers.append((workspace, observer))
        }
        let distributed = DistributedNotificationCenter.default()
        let name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        let observer = distributed.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            self?.environmentChanged("input_source_changed")
        }
        observers.append((distributed, observer))
        environmentChanged("armed")
    }
    func stop(sessionIsCancelling: Bool = false) {
        enabled = false
        clearPermit()
        session.guardedAudioIsFresh = nil
        session.onGuardedRejection = nil
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        if sessionIsCancelling {
            // The owner immediately cancels the whole queue, releases its key
            // and retires the managed track. Do not request a second reset.
            revision &+= 1
            receiver?.notifications.detachOnMain()
            receiver = nil
            deadline?.cancel()
            scheduledTick?.cancel()
            _ = state.invalidate("route_disabled")
        } else {
            environmentChanged("route_disabled")
        }
    }
    func environmentChanged(_ reason: String) {
        revision &+= 1
        receiver?.notifications.detachOnMain()
        receiver = nil
        cancel(reason)
        // TIS is main-thread-only in UI apps. Read it after an environment
        // notification, never in a physical START, key setter, PCM or HAL callback.
        guard enabled, !prepareQueued else { return }
        prepareQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.prepareQueued = false
            self.prepare()
        }
    }
    private func prepare() {
        if preparing { reprepare = true; return }
        guard enabled, #available(macOS 14.2, *), let bound = binding(),
              OnboardingInputSourceSwitcher.isSelected(.doubao),
              let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier > 0,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let targets = NSRunningApplication.runningApplications(withBundleIdentifier: DoubaoRearmMetadata.ime)
        guard targets.count == 1, let target = targets.first, let launch = target.launchDate,
              target.processIdentifier > 0, target.processIdentifier != front.processIdentifier else { return }
        let version = revision
        let scope = State.Scope(remoteBinding: bound.remote, destinationPID: front.processIdentifier,
                                focusRevision: version, imePID: target.processIdentifier,
                                imeIncarnation: launch.timeIntervalSinceReferenceDate.bitPattern, outputDevice: bound.output)
        preparing = true
        metadata.async { [weak self] in
            let resolved: Receiver? = {
                guard DoubaoRearmMetadata.supportedUniqueFixture(bound.output),
                      let notifications = DoubaoFocusNotifications.prepareOffMain(receiver: scope.destinationPID),
                      let focus = DoubaoRearmMetadata.Focus.capture(scope.destinationPID),
                      let window = DoubaoRearmMetadata.windows(destination: scope.destinationPID, ime: scope.imePID),
                      focus.isCurrent() else { return nil }
                return Receiver(scope: scope, target: target, focus: focus, window: window.destination, notifications: notifications)
            }()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.preparing = false
                if self.reprepare { self.reprepare = false; self.prepare(); return }
                guard self.enabled, self.revision == version, self.binding() == bound else { return }
                guard let resolved else { self.status("unavailable"); return }
                self.receiver = resolved
                resolved.notifications.attachOnMain { [weak self] in self?.environmentChanged("receiver_focus_changed") }
                self.prime()
            }
        }
    }

    func physicalStart() -> State.Admission? {
        guard let r = receiver else { return nil }
        guard current(r) else { environmentChanged("output_binding_changed"); return nil }
        guard !unobservedKeyHeld else { return nil }
        return state.physicalStart()
    }
    func unaccepted(_ admission: State.Admission?) {
        if let admission { state.unaccepted(admission.id) }
    }
    func key(_ admission: State.Admission?, down: Bool) {
        guard enabled else { return }
        keyHeld = down
        if !down, let id = admission?.id, permit?.token == id { clearPermit() }
        if let admission, state.contains(admission.id) {
            state.key(admission.id, down: down, at: Self.now)
            resample()
            return
        }
        unobservedKeyHeld = down
        if down {
            if state.headID == nil { cancel("ordinary_press") }
        } else if state.headID == nil { prime() }
    }
    private func current(_ r: Receiver) -> Bool {
        enabled && revision == r.scope.focusRevision &&
            binding() == Binding(remote: r.scope.remoteBinding, output: r.scope.outputDevice)
    }
    private static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
    private func prime() {
        guard receiver != nil, !unobservedKeyHeld, state.headID == nil else { return }
        // This is a bounded search for an idle baseline. Time grants nothing.
        primeUntil = Self.now + 3_000_000_000
        schedule(0)
    }
    private func resample() {
        let epoch = state.epoch
        deadline?.cancel()
        deadline = nil
        if state.deadlinePhase != nil || state.seekingFirstWindow {
            let limit = state.awaitNewReader || state.seekingFirstWindow ? 3.0 : 6.0
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.state.epoch == epoch,
                      self.state.deadlinePhase != nil || self.state.seekingFirstWindow else { return }
                self.cancel("target_transition_timeout")
            }
            deadline = item
            DispatchQueue.main.asyncAfter(deadline: .now() + limit, execute: item)
        }
        schedule(0)
    }
    private func schedule(_ seconds: TimeInterval) {
        scheduledTick?.cancel()
        scheduledTick = nil
        guard receiver != nil, state.demand != .none, !unobservedKeyHeld,
              state.headID != nil || Self.now < primeUntil else { return }
        let item = DispatchWorkItem { [weak self] in self?.sample() }
        scheduledTick = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }
    private func sample() {
        guard !sampling, let r = receiver, !unobservedKeyHeld else { return }
        guard current(r) else { environmentChanged("output_binding_changed"); return }
        let demand = state.demand, epoch = state.epoch
        guard demand != .none, state.headID != nil || Self.now < primeUntil else { return }
        sampling = true
        metadata.async { [weak self] in
            let begin = Self.now
            let before = DoubaoRearmMetadata.reader(r.scope)
            let panel: State.Panel = demand == .window ? DoubaoRearmMetadata.panel(r.scope, destinationWitness: r.window) : .notQueried
            let after = DoubaoRearmMetadata.reader(r.scope)
            let valid = !r.target.isTerminated && r.target.launchDate?.timeIntervalSinceReferenceDate.bitPattern == r.scope.imeIncarnation &&
                r.focus.isCurrent()
            let observation = State.Sample(begin: begin, end: Self.now, before: before, panel: panel, after: after)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sampling = false
                guard self.receiver?.scope == r.scope, self.state.epoch == epoch else {
                    self.schedule(0)
                    return
                }
                guard self.current(r) else { self.environmentChanged("output_binding_changed"); return }
                guard valid else { self.environmentChanged("receiver_focus_changed"); return }
                // A late OS reply cannot authorize an edge or a buffer. Timeout
                // independently releases a protected press even if a query hangs.
                if Self.now - begin < ReaderPermit.maximumAge {
                    let seekingWindow = self.state.seekingFirstWindow
                    let action = self.state.observe(observation, epoch: epoch, canOpen: self.session.canOpenGuarded)
                    if action == nil, observation.capturing, let token = self.state.confirmedReader {
                        _ = self.authorizeAudio(token, beganAt: begin, initial: false)
                    } else {
                        self.perform(action, sampleBeganAt: begin)
                    }
                    if seekingWindow, self.state.hasWitnessedCapture {
                        let observed = self.state.sawUnattributedOccupancy ? "occupied_while_held" : "capture_witnessed"
                        AppLogger.shared.write("RC003 HELD FN target_rearm=\(observed)")
                    }
                    if self.keyHeld && self.state.headID == nil {
                        self.unobservedKeyHeld = true
                        self.primeUntil = 0
                    }
                    if self.state.hasBaseline { self.status("ready") }
                }
                let next = self.state.epoch == epoch ? (self.state.demand == .reader ? 0.10 : 0.025) : 0
                self.schedule(next)
            }
        }
    }
    private func clearPermit() {
        permitExpiry?.cancel()
        permitExpiry = nil
        permit = nil
    }

    private func authorizeAudio(_ token: UInt64, beganAt: UInt64, initial: Bool) -> Bool {
        let nowBeforeCheck = Self.now
        if !initial, permit?.allows(token, at: nowBeforeCheck) != true {
            cancel("target_observation_expired")
            return false
        }
        let sourceCheckedAt: UInt64
        // During faster panel discovery, reuse a recent source check. Once the
        // window is known, check on each slower 100 ms reader observation.
        if !initial, state.demand == .window, let prior = permit?.sourceCheckedAt,
           nowBeforeCheck - prior < ReaderPermit.maximumAge / 2 {
            sourceCheckedAt = prior
        } else {
            sourceCheckedAt = nowBeforeCheck
            guard verifyTargetForGrant(token) else { return false }
        }
        let receipt = ReaderPermit(token: token, sampleBeganAt: beganAt, sourceCheckedAt: sourceCheckedAt)
        let now = Self.now
        guard receipt.allows(token, at: now), initial || permit?.allows(token, at: now) == true else {
            cancel("target_observation_expired")
            return false
        }
        permit = receipt
        permitExpiry?.cancel()
        let job = DispatchWorkItem { [weak self] in
            guard let self, self.permit?.token == token, self.permit?.allows(token, at: Self.now) == false else { return }
            self.cancel("target_observation_expired")
        }
        permitExpiry = job
        DispatchQueue.main.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: receipt.expires), execute: job)
        return true
    }

    private func cancel(_ reason: String) {
        clearPermit()
        deadline?.cancel()
        scheduledTick?.cancel()
        primeUntil = 0
        perform(state.invalidate(reason))
        unobservedKeyHeld = keyHeld
        if lastStatus == "ready" { status("unavailable") }
    }
    // TIS is main-thread-only. Recheck at each guarded privilege boundary,
    // since a change notification can arrive after the actual input switch.
    // The immediately preceding background sample verified the AX references.
    private func verifyTargetForGrant(_ token: UInt64) -> Bool {
        guard let r = receiver, current(r), state.headID == token, !r.target.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == r.scope.destinationPID,
              OnboardingInputSourceSwitcher.isSelected(.doubao) else {
            environmentChanged("target_authorization_changed")
            return false
        }
        return true
    }
    private func perform(_ action: State.Action?, sampleBeganAt: UInt64? = nil) {
        switch action {
        case .down(let token):
            guard let sampleBeganAt, verifyTargetForGrant(token) else { return }
            guard Self.now - sampleBeganAt < ReaderPermit.maximumAge else { cancel("target_observation_expired"); return }
            if session.openGuarded(token) {
                AppLogger.shared.write("RC003 HELD FN target_rearm=awaiting_new_reader press=\(token)")
            } else {
                cancel("target_down_unavailable")
            }
        case .audio(let token):
            guard let sampleBeganAt, authorizeAudio(token, beganAt: sampleBeganAt, initial: true) else { return }
            AppLogger.shared.write("RC003 HELD FN target_rearm=new_reader_confirmed press=\(token)")
            session.confirmGuardedReader(token)
        case .cancel(let ids, let reason):
            if let token = permit?.token, ids.contains(token) { clearPermit() }
            // Remove the newest first so a withdrawn predecessor cannot start a
            // descendant mid-cancellation. Counters/discards belong to each press.
            AppLogger.shared.write("RC003 HELD FN target_rearm=discard presses=\(ids.count) reason=\(reason)")
            for token in ids.reversed() { session.rejectGuarded(token, reason: reason) }
        case nil:
            break
        }
    }
    private func status(_ value: String) {
        guard lastStatus != value else { return }
        lastStatus = value
        AppLogger.shared.write("RC003 HELD FN target_rearm=\(value)")
    }
}
