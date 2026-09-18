#import <Foundation/Foundation.h>

// Parses the authenticated set-muted "muted" field. Accepts only JSON
// true/false (CFBoolean). Numbers, strings, null, and a missing field
// must be rejected so they cannot unmute or crash FaceTime.
BOOL OpenClawFaceTimeParseMutedFlag(id value, BOOL *outMuted);
