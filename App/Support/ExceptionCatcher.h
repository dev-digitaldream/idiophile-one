#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised, if any, as an NSError.
/// AVAudioPlayerNode and AVAudioEngine raise NSExceptions (not Swift errors) when started
/// while the audio hardware is being reconfigured; Swift cannot catch those.
NSError *_Nullable IdiophileTry(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
