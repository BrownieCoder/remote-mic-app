#import "RemoteMicAudioRenderClock.h"
#import <AudioToolbox/AudioToolbox.h>
#import <mach/mach_time.h>
#import <stdatomic.h>

typedef struct {
    double ticksPerFrame;
    UInt64 latencyTicks;
    _Atomic UInt64 occupiedThrough;
    _Atomic UInt64 renderedThrough;
    _Atomic UInt64 renderingThrough;
    _Atomic UInt64 clockErrors;
} RenderClockState;

// Both the observer block and its readers own this storage. A callback
// already entered at teardown never depends on the Swift controller's lifetime.
@interface RemoteMicRenderStorage : NSObject {
@public RenderClockState clock;
}
@end
@implementation RemoteMicRenderStorage
@end

static void recordOutputBlock(RenderClockState *state, AudioUnitRenderActionFlags flags,
                              const AudioTimeStamp *time, UInt32 frames, NSInteger bus) {
    if (bus != 0 || !frames) return;
    double scalar = (time->mFlags & kAudioTimeStampRateScalarValid) ? time->mRateScalar : 1;
    if (!(time->mFlags & kAudioTimeStampHostTimeValid) || !time->mHostTime || !isfinite(scalar) ||
        scalar <= 0 || (flags & kAudioUnitRenderAction_PostRenderError)) {
        atomic_fetch_add_explicit(&state->clockErrors, 1, memory_order_release);
        return;
    }
    UInt64 end = time->mHostTime + (UInt64)ceil(frames * state->ticksPerFrame * scalar) + state->latencyTicks;
    if (flags & kAudioUnitRenderAction_PreRender) {
        atomic_store_explicit(&state->renderingThrough, end, memory_order_release);
        return;
    }
    if (!(flags & kAudioUnitRenderAction_PostRender)) return;
    // A scheduled all-zero buffer also occupies a render block. The mixer
    // sets OutputIsSilence after its source and sample-rate converter run dry.
    if (!(flags & kAudioUnitRenderAction_OutputIsSilence)) {
        atomic_store_explicit(&state->occupiedThrough, end, memory_order_release);
    }
    atomic_store_explicit(&state->renderedThrough, end, memory_order_release);
    atomic_store_explicit(&state->renderingThrough, 0, memory_order_release);
}

@implementation RemoteMicAudioRenderClock {
    AUAudioUnit *_unit;
    NSInteger _token;
    RemoteMicRenderStorage *_storage;
}

- (nullable instancetype)initWithMixer:(AVAudioMixerNode *)mixer
                            sampleRate:(double)sampleRate
                               latency:(NSTimeInterval)latency {
    self = [super init];
    if (!self || !isfinite(sampleRate) || sampleRate <= 0 || !isfinite(latency) || latency < 0) return nil;
    mach_timebase_info_data_t base;
    if (mach_timebase_info(&base) != KERN_SUCCESS || !base.numer) return nil;
    double ticksPerSecond = 1e9 * base.denom / base.numer;
    RemoteMicRenderStorage *storage = [RemoteMicRenderStorage new];
    storage->clock.ticksPerFrame = ticksPerSecond / sampleRate;
    storage->clock.latencyTicks = (UInt64)ceil(latency * ticksPerSecond);
    _storage = storage;
    _unit = mixer.AUAudioUnit;
    _token = [_unit tokenByAddingRenderObserver:^(AudioUnitRenderActionFlags flags,
                    const AudioTimeStamp *time, AUAudioFrameCount frames, NSInteger bus) {
        recordOutputBlock(&storage->clock, flags, time, frames, bus);
    }];
    return self;
}

- (RemoteMicAudioRenderPosition)position {
    RenderClockState *state = &_storage->clock;
    UInt64 rendering = atomic_load_explicit(&state->renderingThrough, memory_order_acquire);
    UInt64 rendered = atomic_load_explicit(&state->renderedThrough, memory_order_acquire);
    UInt64 occupied = atomic_load_explicit(&state->occupiedThrough, memory_order_acquire);
    UInt64 errors = atomic_load_explicit(&state->clockErrors, memory_order_acquire);
    return (RemoteMicAudioRenderPosition){occupied, rendered, rendering, errors};
}

- (void)invalidate {
    [_unit removeRenderObserver:_token];
    _unit = nil;
}

- (void)dealloc { [self invalidate]; }
@end
