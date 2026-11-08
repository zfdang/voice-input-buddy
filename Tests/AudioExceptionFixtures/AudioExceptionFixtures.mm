#import "AudioExceptionFixtures.h"
#import "AudioExceptionGuard.h"
#include <stdexcept>

BOOL AudioFixtureCatchesCppException(void) {
    return !RemoteBuddyTryAudioOperation(^{ throw std::runtime_error("fixture"); });
}
