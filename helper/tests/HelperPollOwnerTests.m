#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

@interface TUCallCenter : NSObject
+ (instancetype)sharedInstance;
@end

@interface Helper : NSObject
@property NSUInteger polls;
@property NSUInteger notifications;
- (void)startCallStatusPolling;
- (void)openclaw_stopHelperPolling;
- (void)pollCallStatuses;
- (void)callStatusChanged:(NSNotification *)notification;
- (void)emitCallStatus:(id)call;
@end

#ifdef HELPER_IMAGE
static NSArray *AllKnownCalls(void) { return @[[NSUUID UUID]]; }
// Supply a stable synthetic call UUID to the production polling loop.
@interface NSUUID (FixtureCall)
- (NSString *)callUUID;
@end
@implementation NSUUID (FixtureCall)
- (NSString *)callUUID { return @"synthetic-call"; }
@end
@implementation Helper
/* OPENCLAW_POLL_LIFECYCLE */
/* OPENCLAW_POLL_METHOD */
- (void)emitCallStatus:(id)call { self.polls++; }
- (void)callStatusChanged:(NSNotification *)notification { self.notifications++; }
@end
#else
@implementation TUCallCenter
+ (instancetype)sharedInstance { static id center; if (!center) center = [self new]; return center; }
@end
static void Expect(BOOL value, const char *message) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static void AdvancePoll(void) {
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.1]];
}
static void Notify(void) {
    for (NSString *name in @[@"TUCallCenterVideoCallStatusChangedNotification", @"TUCallCenterCallStatusChangedNotification"]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:name object:nil];
    }
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        Expect(argc == 3, "two independent helper images are required");
        Expect(dlopen(argv[1], RTLD_NOW | RTLD_LOCAL) != NULL, "first helper image must load");
        Helper *previous = [NSClassFromString(@"HelperA") new];
        [previous startCallStatusPolling];
        AdvancePoll();
        Expect(previous.polls >= 2, "initial helper must schedule recurring polls");
        Notify();
        Expect(previous.notifications == 2, "initial helper must observe both notification types");
        Expect(dlopen(argv[2], RTLD_NOW | RTLD_LOCAL) != NULL, "replacement helper image must load");
        Helper *current = [NSClassFromString(@"HelperB") new];
        [current startCallStatusPolling];
        NSUInteger previousPolls = previous.polls;
        AdvancePoll();
        Expect(previous.polls == previousPolls, "replacement must stop the previous image's scheduled polls");
        Expect(current.polls >= 2, "replacement must keep polling");
        Notify();
        Expect(previous.notifications == 2 && current.notifications == 2, "only the replacement may receive notifications");
        NSUInteger currentPolls = current.polls;
        [current startCallStatusPolling];
        Expect(current.polls == currentPolls, "same-instance initialization must not start another poll chain");
        Notify();
        Expect(current.notifications == 4, "same-instance initialization must not duplicate observers");
        [current openclaw_stopHelperPolling];
        AdvancePoll();
        Expect(current.polls == currentPolls, "explicit stop must cancel the remaining poll chain");
        [previous startCallStatusPolling];
        Expect(previous.polls == previousPolls + 1, "a stopped helper may reclaim ownership");
        [previous openclaw_stopHelperPolling];
        [previous startCallStatusPolling];
        NSUInteger restartedPolls = previous.polls;
        AdvancePoll();
        Expect(previous.polls == restartedPolls + 1, "restart must not revive the previous generation's queued callback");
        Notify();
        Expect(previous.notifications == 4 && current.notifications == 4, "reclaimed ownership must restore exactly one observer set");
        [previous openclaw_stopHelperPolling];
        fputs("PASS: independent helper images transfer polling and observer ownership\n", stderr);
    }
    return 0;
}
#endif
