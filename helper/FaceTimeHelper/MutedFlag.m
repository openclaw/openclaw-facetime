#import "MutedFlag.h"

BOOL OpenClawFaceTimeParseMutedFlag(id value, BOOL *outMuted) {
    if (![value isKindOfClass:[NSNumber class]]) {
        return NO;
    }
    // NSJSONSerialization maps true/false to CFBoolean and 0/1 to CFNumber.
    if (CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) {
        return NO;
    }
    if (outMuted != NULL) {
        *outMuted = CFBooleanGetValue((__bridge CFBooleanRef)value);
    }
    return YES;
}
