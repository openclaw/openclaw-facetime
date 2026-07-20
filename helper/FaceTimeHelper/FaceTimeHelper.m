@import AppKit;

#import <Foundation/Foundation.h>

#import "NetworkController.h"
#import "Logging.h"
#import "ZKSwizzle.h"
#import "TUConversationManager.h"
#import "TUConversationLink.h"
#import "TUConversationManagerXPCClient.h"
#import "TUProxyCall.h"
#import "TUAnswerRequest.h"
#import "TUCallCenter.h"
#import "TUConversation.h"
#import "TUConversationJoinRequest.h"
#import "TUConversationMember.h"
#import "CSDConversation.h"
#import "CSDConversationManager.h"
#import "TUCall.h"

@interface FACETIMEHELPER : NSObject
+ (instancetype)sharedInstance;
@end

// This can be used to dump the methods of any class
@interface NSObject (Private)
- (NSString*)_methodDescription;
@end

FACETIMEHELPER *plugin;

@implementation FACETIMEHELPER

// FACETIMEHELPER is a singleton
+ (instancetype)sharedInstance {
    static FACETIMEHELPER *plugin = nil;
    @synchronized(self) {
        if (!plugin) {
            plugin = [[self alloc] init];
        }
    }
    return plugin;
}

// Helper method to log a long string
-(void) logString:(NSString*)logString{

        int stepLog = 800;
        NSInteger strLen = [@([logString length]) integerValue];
        NSInteger countInt = strLen / stepLog;

        if (strLen > stepLog) {
        for (int i=1; i <= countInt; i++) {
            NSString *character = [logString substringWithRange:NSMakeRange((i*stepLog)-stepLog, stepLog)];
            DLog("FACETIMEHELPER: %{public}@", character);

        }
        NSString *character = [logString substringWithRange:NSMakeRange((countInt*stepLog), strLen-(countInt*stepLog))];
            DLog("FACETIMEHELPER: %{public}@", character);
        } else {

            DLog("FACETIMEHELPER: %{public}@", logString);
        }

}

// Called when macforge initializes the plugin
+ (void)load {
    // Create the singleton
    plugin = [FACETIMEHELPER sharedInstance];

    // Get OS version for debugging purposes
    NSUInteger major = [[NSProcessInfo processInfo] operatingSystemVersion].majorVersion;
    NSUInteger minor = [[NSProcessInfo processInfo] operatingSystemVersion].minorVersion;
    DLog("FACETIMEHELPER: %{public}@ loaded into %{public}@ on macOS %ld.%ld", [self className], [[NSBundle mainBundle] bundleIdentifier], (long)major, (long)minor);

    NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleIdentifier isEqualToString:@"com.apple.FaceTime"] || [bundleIdentifier isEqualToString:@"com.apple.FaceTime.FTConversationService"] || [bundleIdentifier isEqualToString:@"com.apple.TelephonyUtilities"]) {
        DLog("FACETIMEHELPER: Initializing Connection...");
        [plugin initializeNetworkController];
    } else {
        DLog("FACETIMEHELPER: Injected into non-FaceTime process %@, aborting.", bundleIdentifier);
        return;
    }
}

-(void) DumpObjcMethods:(Class) clz {

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(clz, &methodCount);

    DLog("FACETIMEHELPER: Found %d methods on '%s'\n", methodCount, class_getName(clz));

    for (unsigned int i = 0; i < methodCount; i++) {
        Method method = methods[i];

        DLog("\tFACETIMEHELPER: '%s' has method named '%s' of encoding '%s'\n",
               class_getName(clz),
               sel_getName(method_getName(method)),
               method_getTypeEncoding(method));
    }

    free(methods);
}

