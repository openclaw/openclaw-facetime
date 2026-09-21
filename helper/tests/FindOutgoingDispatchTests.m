#import <Foundation/Foundation.h>

@interface TUCall : NSObject
@property NSString *callUUID;
@property NSString *uniqueProxyIdentifier;
@property TUCall *comparativeCall;
@property(getter=isOutgoing) BOOL outgoing;
@property BOOL verifiedFaceTime;
@property BOOL acceptsSafetyMute;
@end
@implementation TUCall
@end

static NSArray *liveCalls;
static NSMutableDictionary *OutboundCallsByDialID;
static NSMutableSet *cancelledDials;
static NSMutableArray *messages;
static NSMutableArray *disconnectedCalls;
static NSUInteger muteAttempts;

@interface TUCallCenter : NSObject
+ (instancetype)sharedInstance;
- (NSArray *)currentCalls;
- (NSArray *)currentAudioAndVideoCalls;
- (NSArray *)displayedCalls;
- (NSArray *)displayedAudioAndVideoCalls;
- (NSArray *)incomingCalls;
- (TUCall *)incomingCall;
- (TUCall *)incomingVideoCall;
- (void)disconnectCall:(TUCall *)call;
@end
@implementation TUCallCenter
+ (instancetype)sharedInstance { static id center; if (!center) center = [self new]; return center; }
- (NSArray *)currentCalls { return liveCalls; }
- (NSArray *)currentAudioAndVideoCalls { return liveCalls; }
- (NSArray *)displayedCalls { return @[]; }
- (NSArray *)displayedAudioAndVideoCalls { return @[]; }
- (NSArray *)incomingCalls { return @[]; }
- (TUCall *)incomingCall { return nil; }
- (TUCall *)incomingVideoCall { return nil; }
- (void)disconnectCall:(TUCall *)call { [disconnectedCalls addObject:call]; }
@end

@interface FixtureController : NSObject
- (void)sendMessage:(NSDictionary *)message;
@end
@implementation FixtureController
- (void)sendMessage:(NSDictionary *)message { [messages addObject:message]; }
@end

static BOOL IsVerifiedFaceTimeCall(TUCall *call) { return call.verifiedFaceTime; }
static BOOL ApplyOutboundSafetyMute(TUCall *call) {
    muteAttempts++;
    return call.verifiedFaceTime && call.acceptsSafetyMute;
}
static void ArmOutboundCancellation(NSString *dialID) { [cancelledDials addObject:dialID]; }
/* OPENCLAW_OUTBOUND_LOOKUP */
static void RunFind(NSDictionary *data, NSString *transaction, FixtureController *controller) {
/* OPENCLAW_FIND_OUTGOING_BODY */
}
static void RunCancel(NSDictionary *data, NSString *transaction, FixtureController *controller) {
/* OPENCLAW_CANCEL_OUTGOING_BODY */
}
static void Expect(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static TUCall *Call(NSString *identifier, BOOL verified) {
    TUCall *call = [TUCall new];
    call.callUUID = identifier;
    call.uniqueProxyIdentifier = [@"proxy-" stringByAppendingString:identifier];
    call.outgoing = YES;
    call.verifiedFaceTime = verified;
    call.acceptsSafetyMute = YES;
    return call;
}
static void Reset(TUCall *call) {
    liveCalls = call ? @[call] : @[];
    OutboundCallsByDialID = [NSMutableDictionary dictionary];
    cancelledDials = [NSMutableSet set];
    messages = [NSMutableArray array];
    disconnectedCalls = [NSMutableArray array];
    muteAttempts = 0;
}
static void Find(NSDictionary *data) { RunFind(data, @"tx", [FixtureController new]); }
static void ExpectNoAudioChanges(void) {
    Expect(muteAttempts == 0 && disconnectedCalls.count == 0, "lookup must not touch non-FaceTime audio");
}

int main(void) {
    @autoreleasepool {
        for (NSString *key in @[@"callUUID", @"proxyIdentifier"]) {
            for (NSNumber *preexisting in @[@NO, @YES]) {
                TUCall *cellular = Call(@"cellular", NO);
                TUCall *retained = Call(@"retained", YES);
                Reset(cellular);
                if (preexisting.boolValue) OutboundCallsByDialID[@"dial"] = retained;
                NSDictionary *query = @{@"dialID": @"dial", key: [key isEqual:@"callUUID"] ? cellular.callUUID : cellular.uniqueProxyIdentifier};
                Find(query);
                Find(query);
                ExpectNoAudioChanges();
                Expect(![messages.lastObject[@"found"] boolValue], "non-FaceTime lookup must report absent");
                Expect(OutboundCallsByDialID[@"dial"] == (preexisting.boolValue ? retained : nil),
                       "rejected transport must not create or overwrite retained ownership");
                Expect(RetainedDialIDForOutboundCall(cellular) == nil, "rejected call must not inherit a dial ID");
                Expect([messages.lastObject[@"retained_outbound_dial"] boolValue] == preexisting.boolValue,
                       "lookup must report only the real retained owner");
            }
        }
        TUCall *call = Call(@"facetime", YES);
        Reset(call);
        Find(@{@"dialID": @"dial", @"callUUID": call.callUUID});
        Expect([messages.lastObject[@"found"] boolValue] && muteAttempts == 1 && disconnectedCalls.count == 0,
               "verified FaceTime lookup must apply safety mute and remain found");
        Expect(OutboundCallsByDialID[@"dial"] == call && [messages.lastObject[@"retained_outbound_dial"] boolValue],
               "successful lookup must report its newly retained owner");
        call.acceptsSafetyMute = NO;
        Reset(call);
        Find(@{@"dialID": @"dial", @"callUUID": call.callUUID});
        Expect(![messages.lastObject[@"found"] boolValue] && disconnectedCalls.count == 1,
               "a FaceTime carrier that loses safety mute must receive disconnect");
        Expect(OutboundCallsByDialID[@"dial"] == call && [messages.lastObject[@"retained_outbound_dial"] boolValue],
               "failed FaceTime postcondition must retain reconciliation ownership");
        TUCall *successor = Call(@"successor", YES);
        successor.comparativeCall = call;
        Reset(successor);
        OutboundCallsByDialID[@"dial"] = call;
        Find(@{@"dialID": @"dial"});
        Expect(OutboundCallsByDialID[@"dial"] == successor, "Apple-linked replacement must update the owned carrier");
        Reset(nil);
        Find(@{@"dialID": @"dial"});
        ExpectNoAudioChanges();
        Expect(![messages.lastObject[@"found"] boolValue], "missing carrier must report absent");
        TUCall *explicitCarrier = Call(@"explicit", NO);
        Reset(explicitCarrier);
        RunCancel(@{@"dialID": @"dial", @"callUUID": explicitCarrier.callUUID}, @"tx", [FixtureController new]);
        Expect(disconnectedCalls.count == 1 && OutboundCallsByDialID[@"dial"] == explicitCarrier,
               "explicit exact-carrier cancellation keeps its existing ownership contract");
        Expect([cancelledDials containsObject:@"dial"], "exact-carrier cancellation remains armed");
        fputs("PASS: outgoing dispatch preserves transport and retained-owner boundaries\n", stderr);
    }
    return 0;
}
