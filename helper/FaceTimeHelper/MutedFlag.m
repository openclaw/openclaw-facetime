#import "MutedFlag.h"

BOOL OpenClawFaceTimeParseMutedFlag(id value, BOOL *outMuted) {
    if (![value isKindOfClass:[NSNumber class]]) {
        return NO;
    }
    if (outMuted != NULL) {
        *outMuted = [value boolValue];
    }
    return YES;
}
