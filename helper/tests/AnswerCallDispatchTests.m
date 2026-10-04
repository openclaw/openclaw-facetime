#import <Foundation/Foundation.h>
@interface TUConversation : NSObject
- (NSUUID *)UUID;
@end
@implementation TUConversation
- (NSUUID *)UUID { return nil; }
@end
@interface TUConversationManager : NSObject
- (void)setUplinkMuted:(BOOL)muted forPendingConversationWithUUID:(NSUUID *)uuid;
@end
@implementation TUConversationManager
- (void)setUplinkMuted:(BOOL)muted forPendingConversationWithUUID:(NSUUID *)uuid {}
@end
@interface TUCall : NSObject
@property int callStatus;
@property BOOL verifiedFaceTime;
@property(nonatomic) BOOL muted;
@property(nonatomic) BOOL uplinkMuted;
@property NSDate *dateEnded;
@property NSUInteger writes;
- (BOOL)isMuted;
- (BOOL)isUplinkMuted;
@end
@implementation TUCall
- (BOOL)isMuted { return _muted; }
- (BOOL)isUplinkMuted { return _uplinkMuted; }
- (void)setMuted:(BOOL)value { _muted=value; _writes++; }
- (void)setUplinkMuted:(BOOL)value { _uplinkMuted=value; _writes++; }
@end
static TUCall *currentCall;
static NSUInteger answers;
static NSMutableArray *messages;
@interface TUCallCenter : NSObject
+ (instancetype)sharedInstance;
- (TUCall *)callWithCallUUID:(NSString *)uuid;
- (TUConversation *)activeConversationForCall:(TUCall *)call;
- (void)answerOrJoinCall:(TUCall *)call;
@end
@implementation TUCallCenter
+ (instancetype)sharedInstance { static id center; if (!center) center=[self new]; return center; }
- (TUCall *)callWithCallUUID:(NSString *)uuid { return [uuid isEqual:@"call-1"] ? currentCall : nil; }
- (TUConversation *)activeConversationForCall:(TUCall *)call { return nil; }
- (void)answerOrJoinCall:(TUCall *)call { answers++; call.callStatus=1; }
@end
@interface FixtureController : NSObject
- (void)sendMessage:(NSDictionary *)message;
@end
@implementation FixtureController
- (void)sendMessage:(NSDictionary *)message { [messages addObject:message]; }
@end
static BOOL IsVerifiedFaceTimeCall(TUCall *call) { return call.verifiedFaceTime; }
static NSDictionary *CallTransportEvidence(TUCall *call) { return @{}; }
/* OPENCLAW_REQUIRED_CALL_UUID */
static void RunAnswer(NSDictionary *data, NSString *transaction, FixtureController *controller) {
/* OPENCLAW_ANSWER_BODY */
}
static void Expect(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr,"FAIL: %s\n",message); exit(1); }
}
static void Reset(int status, BOOL muted, BOOL uplink, BOOL verified, BOOL ended) {
    currentCall=[TUCall new]; currentCall.callStatus=status; currentCall.muted=muted;
    currentCall.uplinkMuted=uplink; currentCall.verifiedFaceTime=verified;
    currentCall.dateEnded=ended ? [NSDate date] : nil; currentCall.writes=0;
    answers=0; messages=[NSMutableArray array];
}
static void Answer(void) { RunAnswer(@{@"callUUID":@"call-1"}, @"tx", [FixtureController new]); }
int main(void) {
    @autoreleasepool {
        Reset(4,NO,NO,YES,NO); Answer();
        Expect(answers==1 && [messages.lastObject[@"outcome"] isEqual:@"answered-muted"],"first proxy answers muted");
        NSUInteger writes=currentCall.writes; Answer();
        Expect(answers==1 && currentCall.writes==writes,"second proxy does not answer or change audio twice");
        Expect([messages.lastObject[@"outcome"] isEqual:@"answered-muted"],"second proxy observes the first proxy's safe answer");
        for (NSArray *flags in @[@[@NO,@YES],@[@YES,@NO],@[@NO,@NO]]) {
            Reset(1,[flags[0] boolValue],[flags[1] boolValue],YES,NO); Answer();
            Expect(messages.lastObject[@"error"] != nil && answers==0 && currentCall.writes==0,"active call must already have both mute flags");
        }
        for (NSNumber *status in @[@0,@2,@3,@5,@99]) {
            Reset(status.intValue,YES,YES,YES,NO); Answer();
            Expect(messages.lastObject[@"error"] != nil && answers==0 && currentCall.writes==0,"unknown or transitional status stays rejected");
        }
        for (NSNumber *status in @[@1,@4]) {
            Reset(status.intValue,YES,YES,NO,NO); Answer();
            Expect(messages.lastObject[@"error"] != nil && answers==0 && currentCall.writes==0,"unverified transport stays rejected");
            Reset(status.intValue,YES,YES,YES,YES); Answer();
            Expect(messages.lastObject[@"error"] != nil && answers==0 && currentCall.writes==0,"ended call must not be answered or acknowledged active");
        }
        Reset(4,NO,NO,YES,NO);
        RunAnswer(@{@"callUUID":@"other"}, @"tx", [FixtureController new]);
        Expect([messages.lastObject[@"outcome"] isEqual:@"absent"] && answers==0 && currentCall.writes==0,"exact UUID required");
        fprintf(stderr,"PASS: shared answer dispatch preserves muted idempotence\n");
    }
    return 0;
}
