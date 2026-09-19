#import <Foundation/Foundation.h>

#import "../FaceTimeHelper/MutedFlag.h"

static int Fail(NSString *message) {
    fputs([[NSString stringWithFormat:@"MutedFlagTests: %@\n", message] UTF8String], stderr);
    return 1;
}

static id DecodeJSON(NSString *json) {
    NSData *bytes = [json dataUsingEncoding:NSUTF8StringEncoding];
    return [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
}

// Same path as FaceTimeHelper handleMessage: after JSON-decoding the
// authenticated action payload, parse data[@"muted"] before any call audio
// side effects.
static BOOL ParseSetMutedCommand(NSString *payloadJSON, BOOL *outMuted) {
    id command = DecodeJSON(payloadJSON);
    NSDictionary *data = [command isKindOfClass:[NSDictionary class]] ? command[@"data"] : nil;
    return OpenClawFaceTimeParseMutedFlag(
        [data isKindOfClass:[NSDictionary class]] ? data[@"muted"] : nil,
        outMuted);
}

int main(void) {
    @autoreleasepool {
        BOOL muted = NO;
        if (!ParseSetMutedCommand(
                @"{\"action\":\"set-muted\",\"data\":{\"muted\":true,\"callUUID\":\"call-1\"}}",
                &muted) || !muted) {
            return Fail(@"JSON true must mute");
        }
        muted = YES;
        if (!ParseSetMutedCommand(
                @"{\"action\":\"set-muted\",\"data\":{\"muted\":false,\"callUUID\":\"call-1\"}}",
                &muted) || muted) {
            return Fail(@"JSON false must unmute only after a typed bool");
        }

        muted = YES;
        if (ParseSetMutedCommand(
                @"{\"action\":\"set-muted\",\"data\":{\"muted\":0,\"callUUID\":\"call-1\"}}",
                &muted) || !muted) {
            return Fail(@"JSON number 0 must be rejected without unmuting");
        }
        muted = YES;
        if (ParseSetMutedCommand(
                @"{\"action\":\"set-muted\",\"data\":{\"muted\":1,\"callUUID\":\"call-1\"}}",
                &muted) || !muted) {
            return Fail(@"JSON number 1 must be rejected");
        }
        muted = YES;
        if (ParseSetMutedCommand(
                @"{\"action\":\"set-muted\",\"data\":{\"muted\":0.5,\"callUUID\":\"call-1\"}}",
                &muted) || !muted) {
            return Fail(@"JSON fractional number must be rejected");
        }
        if (ParseSetMutedCommand(
                @"{\"action\":\"set-muted\",\"data\":{\"muted\":null,\"callUUID\":\"call-1\"}}",
                &muted)) {
            return Fail(@"JSON null must not be treated as a muted flag");
        }
        if (ParseSetMutedCommand(
                @"{\"action\":\"set-muted\",\"data\":{\"callUUID\":\"call-1\"}}",
                &muted)) {
            return Fail(@"a missing muted field must be rejected");
        }
        if (ParseSetMutedCommand(
                @"{\"action\":\"set-muted\",\"data\":{\"muted\":\"true\",\"callUUID\":\"call-1\"}}",
                &muted)) {
            return Fail(@"a string muted field must be rejected");
        }
        if (ParseSetMutedCommand(
                @"{\"action\":\"set-muted\",\"data\":{\"muted\":[],\"callUUID\":\"call-1\"}}",
                &muted)) {
            return Fail(@"a non-boolean muted field must be rejected");
        }
    }
    return 0;
}
