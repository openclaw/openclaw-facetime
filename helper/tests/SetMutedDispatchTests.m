#import <Foundation/Foundation.h>

@interface TUCall : NSObject {
    BOOL _muted;
    BOOL _uplinkMuted;
}
@property BOOL verifiedFaceTime;
@property NSUInteger muteWrites;
@property NSUInteger uplinkWrites;
- (BOOL)setMuted:(BOOL)muted;
- (void)setUplinkMuted:(BOOL)muted;
- (BOOL)isMuted;
- (BOOL)isUplinkMuted;
- (BOOL)isSendingAudio;
- (BOOL)isSendingTransmission;
@end
@implementation TUCall
- (BOOL)setMuted:(BOOL)muted { _muted = muted; self.muteWrites++; return YES; }
- (void)setUplinkMuted:(BOOL)muted { _uplinkMuted = muted; self.uplinkWrites++; }
- (BOOL)isMuted { return _muted; }
- (BOOL)isUplinkMuted { return _uplinkMuted; }
- (BOOL)isSendingAudio { return !_muted; }
- (BOOL)isSendingTransmission { return !_uplinkMuted; }
@end

static TUCall *currentCall;
static NSMutableArray *messages;
static NSUInteger audioActivations;

@interface TUCallCenter : NSObject
+ (instancetype)sharedInstance;
- (TUCall *)callWithCallUUID:(NSString *)uuid;
@end
@implementation TUCallCenter
+ (instancetype)sharedInstance { static id center; if (!center) center = [self new]; return center; }
- (TUCall *)callWithCallUUID:(NSString *)uuid { return [uuid isEqual:@"call-1"] ? currentCall : nil; }
@end

@interface FixtureController : NSObject
- (void)sendMessage:(NSDictionary *)message;
@end
@implementation FixtureController
- (void)sendMessage:(NSDictionary *)message { [messages addObject:message]; }
@end

@interface FixtureHelper : NSObject
- (NSDictionary *)startConversationAudioForCall:(TUCall *)call muted:(BOOL)muted preserveVideo:(BOOL)preserveVideo;
@end
@implementation FixtureHelper
- (NSDictionary *)startConversationAudioForCall:(TUCall *)call muted:(BOOL)muted preserveVideo:(BOOL)preserveVideo {
    audioActivations++;
    return @{};
}
@end

static BOOL IsVerifiedFaceTimeCall(TUCall *call) { return call.verifiedFaceTime; }
static NSDictionary *CallTransportEvidence(TUCall *call) { return @{ @"facetime": @(call.verifiedFaceTime) }; }
static void RunSetMuted(NSDictionary *data, NSString *transaction, FixtureController *controller, FixtureHelper *self) {
/* OPENCLAW_SET_MUTED_BODY */
}
static void Expect(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static void Reset(BOOL verified) {
    currentCall = [TUCall new];
    currentCall.verifiedFaceTime = verified;
    messages = [NSMutableArray array];
    audioActivations = 0;
}
static void SendJSON(NSString *json, NSString *transaction) {
    NSDictionary *data = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                                        options:0 error:NULL];
    RunSetMuted(data, transaction, [FixtureController new], [FixtureHelper new]);
}
static void ExpectNoAudioChanges(void) {
    Expect(currentCall.muteWrites == 0 && currentCall.uplinkWrites == 0 && audioActivations == 0,
           "rejected command must not change call or conversation audio");
}

int main(void) {
    @autoreleasepool {
        for (NSString *value in @[@"0", @"1", @"0.5", @"null", @"\"true\"", @"[]", @"{}", @""]) {
            for (id transaction in @[@"tx", [NSNull null]]) {
                Reset(YES);
                NSString *field = value.length ? [NSString stringWithFormat:@",\"muted\":%@", value] : @"";
                SendJSON([NSString stringWithFormat:@"{\"callUUID\":\"call-1\"%@}", field],
                         transaction == [NSNull null] ? nil : transaction);
                ExpectNoAudioChanges();
                Expect(transaction == [NSNull null] ? messages.count == 0 : messages.lastObject[@"error"] != nil,
                       "invalid muted value must return a command error when a reply was requested");
            }
        }
        for (NSNumber *muted in @[@YES, @NO]) {
            Reset(YES);
            SendJSON([NSString stringWithFormat:@"{\"callUUID\":\"call-1\",\"muted\":%@}", muted.boolValue ? @"true" : @"false"], @"tx");
            Expect(currentCall.muteWrites == 1 && currentCall.uplinkWrites == 1 && audioActivations == 1,
                   "valid JSON boolean must reach each audio operation once");
            Expect([currentCall isMuted] == muted.boolValue && [currentCall isUplinkMuted] == muted.boolValue,
                   "call audio must follow the requested boolean");
            Expect([messages.lastObject[@"outcome"] isEqual:muted.boolValue ? @"safe-muted" : @"media-configured"],
                   "successful reply must describe the requested audio state");
        }
        Reset(NO);
        SendJSON(@"{\"callUUID\":\"call-1\",\"muted\":false}", @"tx");
        ExpectNoAudioChanges();
        Expect(messages.lastObject[@"error"] != nil, "non-FaceTime unmute remains rejected");
        Reset(NO);
        SendJSON(@"{\"callUUID\":\"call-1\",\"muted\":true}", @"tx");
        Expect([currentCall isMuted], "safety muting remains available for an unverified call");
        Reset(YES);
        SendJSON(@"{\"callUUID\":\"absent\",\"muted\":true}", @"tx");
        ExpectNoAudioChanges();
        Expect([messages.lastObject[@"outcome"] isEqual:@"absent"], "absent call remains an explicit outcome");
        fputs("PASS: set-muted dispatch validates JSON before call audio effects\n", stderr);
    }
    return 0;
}