// Private method to initialize all the things required by the plugin to communicate with the main
// server over a tcp socket
-(void) initializeNetworkController {
    // Get the network controller
    NetworkController *controller = [NetworkController sharedInstance];
    [controller connect];

    // Upon receiving a message
    controller.messageReceivedBlock =  ^(NetworkController *controller, NSString *data) {
        [self handleMessage:controller message: data];
    };
    NSDictionary *message = @{@"event": @"ping", @"message": @"Helper Connected!"};
    [controller sendMessage:message];

    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC));
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        DLog("FACETIMEHELPER: Registering call listeners...");

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(callStatusChanged:) name:@"TUCallCenterVideoCallStatusChangedNotification" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(callStatusChanged:) name:@"TUCallCenterCallStatusChangedNotification" object:nil];
        [self pollCallStatuses];
        
        // [self handleMessage:controller message:@"{\"action\":\"invalidate-link\",\"transactionId\":\"bruh\",\"data\":{\"url\":\"https://facetime.apple.com/join#v=1&p=5rYoTVvAEe6LSjJziwUUiw&k=h9yNjziqokL3lLK-JEq-1_uae-KCvqKvayGsrkdNmGg\"}}"];
    });
}

-(void) emitCallStatus:(id)call {
    if (call == nil || ![call respondsToSelector:@selector(callUUID)] || ![call respondsToSelector:@selector(callStatus)]) {
        return;
    }
    TUConversation *conversation = [[TUCallCenter sharedInstance] activeConversationForCall:call];
    NSDictionary *data = @{
        @"audio_mode": [call audioMode] ?: [NSNull null],
        @"call_status": [NSNumber numberWithInt:[call callStatus]] ?: [NSNull null],
        @"call_uuid": [call callUUID] ?: [NSNull null],
        @"conversation_uuid": [[conversation UUID] UUIDString] ?: [NSNull null],
        @"conversation_group_uuid": [[conversation groupUUID] UUIDString] ?: [NSNull null],
        @"conversation_audio_enabled": [NSNumber numberWithBool:[conversation isAudioEnabled]] ?: [NSNull null],
        @"conversation_video_enabled": [NSNumber numberWithBool:[conversation isVideoEnabled]] ?: [NSNull null],
        @"conversation_av_mode": [NSNumber numberWithUnsignedInteger:[conversation avMode]] ?: [NSNull null],
        @"conversation_resolved_audio_video_mode": [NSNumber numberWithUnsignedInteger:[conversation resolvedAudioVideoMode]] ?: [NSNull null],
        @"is_conversation": [NSNumber numberWithBool:[call isConversation]] ?: [NSNull null],
        @"disconnected_reason": [NSNumber numberWithInt:[call disconnectedReason]] ?: [NSNull null],
        @"ended_error": [call endedErrorString] ?: [NSNull null],
        @"ended_reason": [call endedReasonString] ?: [NSNull null],
        @"handle": [[call handle] dictionaryRepresentation] ?: [NSNull null],
        @"is_sending_audio": [NSNumber numberWithBool:[call isSendingAudio]] ?: [NSNull null],
        @"is_sending_transmission": [NSNumber numberWithBool:[call isSendingTransmission]] ?: [NSNull null],
        @"is_sending_video": [NSNumber numberWithBool:[call isSendingVideo]] ?: [NSNull null],
        @"is_uplink_muted": [NSNumber numberWithBool:[call isUplinkMuted]] ?: [NSNull null],
        @"is_outgoing": [NSNumber numberWithBool:[call isOutgoing]] ?: [NSNull null],
        @"local_meter_level": [NSNumber numberWithFloat:[call localMeterLevel]] ?: [NSNull null],
        @"remote_meter_level": [NSNumber numberWithFloat:[call remoteMeterLevel]] ?: [NSNull null],
    };
    NSDictionary *message = @{@"event": @"ft-call-status-changed", @"data": data};
    [[NetworkController sharedInstance] sendMessage: message];
}

