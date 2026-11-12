#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and turns an Objective-C exception (which Swift cannot catch) into an error. Some system
/// frameworks (BackgroundTasks among them) raise assertions for bad configuration instead of returning an
/// error; calling them through this keeps the app alive.
BOOL BLTryObjC(NS_NOESCAPE void (^block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
