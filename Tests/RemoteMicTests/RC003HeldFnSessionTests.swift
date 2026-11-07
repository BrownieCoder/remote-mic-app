import Foundation
import Testing
@testable import RemoteMic

struct RC003HeldFnSessionTests {
    final class Fixture {
        var events: [String] = []
        var pending: [Int: Int] = [:]
        var interrupted: Set<Int> = []
        var presentation: [Int: TimeInterval] = [:]
        var callbacks: [() -> Void] = []
        var delays: [TimeInterval] = []
        var time: TimeInterval = 0
        lazy var session = RC003HeldFnSession(
            playback: { generation in
                .init(pendingSamples: self.pending[generation, default: 0], interrupted: self.interrupted.contains(generation),
                      presentationDelay: self.presentation[generation])
            },
            now: { self.time },
            schedule: { delay, callback in self.delays.append(delay); self.callbacks.append(callback) },
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

    @Test func earlyPlayedBackWaitsForItsSubmittedDeviceBlockBeforeBothKeyEdges() {
        let f = Fixture()
        #expect(f.begin("a"))
        f.audio(1, 9000)
        f.pending[1] = 0
        f.presentation[1] = 0.004813
        f.session.stop(deliveryGeneration: 1)
        #expect(f.begin("b"))
        f.audio(2, -6000)
        #expect(f.events == ["a-down", "audio-1-9000"])
        #expect(f.delays == [0.004813])
        f.presentation[1] = nil
        f.tick(5)
        #expect(f.events == ["a-down", "audio-1-9000", "a-up", "b-down", "audio-2--6000"])
    }

    @Test func presentationUsesThisDeliveriesOccupiedFramesAndAnIdleConverterBlock() {
        // A previously presented block cannot acknowledge a new all-zero buffer.
        #expect(VirtualAudioOutput.presentationDelay(previousEnd: 100, occupiedThrough: 100,
                                                      renderedThrough: 200, now: 210) == 0)
        #expect(VirtualAudioOutput.presentationDelay(previousEnd: 100, occupiedThrough: 350,
                                                      renderedThrough: 350, now: 360) == 0)
        #expect((VirtualAudioOutput.presentationDelay(previousEnd: 100, occupiedThrough: 350,
                                                       renderedThrough: 450, now: 325) ?? 0) > 0)
        #expect(VirtualAudioOutput.presentationDelay(previousEnd: 100, occupiedThrough: 350,
                                                      renderedThrough: 450, now: 360) == nil)
    }

    @Test func anAllZeroBufferWaitsForItsDeviceBlockButAPresentedTailReleasesImmediately() {
        let f = Fixture()
        #expect(f.begin("silent"))
        f.audio(1, 0)
        f.pending[1] = 0
        f.presentation[1] = 0
        f.session.stop(deliveryGeneration: 1)
        #expect(f.events == ["silent-down", "audio-1-0"])
        f.presentation[1] = nil
        f.tick(8)
        #expect(f.events.last == "silent-up")

        #expect(f.begin("complete"))
        f.audio(2, 19)
        f.audio(2, 0)
        f.pending[2] = 0
        f.session.stop(deliveryGeneration: 2)
        #expect(f.events.last == "complete-up")
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

    @Test func progressingThreeSecondTailPreservesTheWholeFollowingPress() {
        let f = Fixture()
        #expect(f.begin("a"))
        var deliveredA = 0
        f.session.deliver([Int16](repeating: 1, count: 48_000), enqueue: {
            deliveredA += $0.count
            f.pending[1] = $0.count
            return true
        }, discard: { _ in Issue.record("A was discarded") })
        f.session.stop(deliveryGeneration: 1)
        #expect(f.begin("b"))
        var deliveredB: [Int16] = []
        for packet in 1...201 {
            f.session.deliver([Int16](repeating: Int16(packet), count: 160), enqueue: {
                deliveredB.append(contentsOf: $0)
                f.pending[2, default: 0] += $0.count
                return true
            }, discard: { _ in Issue.record("B was discarded") })
            f.pending[1, default: 0] -= 160
            f.tick(10)
        }
        f.session.stop(deliveryGeneration: 2)
        #expect(f.pending[1] == 15_840)
        #expect(f.events == ["a-down"])
        #expect(deliveredB.isEmpty)
        f.pending[1] = 0
        f.presentation[1] = 0.004
        f.tick(990)
        #expect(f.events == ["a-down"])
        f.presentation[1] = nil
        f.tick(4)
        #expect(deliveredA == 48_000)
        let expectedB = (1...201).flatMap { [Int16](repeating: Int16($0), count: 160) }
        let completeInOrder = deliveredB == expectedB
        #expect(completeInOrder)
        f.pending[2] = 0
        f.tick(8)
        #expect(f.events == ["a-down", "a-up", "b-down", "b-up"])
    }

    @Test func exceedingEitherPrerollBudgetDiscardsOnlyTheNewestPhysicalPress() {
        for batchLimited in [false, true] {
            let f = Fixture()
            #expect(f.begin("a"))
            f.audio(1, 11)
            f.session.stop(deliveryGeneration: 1)
            #expect(f.begin("b"))
            let batchCount = batchLimited ? RC003HeldFnSession.maximumBufferedBatches : 1
            let batchSize = batchLimited ? 1 : RC003HeldFnSession.maximumBufferedSamples
            let packet = [Int16](repeating: 2, count: batchSize)
            var discarded = 0
            let keepOutOfPlayer: ([Int16]) -> Bool = { _ in Issue.record("Rejected B reached output"); return false }
            let account: (Int) -> Void = { discarded += $0 }
            for _ in 0..<batchCount {
                #expect(f.session.deliver(packet, enqueue: keepOutOfPlayer, discard: account))
            }
            #expect(!f.session.deliver([3], enqueue: keepOutOfPlayer, discard: account))
            #expect(f.session.rejectedPressReason == "preroll_full")
            #expect(discarded == batchSize * batchCount + 1)
            #expect(f.events == ["a-down", "audio-1-11"])
            f.pending[1] = 0
            f.presentation[1] = 0.004
            f.tick(10)
            #expect(f.events.last == "audio-1-11")
            f.presentation[1] = nil
            f.tick(4)
            #expect(f.events.last == "a-up")
            #expect(!f.session.deliver([4, 5], enqueue: keepOutOfPlayer, discard: account))
            #expect(discarded == batchSize * batchCount + 3)
            #expect(f.session.isBusy)
            #expect(!f.begin("overlapping"))
            f.session.stop(deliveryGeneration: 2)
            #expect(!f.session.isBusy)
            #expect(f.begin("c"))
            f.audio(3, 31)
            f.pending[3] = 0
            f.session.stop(deliveryGeneration: 3)
            #expect(f.events == ["a-down", "audio-1-11", "a-up", "c-down", "audio-3-31", "c-up"])
        }
    }

    @Test func oneMinuteOfNativeFramesFitsTheBoundedPrerollInOrder() {
        let f = Fixture()
        #expect(f.begin("a"))
        f.pending[1] = 960_000
        f.session.stop(deliveryGeneration: 1)
        #expect(f.begin("b"))
        var nextPacket = 0
        var inOrder = true
        for packet in 0..<4_000 {
            let data = [Int16](repeating: Int16(packet), count: 240)
            f.session.deliver(data, enqueue: { samples in
                inOrder = inOrder && samples.count == 240 && samples.allSatisfy { $0 == Int16(nextPacket) }
                nextPacket += 1
                f.pending[2, default: 0] += samples.count
                return true
            }, discard: { _ in Issue.record("Native minute did not fit") })
            f.pending[1, default: 0] -= 240
            f.tick(15)
        }
        #expect(inOrder && nextPacket == 4_000)
        #expect(f.pending[2] == 960_000)
        f.pending[2] = 0
        f.session.stop(deliveryGeneration: 2)
        #expect(f.events == ["a-down", "a-up", "b-down", "b-up"])
    }

    @Test func routeFailureAccountsForOlderBufferedAudioIndependentlyOfNewInputOverflow() {
        let f = Fixture()
        #expect(f.begin("a"))
        f.audio(1, 11)
        f.session.stop(deliveryGeneration: 1)
        var losses: [String: Int] = [:]
        #expect(f.begin("b"))
        f.session.deliver([21, 22], enqueue: { _ in true }, discardWithReason: { losses[$1, default: 0] += $0 })
        f.session.stop(deliveryGeneration: 2)
        #expect(f.begin("c"))
        let excessive = [Int16](repeating: 3, count: RC003HeldFnSession.maximumBufferedSamples)
        f.session.deliver(excessive, enqueue: { _ in true }, discardWithReason: { losses[$1, default: 0] += $0 })
        f.interrupted.insert(1)
        f.tick(8)
        #expect(losses == ["preroll_full": excessive.count, "playback_interrupted": 2])
        #expect(f.events == ["a-down", "audio-1-11", "a-up", "playback_interrupted"])
        #expect(!f.session.isBusy)
    }

    @Test func ninthPressCannotCancelAnyOfTheEightAcceptedPresses() {
        let f = Fixture()
        for id in 1...8 {
            #expect(f.begin("p\(id)"))
            f.audio(id, Int16(id))
            f.session.stop(deliveryGeneration: id)
        }
        #expect(!f.begin("rejected"))
        #expect(f.session.rejectedPressReason == "press_queue_full")
        f.audio(9, 9)
        f.session.stop(deliveryGeneration: 9)
        for id in 1...8 {
            f.pending[id] = 0
            f.tick(8)
        }
        let expected = (1...8).flatMap { ["p\($0)-down", "audio-\($0)-\($0)", "p\($0)-up"] }
        #expect(f.events.filter { $0 != "discard-9" } == expected)
        #expect(f.events.filter { $0 == "discard-9" }.count == 1)
        #expect(!f.session.isBusy)
    }

    @Test func cancelOrStallWhileNewestPressIsRejectedStillResetsTheQueue() {
        for stall in [false, true] {
            let f = Fixture()
            #expect(f.begin("a"))
            f.audio(1, 10)
            f.session.stop(deliveryGeneration: 1)
            #expect(f.begin("b"))
            let oversized = [Int16](repeating: 0, count: RC003HeldFnSession.maximumBufferedSamples + 1)
            #expect(!f.session.deliver(oversized, enqueue: { _ in false }, discard: { _ in }))
            if stall { f.tick(2_100) } else { f.session.cancel() }
            #expect(!f.session.isBusy)
            #expect(f.session.rejectedPressReason == nil)
            #expect(f.events.filter { $0 == "a-up" }.count == 1)
            #expect(f.events.contains("playback_stalled") == stall)
            #expect(f.begin("c"))
            f.tick(8)
            #expect(f.events.last == "c-down")
        }
    }

    @Test func coalescedNativeFramesWaitForTheWholeTicketAndDevicePresentation() {
        let f = Fixture()
        var configuration = CommandVoiceActivationAudioBuffer(maximumSampleCount: 32_000)
        configuration.begin()
        for _ in 0..<133 { _ = configuration.appendIfWaiting([Int16](repeating: 0, count: 240)) }
        let batch = configuration.drain()
        #expect(batch.count == 31_920)
        #expect(f.begin("a"))
        f.session.deliver(batch, enqueue: { f.pending[1] = $0.count; return true },
                          discard: { _ in Issue.record("Accepted configuration audio discarded") })
        f.session.stop(deliveryGeneration: 1)
        #expect(f.begin("b"))
        f.audio(2, 11)
        f.session.stop(deliveryGeneration: 2)
        f.tick(2_000)
        #expect(f.events == ["a-down"])
        // 1,995 ms of source plus one 512/48k output quantum is 2,005.67 ms.
        f.pending[1] = 0
        f.presentation[1] = 0.003
        f.tick(6)
        #expect(f.events == ["a-down"])
        f.presentation[1] = nil
        f.tick(3)
        f.pending[2] = 0
        f.tick(8)
        #expect(f.events == ["a-down", "a-up", "b-down", "audio-2-11", "b-up"])
    }

    @Test func aQueuedFourSecondTicketKeepsItsOwnCallbackBudget() {
        let f = Fixture()
        #expect(f.begin("a"))
        f.audio(1, 1)
        f.session.stop(deliveryGeneration: 1)
        #expect(f.begin("b"))
        f.session.deliver([Int16](repeating: 0, count: 64_000),
                          enqueue: { f.pending[2] = $0.count; return true },
                          discard: { _ in Issue.record("Queued ticket discarded") })
        f.session.stop(deliveryGeneration: 2)
        f.pending[1] = 0
        f.tick(8)
        f.tick(2_000)
        #expect(f.events.last == "b-down")
        f.pending[2] = 0
        f.tick(2_011)
        #expect(f.events.last == "b-up")
        #expect(!f.events.contains("playback_stalled"))
    }

    @Test func frozenTicketsTimeOutEvenIfTheEngineKeepsRendering() {
        let cases = [(240, 4_000, 2_000), (31_920, 1, 2_745),
                     (64_000, 1, 4_750), (131_070, 1, 8_942)]
        for (size, count, deadlineMS) in cases {
            let f = Fixture()
            let packet = [Int16](repeating: 0, count: size)
            #expect(f.begin("a"))
            for _ in 0..<count {
                f.session.deliver(packet, enqueue: { f.pending[1, default: 0] += $0.count; return true },
                                  discard: { _ in Issue.record("Unexpected discard") })
            }
            f.session.stop(deliveryGeneration: 1)
            var elapsed = 0
            while elapsed + 8 < deadlineMS {
                elapsed += 8
                f.presentation[1] = elapsed.isMultiple(of: 16) ? 0 : 0.010667
                f.tick(8)
            }
            #expect(f.events == ["a-down"])
            f.tick(deadlineMS + 1 - elapsed)
            #expect(f.events == ["a-down", "a-up", "playback_stalled"])
            #expect(!f.session.isBusy)
        }
    }

    @Test func aLargePlayedTicketDoesNotExtendTheRemainingShortTail() {
        let f = Fixture()
        #expect(f.begin("a"))
        f.session.deliver([Int16](repeating: 0, count: 64_000),
                          enqueue: { f.pending[1] = $0.count; return true }, discard: { _ in })
        f.audio(1, 1)
        f.session.stop(deliveryGeneration: 1)
        f.pending[1] = 1
        f.tick(10)
        f.tick(749)
        #expect(f.events.last == "audio-1-1")
        f.tick(2)
        #expect(f.events.suffix(2) == ["a-up", "playback_stalled"])
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
