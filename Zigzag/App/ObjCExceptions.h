#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `body` and returns the Objective-C exception it threw, if any, so it never unwinds through Swift.
NSException *_Nullable ZigzagCatchingException(NS_NOESCAPE void (^body)(void)) NS_SWIFT_NAME(catchingException(_:));

NS_ASSUME_NONNULL_END
