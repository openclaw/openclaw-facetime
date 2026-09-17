#import "FindOutgoingCall.h"

OpenClawFaceTimeFindOutgoingAction OpenClawFaceTimeFindOutgoingActionForMatch(
    BOOL matched,
    BOOL verifiedFaceTime,
    BOOL safetyMuteRetained)
{
    if (!matched) {
        return OpenClawFaceTimeFindOutgoingAbsent;
    }
    if (!verifiedFaceTime) {
        return OpenClawFaceTimeFindOutgoingAbsent;
    }
    if (!safetyMuteRetained) {
        return OpenClawFaceTimeFindOutgoingDisconnect;
    }
    return OpenClawFaceTimeFindOutgoingKeep;
}
