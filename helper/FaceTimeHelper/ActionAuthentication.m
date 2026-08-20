#import "ActionAuthentication.h"

#import <CommonCrypto/CommonHMAC.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString * const OpenClawFaceTimeAuthenticationErrorDomain =
    @"ai.openclaw.facetime.helper-authentication";

static NSString *HelperAuthenticationErrorDescription(NSString *message) {
    return message ?: @"FaceTime helper authentication failed";
}

static void SetHelperAuthenticationError(NSError **error, NSInteger code, NSString *message) {
    if (error == NULL) {
        return;
    }
    *error = [NSError errorWithDomain:OpenClawFaceTimeAuthenticationErrorDomain
                                 code:code
                             userInfo:@{
                                 NSLocalizedDescriptionKey: HelperAuthenticationErrorDescription(message),
                             }];
}

NSString *OpenClawFaceTimeLoadHelperTokenAtPath(NSString *dylibPath, NSError **error) {
    NSString *authPath = [dylibPath stringByAppendingString:@".auth"];
    int descriptor = open(authPath.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        SetHelperAuthenticationError(error, 1, @"Authentication sidecar is missing or unsafe");
        return nil;
    }

    struct stat metadata;
    if (fstat(descriptor, &metadata) != 0 ||
        !S_ISREG(metadata.st_mode) ||
        metadata.st_uid != getuid() ||
        (metadata.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)) != (S_IRUSR | S_IWUSR) ||
        metadata.st_size < 64 ||
        metadata.st_size > 65) {
        close(descriptor);
        SetHelperAuthenticationError(error, 2, @"Authentication sidecar has unsafe metadata");
        return nil;
    }

    unsigned char bytes[66] = {0};
    ssize_t count = 0;
    while (count < metadata.st_size) {
        ssize_t chunk = read(
            descriptor,
            bytes + count,
            (size_t)(metadata.st_size - count)
        );
        if (chunk <= 0) {
            count = -1;
            break;
        }
        count += chunk;
    }
    close(descriptor);
    if (count < 0 || count != metadata.st_size) {
        SetHelperAuthenticationError(error, 3, @"Authentication sidecar could not be read");
        return nil;
    }

    NSString *rawToken = [[NSString alloc] initWithBytes:bytes
                                                   length:(NSUInteger)count
                                                 encoding:NSUTF8StringEncoding];
    NSString *token = [rawToken stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (token.length != 64) {
        SetHelperAuthenticationError(error, 4, @"Authentication sidecar token is malformed");
        return nil;
    }
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
    if ([[token stringByTrimmingCharactersInSet:hex] length] != 0) {
        SetHelperAuthenticationError(error, 4, @"Authentication sidecar token is malformed");
        return nil;
    }
    return token;
}

NSString *OpenClawFaceTimeLoadHelperTokenForImageAddress(
    const void *imageAddress,
    NSError **error
) {
    Dl_info imageInfo;
    if (imageAddress == NULL || dladdr(imageAddress, &imageInfo) == 0 || imageInfo.dli_fname == NULL) {
        SetHelperAuthenticationError(error, 5, @"Injected helper image path could not be resolved");
        return nil;
    }
    NSString *dylibPath = [NSString stringWithUTF8String:imageInfo.dli_fname];
    if (dylibPath.length == 0) {
        SetHelperAuthenticationError(error, 5, @"Injected helper image path could not be resolved");
        return nil;
    }
    return OpenClawFaceTimeLoadHelperTokenAtPath(dylibPath, error);
}

static NSString *ActionHMAC(NSString *token, NSString *message) {
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

static BOOL ActionAuthStringsEqual(NSString *first, NSString *second) {
    NSData *firstData = [first dataUsingEncoding:NSUTF8StringEncoding];
    NSData *secondData = [second dataUsingEncoding:NSUTF8StringEncoding];
    if (firstData.length == 0 || firstData.length != secondData.length) {
        return NO;
    }
    const unsigned char *firstBytes = firstData.bytes;
    const unsigned char *secondBytes = secondData.bytes;
    unsigned char difference = 0;
    for (NSUInteger index = 0; index < firstData.length; index++) {
        difference |= firstBytes[index] ^ secondBytes[index];
    }
    return difference == 0;
}

@implementation OpenClawFaceTimeActionAuthenticator {
    NSString *_token;
    NSString *_session;
    NSMutableSet<NSString *> *_acceptedNonces;
}

- (instancetype)initWithProofMaterial:(NSString *)proofMaterial {
    self = [super init];
    if (self) {
        _token = [proofMaterial copy];
        _session = @"";
        _acceptedNonces = [NSMutableSet set];
    }
    return self;
}

- (void)resetWithSession:(NSString *)session {
    @synchronized(self) {
        _session = [session copy];
        _acceptedNonces = [NSMutableSet set];
    }
}

- (OpenClawFaceTimeActionAuthResult)consumeAction:(NSString *)action
                                    transactionID:(NSString *)transactionID
                                           session:(NSString *)session
                                             nonce:(NSString *)nonce
                                          dataJSON:(NSString *)dataJSON
                                              auth:(NSString *)auth {
    @synchronized(self) {
        if (action.length == 0 || transactionID.length == 0 || session.length == 0 ||
            nonce.length == 0 || dataJSON.length == 0 || ![_session isEqualToString:session]) {
            return OpenClawFaceTimeActionAuthResultUnauthenticated;
        }
        NSString *payload = [NSString stringWithFormat:@"action\n%@\n%@\n%@\n%@\n%@",
            action, transactionID, session, nonce, dataJSON];
        if (!ActionAuthStringsEqual(auth, ActionHMAC(_token, payload))) {
            return OpenClawFaceTimeActionAuthResultUnauthenticated;
        }
        if ([_acceptedNonces containsObject:nonce]) {
            return OpenClawFaceTimeActionAuthResultReplay;
        }
        [_acceptedNonces addObject:nonce];
        return OpenClawFaceTimeActionAuthResultAccepted;
    }
}

@end
