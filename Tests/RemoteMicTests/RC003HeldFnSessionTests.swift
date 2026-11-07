import Foundation
import Testing
@testable import RemoteMic

struct RC003HeldFnSessionTests {
    final class Fixture {
        var events: [String] = []
        var pending: [Int: Int] = [:]
        var interrupted: Set<Int> = []
        var callbacks: [() -> Void] = []
        var time: TimeInterval = 0
        lazy var session = RC003HeldFnSession(
            playback: { generation in
                .init(pendingSamples: self.pending[generation, default: 0], interrupted: self.interrupted.contains(generation))
            },
            now: { self.time },
            schedule: { _, callback in self.callbacks.append(callback) },
            onAbort: { self.events.append($0) }
        )
        func begin(_ label: String) -> Bool {
            session.start { pressed in
                self.events.append(label + (pressed ? "-down" : "-up"))
                return true
            }
        }
        func audio(_ generation: Int, _ value: Int16) {
            session.deliver([value], enqueue: { samples in
                self.events.append("audio-\(generation)-\(samples[0])")
                self.pending[generation, default: 0] += samples.count
                return true
            }, discard: { _ in self.events.append("discard-\(generation)") })
        }
        func tick(_ milliseconds: Int) {
            time += Double(milliseconds) / 1_000
            let current = callbacks
            callbacks.removeAll()
            current.forEach { $0() }
        }
    }

    @Test func holdsFnThroughTheStoppedStreamsLastPlaybackCompletion() {
        let f = Fixture()
        #expect(f.begin("a"))
        f.audio(17, 11)
        f.session.stop(deliveryGeneration: 17)
        f.tick(421)
        #expect(f.events == ["a-down", "audio-17-11"])
        f.pending[17] = 0
        f.pending[18] = 9
        f.tick(62)
        #expect(f.events == ["a-down", "audio-17-11", "a-up"])
        #expect(f.pending[18] == 9)
    }

    @Test func immediateReleaseWithoutPendingAudioAndNoTimerForIdleSessions() {
        let f = Fixture()
        #expect(f.begin("a"))
        #expect(f.events == ["a-down"])
        f.session.stop(deliveryGeneration: 8)
        #expect(f.events == ["a-down", "a-up"])
        #expect(f.callbacks.isEmpty)
    }

    @Test func rapidRepressBuffersItsOwnAudioUntilPreviousKeyUp() {
        let f = Fixture()
        #expect(f.begin("a"))
        f.audio(1, 5)
        f.session.stop(deliveryGeneration: 1)
        #expect(f.begin("b"))
        f.audio(2, 7)
        f.session.stop(deliveryGeneration: 2)
        #expect(f.events == ["a-down", "audio-1-5"])
        f.pending[1] = 0
        f.tick(70)
        #expect(f.events == ["a-down", "audio-1-5", "a-up", "b-down", "audio-2-7"])
        f.pending[2] = 0
        f.tick(125)
        #expect(f.events.last == "b-up")
    }

    @Test func interruptCancelsQueuedAudioAndStaleCompletionCannotReleaseNewFn() {
        let f = Fixture()
        #expect(f.begin("a"))
        f.audio(1, 9)
        f.session.stop(deliveryGeneration: 1)
        #expect(f.begin("b"))
        f.audio(2, 7)
        f.session.cancel()
        #expect(f.events == ["a-down", "audio-1-9", "a-up", "discard-2"])
        #expect(f.begin("c"))
        f.tick(1_000)
        #expect(f.events.last == "c-down")
        f.session.stop(deliveryGeneration: 3)
        #expect(f.events.last == "c-up")
    }

    @Test func enqueueFailureDuringRepressCannotReportNormalDrain() {
        let f = Fixture()
        #expect(f.begin("a"))
        f.audio(1, 1)
        f.session.stop(deliveryGeneration: 1)
        #expect(f.begin("b"))
        f.session.deliver([8], enqueue: { _ in false }, discard: { _ in })
        f.audio(2, 6)
        f.session.stop(deliveryGeneration: 2)
        f.pending[1] = 0
        f.tick(3)
        #expect(f.events == ["a-down", "audio-1-1", "a-up", "b-down", "discard-2", "b-up", "audio_enqueue_failed"])
        #expect(!f.session.isBusy)
    }

    @Test func aLongQueueThatKeepsPlayingDoesNotLoseItsTailAtADeadline() {
        let f = Fixture()
        #expect(f.begin("a"))
        f.pending[1] = 48_000
        f.session.stop(deliveryGeneration: 1)
        for _ in 0..<6 {
            f.pending[1, default: 0] -= 6_000
            f.tick(500)
        }
        #expect(f.events == ["a-down"])
        f.pending[1] = 0
        f.tick(200)
        #expect(f.events == ["a-down", "a-up"])
    }

    @Test func aRapidPressAfterAStallWaitsForOutputRevocationAndKeepsItsFirstSamples() {
        let f = Fixture()
        var finishReset: (() -> Void)?
        #expect(f.begin("old"))
        f.audio(1, 9)
        f.session.stop(deliveryGeneration: 1)
        f.tick(2_100)
        f.session.waitForOutputReset { finishReset = $0 }
        #expect(f.begin("new"))
        f.audio(2, 4)
        f.session.stop(deliveryGeneration: 2)
        #expect(!f.events.contains("new-down"))
        f.pending[1] = 0
        finishReset?()
        #expect(f.events.suffix(2) == ["new-down", "audio-2-4"])
        f.pending[2] = 0
        f.tick(8)
        #expect(f.events.last == "new-up")
        finishReset?()
        #expect(f.events.filter { $0 == "new-down" }.count == 1)
    }

    @Test func stalledOrInterruptedPlaybackReleasesOnceAndLeavesOtherGenerationsAlone() {
        for interrupted in [false, true] {
            let f = Fixture()
            #expect(f.begin("a"))
            f.audio(1, 4)
            f.pending[2] = 17
            f.session.stop(deliveryGeneration: 1)
            if interrupted { f.interrupted.insert(1) }
            f.tick(2_100)
            #expect(!f.session.isBusy)
            #expect(f.events.filter { $0 == "a-up" }.count == 1)
            #expect(f.events.last == (interrupted ? "playback_interrupted" : "playback_stalled"))
            #expect(f.pending[2] == 17)
        }
    }
}
