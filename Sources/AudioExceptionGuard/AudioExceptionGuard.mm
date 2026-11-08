#import "AudioExceptionGuard.h"

BOOL RemoteBuddyTryAudioOperation(void (^operation)(void)) {
    try {
        @try {
            operation();
            return YES;
        } @catch (__unused NSException *exception) {
            return NO;
        }
    } catch (...) {
        return NO;
    }
}

BOOL RemoteBuddyTryPlayAudioPlayerNode(AVAudioPlayerNode *player) {
    return RemoteBuddyTryAudioOperation(^{ [player play]; });
}