-(NSDictionary*) startConversationAudioForCall:(TUCall*)call muted:(BOOL)muted preserveVideo:(BOOL)preserveVideo {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    TUConversation *conversation = [[TUCallCenter sharedInstance] activeConversationForCall:call];
    NSUUID *conversationUUID = [conversation UUID];
    BOOL videoActive = preserveVideo || [conversation isVideoEnabled] || [call isSendingVideo];
    result[@"conversation_uuid"] = [conversationUUID UUIDString] ?: [NSNull null];
    result[@"conversation_group_uuid"] = [[conversation groupUUID] UUIDString] ?: [NSNull null];
    
    if (conversationUUID == nil) {
        result[@"conversation_audio_started"] = @NO;
        result[@"conversation_audio_error"] = @"No active conversation UUID";
        return result;
    }
    
    Class conversationManagerClass = NSClassFromString(@"CSDConversationManager");
    id conversationManager = [[conversationManagerClass alloc] init];
    BOOL didSetUplinkMuted = NO;
    BOOL didSetPendingUplinkMuted = NO;
    BOOL didSetAudioPaused = NO;
    BOOL didStartAudio = NO;
    BOOL didSetConversationAudioEnabled = NO;
    BOOL didSetConversationAVMode = NO;
    BOOL didSetLocalParticipantMode = NO;
    BOOL didSetLocalParticipantModeViaXPC = NO;
    BOOL didSetSendingAudio = NO;
    
    if ([conversation respondsToSelector:@selector(setAudioEnabled:)]) {
        [conversation setAudioEnabled:!muted];
        didSetConversationAudioEnabled = YES;
    }
    if (!muted && !videoActive && [conversation respondsToSelector:@selector(setAvMode:)]) {
        [conversation setAvMode:1];
        didSetConversationAVMode = YES;
    }
    
    if ([conversationManager respondsToSelector:@selector(setUplinkMuted:forConversationWithUUID:)]) {
        void (*setUplinkMuted)(id, SEL, BOOL, id) = (void (*)(id, SEL, BOOL, id))[conversationManager methodForSelector:@selector(setUplinkMuted:forConversationWithUUID:)];
        setUplinkMuted(conversationManager, @selector(setUplinkMuted:forConversationWithUUID:), muted, conversationUUID);
        didSetUplinkMuted = YES;
    }
    if ([conversationManager respondsToSelector:@selector(setUplinkMuted:forPendingConversationWithUUID:)]) {
        void (*setPendingUplinkMuted)(id, SEL, BOOL, id) = (void (*)(id, SEL, BOOL, id))[conversationManager methodForSelector:@selector(setUplinkMuted:forPendingConversationWithUUID:)];
        setPendingUplinkMuted(conversationManager, @selector(setUplinkMuted:forPendingConversationWithUUID:), muted, conversationUUID);
        didSetPendingUplinkMuted = YES;
    }
    if (!muted && [conversationManager respondsToSelector:@selector(setAudioPaused:forConversationWithUUID:)]) {
        void (*setAudioPaused)(id, SEL, BOOL, id) = (void (*)(id, SEL, BOOL, id))[conversationManager methodForSelector:@selector(setAudioPaused:forConversationWithUUID:)];
        setAudioPaused(conversationManager, @selector(setAudioPaused:forConversationWithUUID:), NO, conversationUUID);
        didSetAudioPaused = YES;
    }
    if (!muted && [conversationManager respondsToSelector:@selector(startAudioForConversationWithUUID:)]) {
        void (*startAudio)(id, SEL, id) = (void (*)(id, SEL, id))[conversationManager methodForSelector:@selector(startAudioForConversationWithUUID:)];
        startAudio(conversationManager, @selector(startAudioForConversationWithUUID:), conversationUUID);
        didStartAudio = YES;
    }
    if (!muted) {
        if ([call respondsToSelector:@selector(setIsSendingAudio:)]) {
            ((void (*)(id, SEL, BOOL))[call methodForSelector:@selector(setIsSendingAudio:)])(
                call,
                @selector(setIsSendingAudio:),
                YES
            );
            didSetSendingAudio = YES;
        }
        // Mode 1 is the helper's audio-only fallback. Preserve an existing
        // FaceTime video mode while changing only the call's audio route.
        if (!videoActive) {
            TUConversationManager *tuConversationManager = [[TUConversationManager alloc] init];
            if ([tuConversationManager respondsToSelector:@selector(setLocalParticipantAudioVideoMode:forConversationUUID:)]) {
                [tuConversationManager setLocalParticipantAudioVideoMode:1 forConversationUUID:conversationUUID];
                didSetLocalParticipantMode = YES;
            }
            TUConversationManagerXPCClient *xpcClient = [[TUConversationManagerXPCClient alloc] init];
            if ([xpcClient respondsToSelector:@selector(setLocalParticipantAudioVideoMode:forConversationUUID:)]) {
                [xpcClient setLocalParticipantAudioVideoMode:1 forConversationUUID:conversationUUID];
                didSetLocalParticipantModeViaXPC = YES;
            }
        }
    }
    
    result[@"conversation_audio_enabled"] = [NSNumber numberWithBool:[conversation isAudioEnabled]];
    result[@"conversation_video_enabled"] = [NSNumber numberWithBool:[conversation isVideoEnabled]];
    result[@"conversation_av_mode"] = [NSNumber numberWithUnsignedInteger:[conversation avMode]];
    result[@"conversation_resolved_audio_video_mode"] = [NSNumber numberWithUnsignedInteger:[conversation resolvedAudioVideoMode]];
    result[@"conversation_audio_enabled_set"] = [NSNumber numberWithBool:didSetConversationAudioEnabled];
    result[@"conversation_av_mode_set"] = [NSNumber numberWithBool:didSetConversationAVMode];
    result[@"conversation_uplink_muted_set"] = [NSNumber numberWithBool:didSetUplinkMuted];
    result[@"pending_conversation_uplink_muted_set"] = [NSNumber numberWithBool:didSetPendingUplinkMuted];
    result[@"conversation_audio_paused_cleared"] = [NSNumber numberWithBool:didSetAudioPaused];
    result[@"conversation_audio_started"] = [NSNumber numberWithBool:didStartAudio];
    result[@"local_participant_audio_video_mode_set"] = [NSNumber numberWithBool:didSetLocalParticipantMode];
    result[@"local_participant_audio_video_mode_xpc_set"] = [NSNumber numberWithBool:didSetLocalParticipantModeViaXPC];
    result[@"is_sending_audio_set"] = [NSNumber numberWithBool:didSetSendingAudio];
    return result;
}

