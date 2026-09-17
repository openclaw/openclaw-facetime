#import <Foundation/Foundation.h>

// Parses the authenticated set-muted "muted" field. JSON true/false become
// NSNumber. JSON null is NSNull and must not receive -boolValue.
BOOL OpenClawFaceTimeParseMutedFlag(id value, BOOL *outMuted);
