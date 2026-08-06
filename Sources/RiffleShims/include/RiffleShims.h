#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the block, converting any Objective-C NSException into an NSError.
/// AVFoundation raises NSExceptions (not Swift errors) from calls like
/// -[AVAudioNode installTapOnBus:...] when a device switch has invalidated
/// the node's format; Swift cannot catch those, so they abort the process
/// unless funneled through here.
NSError * _Nullable RiffleTryCatch(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
