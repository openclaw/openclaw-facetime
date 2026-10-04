#import <Foundation/Foundation.h>
@interface TUCall : NSObject
@property NSString *callUUID;
@property int callStatus;
@property NSDate *dateEnded;
@end
@implementation TUCall
@end
static NSDictionary *calls;
static NSMutableArray *messages;
@interface TUCallCenter : NSObject
+ (instancetype)sharedInstance;
- (TUCall *)callWithCallUUID:(NSString *)uuid;
@end
@implementation TUCallCenter
+ (instancetype)sharedInstance { static id center; if (!center) center=[self new]; return center; }
- (TUCall *)callWithCallUUID:(NSString *)uuid { return calls[uuid]; }
@end
@interface FixtureController : NSObject
- (void)sendMessage:(NSDictionary *)message;
@end
@implementation FixtureController
- (void)sendMessage:(NSDictionary *)message { [messages addObject:message]; }
@end
static void RunInspect(NSDictionary *data, NSString *transaction, FixtureController *controller) {
/* OPENCLAW_INSPECT_BODY */
}
static void Expect(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr,"FAIL: %s\n",message); exit(1); }
}
static TUCall *Call(NSString *uuid, BOOL ended, int status) {
    TUCall *call=[TUCall new]; call.callUUID=uuid; call.callStatus=status;
    call.dateEnded=ended ? [NSDate date] : nil; return call;
}
static NSDictionary *Inspect(NSArray *aliases) {
    messages=[NSMutableArray array];
    RunInspect(@{@"callUUIDs":aliases},@"tx",[FixtureController new]);
    return messages.lastObject;
}
int main(void) {
    @autoreleasepool {
        calls=@{@"old":Call(@"old",YES,6),@"new":Call(@"new",NO,1)};
        for(NSArray *aliases in @[@[@"old",@"new"],@[@"new",@"old"]]) {
            NSDictionary *result=Inspect(aliases);
            Expect([result[@"outcome"] isEqual:@"present"] && [result[@"call_uuid"] isEqual:@"new"],"ended alias must not hide a live replacement");
            Expect([result[@"found"] boolValue] && ![result[@"has_ended"] boolValue],"live replacement forbids terminal proof");
        }
        calls=@{@"old":Call(@"old",YES,6)};
        NSDictionary *result=Inspect(@[@"old",@"gone"]);
        Expect([result[@"outcome"] isEqual:@"absent"] && ![result[@"found"] boolValue],"retained terminal call is not a live carrier");
        Expect([result[@"has_ended"] boolValue] && [result[@"ended_call_count"] intValue]==1,"terminal result carries dateEnded evidence");
        calls=@{@"unknown":Call(@"unknown",NO,99)};
        result=Inspect(@[@"unknown"]);
        Expect([result[@"outcome"] isEqual:@"present"],"unknown status without dateEnded stays live for closure");
        calls=@{}; result=Inspect(@[@"gone"]);
        Expect([result[@"outcome"] isEqual:@"absent"] && ![result[@"has_ended"] boolValue],"missing carrier is absent without invented terminal evidence");
        fprintf(stderr,"PASS: inspect dispatch checks live replacements and terminal evidence\n");
    }
    return 0;
}