-(void) pollCallStatuses {
    TUCallCenter *callCenter = [TUCallCenter sharedInstance];
    NSMutableDictionary *callsByUUID = [NSMutableDictionary dictionary];
    NSArray *callLists = @[
        [callCenter currentCalls] ?: @[],
        [callCenter incomingCalls] ?: @[],
    ];
    for (NSArray *callList in callLists) {
        for (id call in callList) {
            if ([call respondsToSelector:@selector(callUUID)] && [call callUUID] != nil) {
                callsByUUID[[call callUUID]] = call;
            }
        }
    }
    id incomingCall = [callCenter incomingCall];
    if (incomingCall != nil && [incomingCall respondsToSelector:@selector(callUUID)] && [incomingCall callUUID] != nil) {
        callsByUUID[[incomingCall callUUID]] = incomingCall;
    }
    id incomingVideoCall = [callCenter incomingVideoCall];
    if (incomingVideoCall != nil && [incomingVideoCall respondsToSelector:@selector(callUUID)] && [incomingVideoCall callUUID] != nil) {
        callsByUUID[[incomingVideoCall callUUID]] = incomingVideoCall;
    }
    for (id callUUID in callsByUUID) {
        [self emitCallStatus:callsByUUID[callUUID]];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^(void){
        [self pollCallStatuses];
    });
}

-(void) callStatusChanged: (NSNotification *)notification {
    [self emitCallStatus:[notification object]];
}

