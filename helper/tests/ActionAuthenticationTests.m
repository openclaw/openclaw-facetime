#import <CommonCrypto/CommonHMAC.h>
#import <Foundation/Foundation.h>
#import <sys/stat.h>

#import "../FaceTimeHelper/ActionAuthentication.h"

static NSString *TestHMAC(NSString *token, NSString *message) {
    NSData *key = [token dataUsingEncoding:NSUTF8StringEncoding];
    NSData *payload = [message dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, payload.bytes, payload.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
}

static OpenClawFaceTimeActionAuthResult Consume(
    OpenClawFaceTimeActionAuthenticator *authenticator,
    NSString *token,
    NSString *session,
    NSString *nonce
) {
    NSString *payload = [NSString stringWithFormat:@"action\nstart-call\ntx-1\n%@\n%@\n{}",
        session, nonce];
    return [authenticator
        consumeAction:@"start-call"
        transactionID:@"tx-1"
        session:session
        nonce:nonce
        dataJSON:@"{}"
        auth:TestHMAC(token, payload)];
}

int main(void) {
    @autoreleasepool {
        NSString *token = [@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0];
        OpenClawFaceTimeActionAuthenticator *authenticator =
            [[OpenClawFaceTimeActionAuthenticator alloc] initWithProofMaterial:token];

        [authenticator resetWithSession:@"session-1"];
        NSCAssert(
            Consume(authenticator, token, @"session-1", @"nonce-1") ==
                OpenClawFaceTimeActionAuthResultAccepted,
            @"first authenticated action must be accepted"
        );
        NSCAssert(
            Consume(authenticator, token, @"session-1", @"nonce-1") ==
                OpenClawFaceTimeActionAuthResultReplay,
            @"same-session nonce replay must be rejected"
        );

        [authenticator resetWithSession:@"session-2"];
        NSCAssert(
            Consume(authenticator, token, @"session-1", @"nonce-2") ==
                OpenClawFaceTimeActionAuthResultUnauthenticated,
            @"prior-session envelope must be rejected after reconnect"
        );
        NSCAssert(
            Consume(authenticator, token, @"session-2", @"nonce-1") ==
                OpenClawFaceTimeActionAuthResultAccepted,
            @"a nonce belongs to its authenticated session"
        );

        NSString *temporaryDirectory = [NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager *fileManager = NSFileManager.defaultManager;
        NSCAssert(
            [fileManager createDirectoryAtPath:temporaryDirectory
                   withIntermediateDirectories:YES
                                    attributes:nil
                                         error:nil],
            @"temporary authentication directory must be created"
        );
        NSString *dylibPath = [temporaryDirectory stringByAppendingPathComponent:@"FaceTimeHelper.dylib"];
        NSString *authPath = [dylibPath stringByAppendingString:@".auth"];
        NSCAssert(
            [token writeToFile:authPath atomically:YES encoding:NSUTF8StringEncoding error:nil],
            @"authentication sidecar must be written"
        );
        NSCAssert(chmod(authPath.fileSystemRepresentation, 0600) == 0, @"sidecar mode must be private");
        NSCAssert(
            [OpenClawFaceTimeLoadHelperTokenAtPath(dylibPath, nil) isEqualToString:token],
            @"a private owner-controlled authentication sidecar must load"
        );

        NSCAssert(chmod(authPath.fileSystemRepresentation, 0644) == 0, @"sidecar mode must change");
        NSCAssert(
            OpenClawFaceTimeLoadHelperTokenAtPath(dylibPath, nil) == nil,
            @"a group- or world-readable authentication sidecar must be rejected"
        );

        NSCAssert(chmod(authPath.fileSystemRepresentation, 0700) == 0, @"sidecar mode must change");
        NSCAssert(
            OpenClawFaceTimeLoadHelperTokenAtPath(dylibPath, nil) == nil,
            @"an owner-executable authentication sidecar must be rejected"
        );

        NSCAssert(chmod(authPath.fileSystemRepresentation, 0600) == 0, @"sidecar mode must reset");
        NSCAssert(
            [@"invalid" writeToFile:authPath atomically:YES encoding:NSUTF8StringEncoding error:nil],
            @"malformed sidecar must be written"
        );
        NSCAssert(
            OpenClawFaceTimeLoadHelperTokenAtPath(dylibPath, nil) == nil,
            @"a malformed authentication token must be rejected"
        );

        NSString *linkedAuthPath = [temporaryDirectory stringByAppendingPathComponent:@"linked.auth"];
        NSCAssert(
            [token writeToFile:linkedAuthPath
                    atomically:YES
                      encoding:NSUTF8StringEncoding
                         error:nil],
            @"linked authentication target must be written"
        );
        NSCAssert(
            chmod(linkedAuthPath.fileSystemRepresentation, 0600) == 0,
            @"linked authentication target must be private"
        );
        [fileManager removeItemAtPath:authPath error:nil];
        NSCAssert(
            [fileManager createSymbolicLinkAtPath:authPath
                              withDestinationPath:linkedAuthPath
                                            error:nil],
            @"authentication symlink must be created"
        );
        NSCAssert(
            OpenClawFaceTimeLoadHelperTokenAtPath(dylibPath, nil) == nil,
            @"an authentication symlink must be rejected"
        );

        [fileManager removeItemAtPath:temporaryDirectory error:nil];
    }
    return 0;
}
