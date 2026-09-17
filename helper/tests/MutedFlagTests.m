#import <Foundation/Foundation.h>

#import "../FaceTimeHelper/MutedFlag.h"

static int Fail(NSString *message) {
    fputs([[NSString stringWithFormat:@"MutedFlagTests: %@\n", message] UTF8String], stderr);
    return 1;
}

int main(void) {
    @autoreleasepool {
        BOOL muted = YES;
        if (!OpenClawFaceTimeParseMutedFlag(@YES, &muted) || !muted) {
            return Fail(@"JSON true must mute");
        }
        muted = YES;
        if (!OpenClawFaceTimeParseMutedFlag(@NO, &muted) || muted) {
            return Fail(@"JSON false must unmute only after a typed bool");
        }
        if (OpenClawFaceTimeParseMutedFlag([NSNull null], &muted)) {
            return Fail(@"JSON null must not be treated as a muted flag");
        }
        if (OpenClawFaceTimeParseMutedFlag(nil, &muted)) {
            return Fail(@"a missing muted field must be rejected");
        }
        if (OpenClawFaceTimeParseMutedFlag(@"true", &muted)) {
            return Fail(@"a string muted field must be rejected");
        }
        if (OpenClawFaceTimeParseMutedFlag(@[], &muted)) {
            return Fail(@"a non-number muted field must be rejected");
        }
    }
    return 0;
}
