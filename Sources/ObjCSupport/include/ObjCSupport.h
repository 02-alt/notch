#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, converting any raised Objective-C `NSException` into an `NSError`
/// (returned) instead of letting it propagate. Swift's `do/catch` only handles Swift
/// errors — it cannot catch Objective-C exceptions, which AVFoundation (AVAudioEngine)
/// and Contacts raise on some failure/hardware states, crashing the process. Wrap those
/// calls in this so the app survives and can log/recover instead.
///
/// Returns nil when `block` completed normally.
NSError * _Nullable NGRunCatchingExceptions(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
