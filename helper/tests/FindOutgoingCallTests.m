#import <Foundation/Foundation.h>

#import "../FaceTimeHelper/FindOutgoingCall.h"

static int Fail(NSString *message) {
    fputs([[NSString stringWithFormat:@"FindOutgoingCallTests: %@\n", message] UTF8String], stderr);
    return 1;
}

int main(void) {
    if (OpenClawFaceTimeFindOutgoingActionForMatch(NO, NO, NO) != OpenClawFaceTimeFindOutgoingAbsent) {
        return Fail(@"no match must stay absent");
    }
    if (OpenClawFaceTimeFindOutgoingActionForMatch(YES, NO, NO) != OpenClawFaceTimeFindOutgoingAbsent) {
        return Fail(@"a non-FaceTime match must be absent and must not disconnect");
    }
    if (OpenClawFaceTimeFindOutgoingActionForMatch(YES, YES, NO) != OpenClawFaceTimeFindOutgoingDisconnect) {
        return Fail(@"a FaceTime match that dropped safety mute must disconnect");
    }
    if (OpenClawFaceTimeFindOutgoingActionForMatch(YES, YES, YES) != OpenClawFaceTimeFindOutgoingKeep) {
        return Fail(@"a muted FaceTime match must be kept");
    }
    return 0;
}
