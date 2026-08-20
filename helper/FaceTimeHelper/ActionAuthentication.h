#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * _Nullable OpenClawFaceTimeLoadHelperTokenAtPath(
    NSString *dylibPath,
    NSError * _Nullable * _Nullable error
);
FOUNDATION_EXPORT NSString * _Nullable OpenClawFaceTimeLoadHelperTokenForImageAddress(
    const void *imageAddress,
    NSError * _Nullable * _Nullable error
);

typedef NS_ENUM(NSInteger, OpenClawFaceTimeActionAuthResult) {
    OpenClawFaceTimeActionAuthResultUnauthenticated,
    OpenClawFaceTimeActionAuthResultAccepted,
    OpenClawFaceTimeActionAuthResultReplay,
};

@interface OpenClawFaceTimeActionAuthenticator : NSObject

- (instancetype)initWithProofMaterial:(NSString *)proofMaterial;
- (void)resetWithSession:(NSString *)session;
- (OpenClawFaceTimeActionAuthResult)consumeAction:(NSString *)action
                                    transactionID:(NSString *)transactionID
                                           session:(NSString *)session
                                             nonce:(NSString *)nonce
                                          dataJSON:(NSString *)dataJSON
                                              auth:(NSString *)auth;

@end

NS_ASSUME_NONNULL_END
