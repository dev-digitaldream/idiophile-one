#import "ExceptionCatcher.h"

NSError *_Nullable IdiophileTry(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return [NSError errorWithDomain:@"IdiophileOne.AudioException" code:1 userInfo:@{
            NSLocalizedDescriptionKey: exception.reason ?: exception.name,
        }];
    }
}
