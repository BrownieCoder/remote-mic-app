import CoreGraphics
import Foundation
import Testing
@testable import RemoteMic

struct RC003VoicePlaybackInterruptionTests {
    @Test func heldKeyboardModifiersSurviveTheRemoteFunctionPair() throws {
        let state = ShortcutHardwareModifierState()
        #expect(ShortcutEventSequence.managedFunctionFlags(pressed: true, raw: .maskSecondaryFn, state: state) == nil)
        #expect(ShortcutEventSequence.managedFunctionFlags(pressed: true, raw: .maskShift, state: state) == nil)
        #expect(ShortcutEventSequence.managedFunctionFlags(pressed: true, raw: .maskAlphaShift, state: state) == [.maskAlphaShift, .maskSecondaryFn])
        #expect(ShortcutEventSequence.managedFunctionFlags(pressed: false, raw: [.maskShift, .maskSecondaryFn], state: state) == .maskShift)
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: true))
        event.flags = .maskSecondaryFn
        state.observe(type: .flagsChanged, event: event)
        #expect(ShortcutEventSequence.managedFunctionFlags(pressed: false, raw: .maskShift, state: state) == [.maskShift, .maskSecondaryFn])
    }

    @Test func revocationRejectsLatePlayedCallbacksButPreservesOtherOwnersEvenInTheSameGeneration() async {
        let output = VirtualAudioOutput(logger: { _ in })
        let completed = output.registerPendingVoiceBuffer(sampleCount: 120, deliveryGeneration: 1, rc003HeldFn: true)
        output.scheduledVoiceBufferDidFinish(completed)
        let stale = output.registerPendingVoiceBuffer(sampleCount: 2_880, deliveryGeneration: 1, rc003HeldFn: true)
        let unrelated = output.registerPendingVoiceBuffer(sampleCount: 240, deliveryGeneration: 1)
        let otherGeneration = output.registerPendingVoiceBuffer(sampleCount: 360, deliveryGeneration: 77)
        await withCheckedContinuation { continuation in
            output.interruptHeldFnPlayback { continuation.resume() }
        }
        let cancelled = output.diagnosticSnapshot(deliveryGeneration: 1)
        #expect(cancelled.counters.playedSamples == 120)
        #expect(cancelled.counters.interruptedSamples == 2_880)
        #expect(cancelled.pendingSamples == 240)
        #expect(output.diagnosticSnapshot(deliveryGeneration: 77).pendingSamples == 360)
        let fresh = output.registerPendingVoiceBuffer(sampleCount: 2_160, deliveryGeneration: 2, rc003HeldFn: true)
        output.scheduledVoiceBufferDidFinish(stale)
        output.scheduledVoiceBufferDidFinish(stale, playedBack: false)
        #expect(output.diagnosticSnapshot(deliveryGeneration: 2).pendingSamples == 2_160)
        output.scheduledVoiceBufferDidFinish(unrelated)
        output.scheduledVoiceBufferDidFinish(otherGeneration)
        output.scheduledVoiceBufferDidFinish(fresh)
        let first = output.diagnosticSnapshot(deliveryGeneration: 1)
        let next = output.diagnosticSnapshot(deliveryGeneration: 2)
        #expect(first.counters.playedSamples == 360 && first.counters.interruptedSamples == 2_880)
        #expect(next.counters.playedSamples == 2_160 && next.counters.interruptedSamples == 0)
        #expect(output.diagnosticSnapshot().pendingSamples == 0)
    }

    @Test func engineStopAndLateCallbacksCannotCreditReusedDeliveryNumbers() async {
        let output = VirtualAudioOutput(logger: { _ in })
        let stale = output.registerPendingVoiceBuffer(sampleCount: 1_680, deliveryGeneration: 1, rc003HeldFn: true)
        await Task.detached { output.stop() }.value
        let current = output.registerPendingVoiceBuffer(sampleCount: 2_160, deliveryGeneration: 1, rc003HeldFn: true)
        output.scheduledVoiceBufferDidFinish(stale)
        #expect(output.diagnosticSnapshot(deliveryGeneration: 1).pendingSamples == 2_160)
        output.scheduledVoiceBufferDidFinish(current)
        let final = output.diagnosticSnapshot(deliveryGeneration: 1)
        #expect(final.counters.playedSamples == 2_160 && final.counters.interruptedSamples == 1_680)
    }
}
