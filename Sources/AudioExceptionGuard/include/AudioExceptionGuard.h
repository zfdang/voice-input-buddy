#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

FOUNDATION_EXPORT BOOL RemoteBuddyTryAudioOperation(void (^operation)(void));

FOUNDATION_EXPORT BOOL RemoteBuddyTryPlayAudioPlayerNode(AVAudioPlayerNode *player);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
