#import "include/RiffleShims.h"

NSError * _Nullable RiffleTryCatch(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *message = [NSString stringWithFormat:@"%@: %@",
                             exception.name,
                             exception.reason ?: @"(no reason)"];
        return [NSError errorWithDomain:@"RiffleException"
                                   code:13
                               userInfo:@{NSLocalizedDescriptionKey: message}];
    }
}
