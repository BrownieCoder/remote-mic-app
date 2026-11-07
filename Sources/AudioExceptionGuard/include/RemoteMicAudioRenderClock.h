#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    UInt64 occupiedThrough; // End of the last block containing scheduled frames.
    UInt64 renderedThrough; // End of the last block, including an idle block.
    UInt64 renderingThrough; // Upper bound of a render in progress during cancellation.
    UInt64 clockErrors;
} RemoteMicAudioRenderPosition;

@interface RemoteMicAudioRenderClock : NSObject
- (nullable instancetype)initWithMixer:(AVAudioMixerNode *)mixer
                            sampleRate:(double)sampleRate
                               latency:(NSTimeInterval)latency;
@property (nonatomic, readonly) RemoteMicAudioRenderPosition position;
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
