#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#define DLog(...) do {} while (0)

@interface TUDialRequest : NSObject
@property BOOL video;
@property BOOL showUIPrompt;
@property(readonly,getter=isValid) BOOL valid;
@property(readonly) NSArray *validityErrors;
- (instancetype)initWithURL:(NSURL *)URL;
@end
@implementation TUDialRequest
- (instancetype)initWithURL:(NSURL *)URL { return [super init]; }
- (BOOL)isValid { return YES; }
- (NSArray *)validityErrors { return @[]; }
@end

@interface TUCall : NSObject
@property NSString *callUUID;
@property NSString *uniqueProxyIdentifier;
- (BOOL)isMuted;
- (BOOL)isUplinkMuted;
@end
@implementation TUCall
- (BOOL)isMuted { return YES; }
- (BOOL)isUplinkMuted { return YES; }
@end

static TUCall *createdCall;
static TUCall *stableCallFixture;
static NSUInteger muteChecks;
static NSUInteger muteFailureIndex;
static NSUInteger disconnectedCalls;
static NSMutableDictionary *OutboundCallsByDialID;
static dispatch_block_t delayed;
static NSMutableArray *messages;

@interface TUCallCenter : NSObject
+ (instancetype)sharedInstance;
- (NSArray *)currentCalls;
- (BOOL)canDialWithRequest:(TUDialRequest *)request;
- (TUCall *)dialWithRequest:(TUDialRequest *)request;
- (void)disconnectCall:(TUCall *)call;
@end
@implementation TUCallCenter
+ (instancetype)sharedInstance { static TUCallCenter *center; if (!center) center = [self new]; return center; }
- (NSArray *)currentCalls { return @[]; }
- (BOOL)canDialWithRequest:(TUDialRequest *)request { return YES; }
- (TUCall *)dialWithRequest:(TUDialRequest *)request { return createdCall; }
- (void)disconnectCall:(TUCall *)call { disconnectedCalls += 1; }
@end

@interface FixtureController : NSObject
- (void)sendMessage:(NSDictionary *)message;
@end
@implementation FixtureController
- (void)sendMessage:(NSDictionary *)message { [messages addObject:message]; }
@end
@interface FixtureHelper : NSObject
- (void)emitCallStatus:(TUCall *)call;
@end
@implementation FixtureHelper
- (void)emitCallStatus:(TUCall *)call {}
@end

static BOOL ApplyOutboundSafetyMute(TUCall *call) { muteChecks += 1; return muteChecks != muteFailureIndex; }
static NSDictionary *CallTransportEvidence(TUCall *call) { return @{@"kind": @"facetime"}; }
static TUCall *LiveOutboundCall(NSString *dialID, NSString *uuid, NSString *proxy) {
    return stableCallFixture;
}
static void fake_dispatch_after(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) { delayed = [block copy]; }
#define dispatch_after fake_dispatch_after
static void RunStartCall(NSDictionary *data, NSString *transaction, FixtureController *controller, FixtureHelper *self) {
/* OPENCLAW_START_CALL_BODY */
}
static void Expect(BOOL value, const char *message) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static TUCall *Call(NSString *identifier) {
    TUCall *call = [TUCall new];
    call.callUUID = identifier;
    call.uniqueProxyIdentifier = [@"proxy-" stringByAppendingString:identifier];
    return call;
}
int main(void) {
    @autoreleasepool {
        for (NSUInteger failureIndex = 1; failureIndex <= 2; failureIndex++) {
            createdCall = Call(@"initial-call");
            stableCallFixture = Call(@"stable-call");
            muteChecks = 0;
            muteFailureIndex = failureIndex;
            disconnectedCalls = 0;
            OutboundCallsByDialID = [NSMutableDictionary dictionary];
            messages = [NSMutableArray array];
            delayed = nil;
            RunStartCall(@{@"handle": @"owner@example.com", @"mode": @"audio", @"dialID": @"approved-dial"},
                         @"tx", [FixtureController new], [FixtureHelper new]);
            if (delayed) delayed();
            Expect([messages.firstObject[@"event"] isEqual:@"ft-outbound-call-identified"],
                   "created carrier identity must be published before safety postconditions");
            NSDictionary *failure = messages.lastObject;
            Expect([failure[@"ambiguous"] isEqual:@YES], "post-dial failure must remain ambiguous");
            Expect([failure[@"dial_id"] isEqual:@"approved-dial"], "failure retains the exact approved dial");
            NSString *expected = failureIndex == 1 ? @"initial-call" : @"stable-call";
            Expect([failure[@"call_uuid"] isEqual:expected], "failure carries Apple's current call UUID");
            Expect([failure[@"proxy_identifier"] isEqual:[@"proxy-" stringByAppendingString:expected]],
                   "failure carries Apple's current proxy identity");
            Expect(OutboundCallsByDialID[@"approved-dial"] == (failureIndex == 1 ? createdCall : stableCallFixture),
                   "failed call retains the current carrier for reconciliation");
            Expect(disconnectedCalls == 1, "unsafe carrier receives a disconnect request");
        }
        fprintf(stderr, "PASS: initial and delayed native safety failures preserve reconciliation identity\n");
    }
    return 0;
}
