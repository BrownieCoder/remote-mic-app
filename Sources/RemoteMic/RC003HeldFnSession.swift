import Foundation

/// Main-queue state for a single neutralized RC003 voice key. Only completed playback
/// from the matching audio generation permits a normal Fn release.
final class RC003HeldFnSession {
    struct Playback {
        let pendingSamples: Int
        let interrupted: Bool
        // nil once presented, zero while awaiting a render observation, or
        // the remaining wall time to the last device block already submitted.
        var presentationDelay: TimeInterval? = nil
    }

    private struct BufferedAudio {
        let samples: [Int16]
        let enqueue: ([Int16]) -> Bool
        let discard: (Int) -> Void
    }

    private final class Press {
        let setKey: (Bool) -> Bool
        var isHeld = false
        var stoppedGeneration: Int?
        var buffered: [BufferedAudio] = []
        var deadline: TimeInterval?
        var lastPendingSamples: Int?

        init(setKey: @escaping (Bool) -> Bool) {
            self.setKey = setKey
        }
    }

    private let playback: (Int) -> Playback
    private let now: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let onAbort: (String) -> Void
    private let onIdle: () -> Void
    private var presses: [Press] = []
    private var bufferedSamples = 0

    private var outputReset: UInt64?
    private var nextReset: UInt64 = 0

    var isBusy: Bool { !presses.isEmpty || outputReset != nil }

    /// Capture a new physical press immediately, but never open a new target
    /// window while an invalidated player can still render the old generation.
    func waitForOutputReset(_ reset: (@escaping () -> Void) -> Void) {
        nextReset &+= 1
        let token = nextReset
        outputReset = token
        reset { [weak self] in
            guard let self, self.outputReset == token else { return }
            self.outputReset = nil
            if let next = self.presses.first { _ = self.pressKey(next) } else { self.onIdle() }
        }
    }

    init(
        playback: @escaping (Int) -> Playback,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        },
        onAbort: @escaping (String) -> Void,
        onIdle: @escaping () -> Void = {}
    ) {
        self.playback = playback
        self.now = now
        self.schedule = schedule
        self.onAbort = onAbort
        self.onIdle = onIdle
    }

    func start(setKey: @escaping (Bool) -> Bool) -> Bool {
        guard presses.last == nil || presses.last?.stoppedGeneration != nil else { return false }
        // A stalled output cannot retain unlimited tiny button presses.
        guard presses.count < 8 else {
            abort("press_queue_full")
            return false
        }
        let press = Press(setKey: setKey)
        presses.append(press)
        guard presses.first === press, outputReset == nil else { return true }
        return pressKey(press)
    }

    @discardableResult
    func deliver(
        _ samples: [Int16],
        enqueue: @escaping ([Int16]) -> Bool,
        discard: @escaping (Int) -> Void
    ) -> Bool {
        guard let press = presses.last, press.stoppedGeneration == nil else {
            discard(samples.count)
            return false
        }
        if press.isHeld {
            let accepted = enqueue(samples)
            if !accepted { abort("audio_enqueue_failed") }
            return accepted
        }
        // 2 seconds of mono, 16 kHz pre-roll across all waiting presses.
        guard bufferedSamples + samples.count <= 32_000 else {
            discard(samples.count)
            abort("preroll_full")
            return false
        }
        bufferedSamples += samples.count
        press.buffered.append(.init(samples: samples, enqueue: enqueue, discard: discard))
        return true
    }

    func stop(deliveryGeneration: Int) {
        guard let press = presses.last, press.stoppedGeneration == nil else { return }
        press.stoppedGeneration = deliveryGeneration
        if presses.first === press, press.isHeld { waitForPlayback(press) }
    }

    func cancel(notifyIdle: Bool = true) {
        guard !presses.isEmpty else { return }
        let pending = presses
        presses.removeAll()
        bufferedSamples = 0
        for press in pending {
            if press.isHeld {
                press.isHeld = false
                _ = press.setKey(false)
            }
            press.buffered.forEach { $0.discard($0.samples.count) }
        }
        if notifyIdle, outputReset == nil { onIdle() }
    }

    private func pressKey(_ press: Press) -> Bool {
        guard press.setKey(true) else {
            abort("fn_down_failed")
            return false
        }
        press.isHeld = true
        let queued = press.buffered
        press.buffered.removeAll()
        for (index, audio) in queued.enumerated() {
            bufferedSamples -= audio.samples.count
            guard audio.enqueue(audio.samples) else {
                for remaining in queued.suffix(from: index + 1) {
                    remaining.discard(remaining.samples.count)
                }
                abort("audio_enqueue_failed")
                return false
            }
        }
        if press.stoppedGeneration != nil { waitForPlayback(press) }
        return true
    }

    private func waitForPlayback(_ press: Press) {
        guard presses.first === press, let generation = press.stoppedGeneration else { return }
        let output = playback(generation)
        if output.interrupted {
            abort("playback_interrupted")
            return
        }
        guard output.pendingSamples > 0 || output.presentationDelay != nil else {
            guard press.setKey(false) else {
                abort("fn_up_failed")
                return
            }
            press.isHeld = false
            presses.removeFirst()
            if let next = presses.first { _ = pressKey(next) } else { onIdle() }
            return
        }
        let uptime = now()
        if let deadline = press.deadline, let previous = press.lastPendingSamples,
           output.pendingSamples >= previous {
            guard uptime < deadline else {
                abort("playback_stalled")
                return
            }
        } else {
            // Only a watchdog. Normal completion follows the device timeline.
            let queuedSeconds = Double(output.pendingSamples) / 16_000
            press.deadline = uptime + min(2, queuedSeconds + 0.75)
            press.lastPendingSamples = output.pendingSamples
        }
        let delay = output.pendingSamples == 0 ? output.presentationDelay ?? 0 : 0
        let untilWatchdog = max(0, (press.deadline ?? uptime) - uptime)
        schedule(delay > 0 ? min(delay, untilWatchdog) : 0.008) { [weak self, weak press] in
            guard let press else { return }
            self?.waitForPlayback(press)
        }
    }

    private func abort(_ reason: String) {
        cancel(notifyIdle: false)
        onAbort(reason)
    }
}
