#import "ObjCSupport.h"

NSError * _Nullable NGRunCatchingExceptions(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *desc = exception.reason ?: exception.name;
        return [NSError errorWithDomain:@"NotchGlass.ObjCException"
                                   code:1
                               userInfo:desc ? @{NSLocalizedDescriptionKey: desc} : nil];
    }
}
