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
        let discard: (Int, String) -> Void
    }

    private final class Press {
        let setKey: (Bool) -> Bool
        var isHeld = false
        var stoppedGeneration: Int?
        var buffered: [BufferedAudio] = []
        var bufferedSampleCount = 0
        var deadline: TimeInterval?
        var lastPendingSamples: Int?
        var largestBatchSamples = 0

        init(setKey: @escaping (Bool) -> Bool) {
            self.setKey = setKey
        }

        func enqueue(_ samples: [Int16], using output: ([Int16]) -> Bool) -> Bool {
            guard output(samples) else { return false }
            largestBatchSamples = max(largestBatchSamples, samples.count)
            return true
        }
    }

    private let playback: (Int) -> Playback
    private let now: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let onAbort: (String) -> Void
    private let onIdle: () -> Void
    private var presses: [Press] = []
    // One minute of 16 kHz mono plus margin (1.95 MiB of Int16 payload).
    // Bound the retained batch arrays and closures independently of packet size.
    static let maximumBufferedSamples = 64 * 16_000
    static let maximumBufferedBatches = 8_192
    private(set) var rejectedPressReason: String?

    private var outputReset: UInt64?
    private var nextReset: UInt64 = 0

    var isBusy: Bool { !presses.isEmpty || outputReset != nil || rejectedPressReason != nil }

    /// Capture a new physical press immediately, but never open a new target
    /// window while an invalidated player can still render the old generation.
    func waitForOutputReset(_ reset: (@escaping () -> Void) -> Void) {
        nextReset &+= 1
        let token = nextReset
        outputReset = token
        reset { [weak self] in
            guard let self, self.outputReset == token else { return }
            self.outputReset = nil
            self.startNextPressIfReady()
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
        guard rejectedPressReason == nil,
              presses.last == nil || presses.last?.stoppedGeneration != nil else { return false }
        // A stalled output cannot retain unlimited tiny button presses.
        guard presses.count < 8 else {
            rejectedPressReason = "press_queue_full"
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
        deliver(samples, enqueue: enqueue, discardWithReason: { count, _ in discard(count) })
    }

    @discardableResult
    func deliver(
        _ samples: [Int16],
        enqueue: @escaping ([Int16]) -> Bool,
        discardWithReason discard: @escaping (Int, String) -> Void
    ) -> Bool {
        guard rejectedPressReason == nil, let press = presses.last, press.stoppedGeneration == nil else {
            discard(samples.count, rejectedPressReason ?? "interrupted")
            return false
        }
        if press.isHeld {
            let accepted = press.enqueue(samples, using: enqueue)
            if !accepted { abort("audio_enqueue_failed") }
            return accepted
        }
        let availableSamples = Self.maximumBufferedSamples - presses.reduce(0) { $0 + $1.bufferedSampleCount }
        let batchCount = presses.reduce(0) { $0 + $1.buffered.count }
        guard samples.count <= availableSamples, batchCount < Self.maximumBufferedBatches else {
            // It is the newest physical press and has never opened a target window.
            // Consume its remaining input through STOP while earlier presses drain.
            rejectedPressReason = "preroll_full"
            presses.removeLast()
            press.buffered.forEach { $0.discard($0.samples.count, "preroll_full") }
            discard(samples.count, "preroll_full")
            return false
        }
        press.bufferedSampleCount += samples.count
        press.buffered.append(.init(samples: samples, enqueue: enqueue, discard: discard))
        return true
    }

    func stop(deliveryGeneration: Int) {
        if finishRejectedPress() { return }
        guard let press = presses.last, press.stoppedGeneration == nil else { return }
        press.stoppedGeneration = deliveryGeneration
        if presses.first === press, press.isHeld { waitForPlayback(press) }
    }

    /// A rejected physical START does not own an audio delivery generation.
    @discardableResult
    func finishRejectedPress() -> Bool {
        guard rejectedPressReason != nil else { return false }
        rejectedPressReason = nil
        if !isBusy { onIdle() }
        return true
    }

    func cancel(notifyIdle: Bool = true, reason: String = "interrupted") {
        guard !presses.isEmpty || rejectedPressReason != nil else { return }
        rejectedPressReason = nil
        let pending = presses
        presses.removeAll()
        for press in pending {
            if press.isHeld {
                press.isHeld = false
                _ = press.setKey(false)
            }
            press.buffered.forEach { $0.discard($0.samples.count, reason) }
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
        press.bufferedSampleCount = 0
        for (index, audio) in queued.enumerated() {
            guard press.enqueue(audio.samples, using: audio.enqueue) else {
                for remaining in queued.suffix(from: index + 1) {
                    remaining.discard(remaining.samples.count, "audio_enqueue_failed")
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
            startNextPressIfReady()
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
            // dataPlayedBack acknowledges a whole ticket. Configuration can
            // merge native frames into one long ticket. A large backlog of
            // tiny tickets still has the original two-second stall limit.
            let maxFrameSamples = 2 * Int(UInt16.max) // ADPCM samples per negotiated frame
            let ticketSeconds = Double(min(press.largestBatchSamples, maxFrameSamples)) / 16_000
            let maxWait = max(2, ticketSeconds + 0.75)
            press.deadline = uptime + min(maxWait, queuedSeconds + 0.75)
            press.lastPendingSamples = output.pendingSamples
        }
        let delay = output.pendingSamples == 0 ? output.presentationDelay ?? 0 : 0
        let untilWatchdog = max(0, (press.deadline ?? uptime) - uptime)
        schedule(delay > 0 ? min(delay, untilWatchdog) : 0.008) { [weak self, weak press] in
            guard let press else { return }
            self?.waitForPlayback(press)
        }
    }

    private func startNextPressIfReady() {
        if let next = presses.first {
            _ = pressKey(next)
        } else if !isBusy {
            onIdle()
        }
    }

    private func abort(_ reason: String) {
        cancel(notifyIdle: false, reason: reason)
        onAbort(reason)
    }
}