// Run when receiving a new message from the tcp socket
-(void) handleMessage: (NetworkController*)controller  message:(NSString *)message {
    // The data is in the form of a json string, so we need to convert it to a NSDictionary
    // for some reason the data is sometimes duplicated, so account for that
    NSRange range = [message rangeOfString:@"}\n{"];
    if(range.location != NSNotFound) {
        message = [message substringWithRange:NSMakeRange(0, range.location + 1)];
    }
    DLog("FACETIMEHELPER: Received raw json: %{public}@", message);
    NSError *error;
    NSData *jsonData = [message dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *dictionary = [NSJSONSerialization JSONObjectWithData:jsonData options:kNilOptions error:&error];

    // Event is the type of packet that was sent
    NSString *event = dictionary[@"action"];
    // Data is the actual information that we need in the packet
    NSDictionary *data = dictionary[@"data"];
    // Transaction ID enables us to communicate back to the server that the action was complete
    NSString *transaction = nil;
    if ([dictionary objectForKey:(@"transactionId")] != [NSNull null]) {
        transaction = dictionary[@"transactionId"];
    }

    DLog("FACETIMEHELPER: Message received: %{public}@, %{public}@", event, data);
    
    if ([event isEqualToString:@"answer-call"]) {
        TUCall *call = [[TUCallCenter sharedInstance] callWithCallUUID:(data[@"callUUID"])];
        
        if ([call callStatus] != 4) {
            if (transaction != nil) {
                [controller sendMessage: @{@"transactionId": transaction, @"error": @"Call is not waiting to be answered!"}];
            }
            return;
        }
        
        // Keep the uplink closed until the Node bridge verifies that this exact
        // call process is using OpenClaw-Mic. This prevents a physical-mic leak
        // during the short interval between answer and Core Audio route setup.
        [call setMuted:YES];
        [call setUplinkMuted:YES];
        TUConversation *conversation = [[TUCallCenter sharedInstance] activeConversationForCall:call];
        NSUUID *conversationUUID = [conversation UUID];
        if (conversationUUID != nil) {
            TUConversationManager *conversationManager = [[TUConversationManager alloc] init];
            if ([conversationManager respondsToSelector:@selector(setUplinkMuted:forPendingConversationWithUUID:)]) {
                void (*setPendingUplinkMuted)(id, SEL, BOOL, id) = (void (*)(id, SEL, BOOL, id))[conversationManager methodForSelector:@selector(setUplinkMuted:forPendingConversationWithUUID:)];
                setPendingUplinkMuted(conversationManager, @selector(setUplinkMuted:forPendingConversationWithUUID:), YES, conversationUUID);
            }
        }
        [[TUCallCenter sharedInstance] answerOrJoinCall:call];
        if (transaction != nil) {
            [controller sendMessage: @{@"transactionId": transaction}];
        }
    } else if ([event isEqualToString:@"leave-call"]) {
        TUCall *call = [[TUCallCenter sharedInstance] callWithCallUUID:(data[@"callUUID"])];
        
        if ([call callStatus] != 1) {
            if (transaction != nil) {
                [controller sendMessage: @{@"transactionId": transaction, @"error": @"Call is not waiting to be left!"}];
            }
            return;
        }
        
        [[TUCallCenter sharedInstance] disconnectCall:call];
        if (transaction != nil) {
            [controller sendMessage: @{@"transactionId": transaction}];
        }
    } else if ([event isEqualToString:@"safety-mute"]) {
        TUCall *call = [[TUCallCenter sharedInstance] callWithCallUUID:(data[@"callUUID"])];
        if (call == nil) {
            if (transaction != nil) {
                [controller sendMessage: @{ @"transactionId": transaction, @"error": @"Call not found!" }];
            }
            return;
        }
        [call setDownlinkMuted:YES];
        [call setMuted:YES];
        [call setUplinkMuted:YES];
        if (transaction != nil) {
            [controller sendMessage: @{
                @"transactionId": transaction,
                @"downlink_muted": [NSNumber numberWithBool:[call isDownlinkMuted]],
                @"muted": [NSNumber numberWithBool:[call isMuted]],
                @"is_uplink_muted": [NSNumber numberWithBool:[call isUplinkMuted]],
            }];
        }
    } else if ([event isEqualToString:@"set-muted"]) {
        TUCall *call = [[TUCallCenter sharedInstance] callWithCallUUID:(data[@"callUUID"])];
        
        if (call == nil) {
            if (transaction != nil) {
                [controller sendMessage: @{@"transactionId": transaction, @"error": @"Call not found!"}];
            }
            return;
        }
        
        BOOL muted = [data[@"muted"] boolValue];
        BOOL didSetMuted = [call setMuted:muted];
        [call setUplinkMuted:muted];
        NSDictionary *conversationAudioResult = [self startConversationAudioForCall:call muted:muted preserveVideo:NO];
        if (transaction != nil) {
            NSMutableDictionary *response = [@{
                @"transactionId": transaction,
                @"muted": [NSNumber numberWithBool:[call isMuted]],
                @"is_sending_audio": [NSNumber numberWithBool:[call isSendingAudio]],
                @"is_sending_transmission": [NSNumber numberWithBool:[call isSendingTransmission]],
                @"is_uplink_muted": [NSNumber numberWithBool:[call isUplinkMuted]],
                @"ok": [NSNumber numberWithBool:didSetMuted],
            } mutableCopy];
            [response addEntriesFromDictionary:conversationAudioResult];
            [controller sendMessage: response];
        }
    } else if ([event isEqualToString:@"start-transmission"]) {
        TUCall *call = [[TUCallCenter sharedInstance] callWithCallUUID:(data[@"callUUID"])];
        
        if (call == nil) {
            if (transaction != nil) {
                [controller sendMessage: @{@"transactionId": transaction, @"error": @"Call not found!"}];
            }
            return;
        }
        
        [call setUplinkMuted:NO];
        TUConversation *conversation = [[TUCallCenter sharedInstance] activeConversationForCall:call];
        BOOL wasSendingVideo = [call isSendingVideo];
        BOOL preserveVideo = [conversation isVideoEnabled] || wasSendingVideo;
        NSUInteger videoMode = [conversation avMode];
        [[TUCallCenter sharedInstance] startTransmissionForBargeCall:call sourceIsHandsfreeAccessory:NO];
        // Barge transmission activates FaceTime's local speaking telemetry. It
        // can also reset an active video conversation, so restore its prior mode.
        if (preserveVideo) {
            NSUUID *conversationUUID = [conversation UUID];
            if ([conversation respondsToSelector:@selector(setAvMode:)]) {
                [conversation setAvMode:videoMode];
            }
            // Only restore the local participant's video mode when the camera
            // was already sending. A receive-only video call may have camera off.
            if (wasSendingVideo) {
                TUConversationManager *manager = [[TUConversationManager alloc] init];
                if ([manager respondsToSelector:@selector(setLocalParticipantAudioVideoMode:forConversationUUID:)]) {
                    [manager setLocalParticipantAudioVideoMode:videoMode forConversationUUID:conversationUUID];
                }
                TUConversationManagerXPCClient *xpcClient = [[TUConversationManagerXPCClient alloc] init];
                if ([xpcClient respondsToSelector:@selector(setLocalParticipantAudioVideoMode:forConversationUUID:)]) {
                    [xpcClient setLocalParticipantAudioVideoMode:videoMode forConversationUUID:conversationUUID];
                }
            }
        }
        NSDictionary *conversationAudioResult = [self startConversationAudioForCall:call muted:NO preserveVideo:preserveVideo];
        if (transaction != nil) {
            NSMutableDictionary *response = [@{
                @"transactionId": transaction,
                @"muted": [NSNumber numberWithBool:[call isMuted]],
                @"is_sending_audio": [NSNumber numberWithBool:[call isSendingAudio]],
                @"is_sending_transmission": [NSNumber numberWithBool:[call isSendingTransmission]],
                @"is_uplink_muted": [NSNumber numberWithBool:[call isUplinkMuted]],
            } mutableCopy];
            [response addEntriesFromDictionary:conversationAudioResult];
            [controller sendMessage: response];
        }
    } else if ([event isEqualToString:@"generate-link"]) {
        if (data[@"callUUID"] != [NSNull null]) {
            TUCall *call = [[TUCallCenter sharedInstance] callWithCallUUID:(data[@"callUUID"])];
            TUConversation* convo = [[TUCallCenter sharedInstance] activeConversationForCall:call];
            TUConversationManagerXPCClient *manager = [[TUConversationManagerXPCClient alloc] init];
            [manager generateLinkForConversation:convo completionHandler:^(TUConversationLink *arg0, NSError *arg1) {
                DLog("FACETIMEHELPER: generated link for call %{public}@", [arg0 URL]);
                
                if (transaction != nil) {
                    [controller sendMessage: @{@"transactionId": transaction, @"url": [[arg0 URL] absoluteString]}];
                }
            }];
        } else {
            TUConversationManagerXPCClient *manager = [[TUConversationManagerXPCClient alloc] init];
            [manager generateLinkWithInvitedMemberHandles:@[] linkLifetimeScope:0 completionHandler:^(TUConversationLink *arg0, NSError *arg1) {
                DLog("FACETIMEHELPER: generated link %{public}@", [arg0 URL]);
                
                if (transaction != nil) {
                    [controller sendMessage: @{@"transactionId": transaction, @"url": [[arg0 URL] absoluteString]}];
                }
            }];
        }
    } else if ([event isEqualToString:@"admit-pending-member"]) {
        TUConversation* convo;
        for (TUConversation* i in [[[TUConversationManager alloc] init] activeConversations]) {
            if ([[[i groupUUID] UUIDString] isEqualToString:(data[@"conversationUUID"])]) {
                convo = i;
                break;
            }
        }
        
        if (convo != nil) {
            for (TUConversationMember *i in [convo pendingMembers]) {
                DLog("FACETIMEHELPER: found pending member %{public}@", i);
                if ([[[i handle] value] isEqualToString:(data[@"handleUUID"])]) {
                    DLog("FACETIMEHELPER: approving pending member");
                    [[[TUConversationManager alloc] init] approvePendingMember:i forConversation:convo];
                    if (transaction != nil) {
                        [controller sendMessage: @{@"transactionId": transaction}];
                    }
                    break;
                }
            }
        }
    } else if ([event isEqualToString:@"get-active-links"]) {
        NSArray<TUConversationLink*>* links = [[[[TUConversationManager alloc] init] activatedConversationLinks] allObjects];
        
        NSDictionary *data = @{
            @"links": [[NSMutableArray alloc] initWithArray: @[]],
        };
        
        for (TUConversationLink* link in links) {
            NSMutableArray *handleArray = [NSMutableArray array];
            [[[link invitedMemberHandles] allObjects] enumerateObjectsUsingBlock:^(TUHandle* obj, NSUInteger idx, BOOL *stop) {
                [handleArray addObject:[obj dictionaryRepresentation]];
            }];
            NSDictionary* linkData = @{
                @"url": [[link URL] absoluteString] ?: [NSNull null],
                @"creation_date": [NSNumber numberWithDouble:([[link creationDate] timeIntervalSince1970] * 1000)] ?: [NSNull null],
                @"expiration_date": [NSNumber numberWithDouble:([[link expirationDate] timeIntervalSince1970] * 1000)] ?: [NSNull null],
                @"group_uuid": [[link groupUUID] UUIDString] ?: [NSNull null],
                @"name": [link linkName] ?: [NSNull null],
                @"handles": handleArray ?: [NSNull null],
            };
            
            [data[@"links"] addObject:linkData];
        }
        
        if (transaction != nil) {
            [controller sendMessage: @{@"transactionId": transaction, @"data": data}];
        }
    } else if ([event isEqualToString:@"invalidate-link"]) {
        NSArray<TUConversationLink*>* links = [[[[TUConversationManager alloc] init] activatedConversationLinks] allObjects];
        
        for (TUConversationLink* link in links) {
            if ([[[link URL] absoluteString] isEqualToString:data[@"url"]]) {
                [[[TUConversationManagerXPCClient alloc] init] invalidateLink:link completionHandler:^(char arg0, NSError* arg1) {
                    if (transaction != nil) {
                        [controller sendMessage: @{@"transactionId": transaction}];
                    }
                }];
                break;
            }
        }
    } else if ([event isEqualToString:@"start-call"]) {
        
    }
}

@end


//ZKSwizzleInterface(FTH_NSNotificationCenter, NSNotificationCenter, NSObject)
//@implementation FTH_NSNotificationCenter
//
//- (void)addObserver:(id)observer selector:(SEL)aSelector name:(nullable NSNotificationName)aName object:(nullable id)anObject {
//    if ([aName isEqualToString:@"CNContactStoreDidChangeNotification"]) {
//        return ZKOrig(void, observer, aSelector, aName, anObject);
//    }
//    DLog("FACETIMEHELPER: >>>>>>>>>>>>> name %{public}@", aName);
//    DLog("FACETIMEHELPER: observer %{public}@", observer);
//    DLog("FACETIMEHELPER: sel %{public}@", NSStringFromSelector(aSelector));
//    DLog("FACETIMEHELPER: object %{public}@", anObject);
//    return ZKOrig(void, observer, aSelector, aName, anObject);
//}
//
//@end


//ZKSwizzleInterface(WBWT_TUConversationManager, TUConversationManager, NSObject)
//@implementation WBWT_TUConversationManager
//
//-(void)receivedTrackedPendingMember:(TUConversationMember*)member forConversationLink:(TUConversationLink*)link {
//    NSDictionary *data = @{
//        @"letmein_received": [NSNumber numberWithDouble:[[member dateReceivedLetMeIn] timeIntervalSince1970] * 1000] ?: [NSNull null],
//        @"letmein_initiated": [NSNumber numberWithDouble:[[member dateInitiatedLetMeIn] timeIntervalSince1970] * 1000] ?: [NSNull null],
//        @"handle": [[member handle] dictionaryRepresentation],
//        @"name": [member nickname],
//        @"link": [[link URL] absoluteString],
//    };
//    DLog("FACETIMEHELPER: object %{public}@", [[[TUConversationManager alloc] init] activeConversationWithGroupUUID:([link groupUUID])]);
//    [[NetworkController sharedInstance] sendMessage: @{@"event": @"received-pending-member", @"data": data}];
//    return ZKOrig(void, member, link);
//}
//
//@end
//
//ZKSwizzleInterface(WBWT_NSUserNotification, CSDConversation, NSObject)
//@implementation WBWT_NSUserNotification
//
//- (void)addPendingMembers:(id)arg1 triggeredLocally:(BOOL)arg2 {
//    DLog("FACETIMEHELPER: got pending member %{public}@", arg1);
////    NSUUID *guid = (NSUUID *)ZKHookIvar(self, NSUUID*, "_groupUUID");
////    DLog("FACETIMEHELPER: convo %{public}@", guid);
////    //DLog("FACETIMEHELPER: convo 2 %{public}@", [[[TUConversationManager alloc] init] activeConversations]);
////    DLog("FACETIMEHELPER: convo %{public}@", NSClassFromString(@"CSDConversationManager"));
//    // [[[TUConversationManagerXPCClient alloc] init] approvePendingMember:[arg1 firstObject] forConversation:([[[[TUConversationManager alloc] init] activeConversationWithGroupUUID:guid] firstObject])];
//    return ZKOrig(void, arg1, arg2);
//}
//
//@end
