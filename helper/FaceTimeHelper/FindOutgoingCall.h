#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, OpenClawFaceTimeFindOutgoingAction) {
    OpenClawFaceTimeFindOutgoingKeep = 0,
    OpenClawFaceTimeFindOutgoingAbsent = 1,
    OpenClawFaceTimeFindOutgoingDisconnect = 2,
};

// find-outgoing-call is a lookup. Non-FaceTime matches must be absent
// (no disconnect). Only a verified FaceTime call that drops safety mute
// is disconnected.
OpenClawFaceTimeFindOutgoingAction OpenClawFaceTimeFindOutgoingActionForMatch(
    BOOL matched,
    BOOL verifiedFaceTime,
    BOOL safetyMuteRetained);
