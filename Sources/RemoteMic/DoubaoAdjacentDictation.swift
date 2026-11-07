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
    private var primeUntil: UInt64 = 0
    private var keyHeld = false
    private var unobservedKeyHeld = false
    private var lastStatus: String?

    init(session: RC003HeldFnSession, binding: @escaping () -> Binding?) {
        self.session = session
        self.binding = binding
    }
    func start() {
        guard !enabled else { return }
        enabled = true
        session.onGuardedRejection = { [weak self] token, reason in
            guard let self, self.state.contains(token) else { return }
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
                if Self.now - begin <= 200_000_000 {
                    let seekingWindow = self.state.seekingFirstWindow
                    self.perform(self.state.observe(observation, epoch: epoch, canOpen: self.session.canOpenGuarded))
                    if seekingWindow, self.state.hasWitnessedCapture {
                        AppLogger.shared.write("RC003 HELD FN target_rearm=capture_witnessed")
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
    private func cancel(_ reason: String) {
        deadline?.cancel()
        scheduledTick?.cancel()
        primeUntil = 0
        perform(state.invalidate(reason))
        unobservedKeyHeld = keyHeld
        if lastStatus == "ready" { status("unavailable") }
    }
    private func perform(_ action: State.Action?) {
        switch action {
        case .down(let token):
            if session.openGuarded(token) {
                AppLogger.shared.write("RC003 HELD FN target_rearm=awaiting_new_reader press=\(token)")
            } else {
                cancel("target_down_unavailable")
            }
        case .audio(let token):
            AppLogger.shared.write("RC003 HELD FN target_rearm=new_reader_confirmed press=\(token)")
            session.confirmGuardedReader(token)
        case .cancel(let ids, let reason):
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
