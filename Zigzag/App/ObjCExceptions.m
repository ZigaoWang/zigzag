#import "ObjCExceptions.h"

NSException *ZigzagCatchingException(NS_NOESCAPE void (^body)(void)) {
    @try {
        body();
    } @catch (NSException *exception) {
        return exception;
    }
    return nil;
}
