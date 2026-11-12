#import "ObjCSafe.h"

BOOL BLTryObjC(NS_NOESCAPE void (^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"BacklineObjCException" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: exception.name,
                                                @"name": exception.name}];
        }
        return NO;
    }
}
