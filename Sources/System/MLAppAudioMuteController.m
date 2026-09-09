#import "MLAppAudioMuteController.h"
#import "MLAudioProcessSupport.h"

#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/CATapDescription.h>
#import <dlfcn.h>
#import <string.h>

enum {
    MLAppAudioMuteErrorUnavailable = 1,
    MLAppAudioMuteErrorBadPID = 2,
    MLAppAudioMuteErrorNoProcessObject = 3,
    MLAppAudioMuteErrorCreateTap = 4,
    MLAppAudioMuteErrorMissingSymbol = 5,
    MLAppAudioMuteErrorAggregate = 6,
    MLAppAudioMuteErrorIOProc = 7,
};

typedef OSStatus (*MLAudioHardwareCreateProcessTapFn)(CATapDescription *inDescription,
                                                      AudioObjectID *outTapID);
typedef OSStatus (*MLAudioHardwareDestroyProcessTapFn)(AudioObjectID inTapID);
typedef OSStatus (*MLAudioHardwareCreateAggregateDeviceFn)(CFDictionaryRef inDescription,
                                                           AudioObjectID *outDeviceID);
typedef OSStatus (*MLAudioHardwareDestroyAggregateDeviceFn)(AudioObjectID inDeviceID);

/** One live mute session: Process Tap + private aggregate + discarding IOProc. */
@interface MLMuteSession : NSObject
@property (nonatomic, assign) AudioObjectID tapID;
@property (nonatomic, assign) AudioObjectID aggregateID;
@property (nonatomic, assign) AudioDeviceIOProcID ioProcID;
@end

@implementation MLMuteSession
@end

@interface MLAppAudioMuteController ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, MLMuteSession *> *sessionByKey;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *muteRequestByKey;
@property (nonatomic, assign) BOOL deviceListenerInstalled;
@end

@implementation MLAppAudioMuteController

+ (BOOL)isAvailable {
    return [MLAudioProcessSupport isAvailable];
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    _sessionByKey = [NSMutableDictionary dictionary];
    _muteRequestByKey = [NSMutableDictionary dictionary];
    return self;
}

- (void)dealloc {
    [self removeDeviceListener];
    [self unmuteAll];
}

#pragma mark - Symbols

static MLAudioHardwareCreateProcessTapFn MLCreateTapFn(void) {
    static MLAudioHardwareCreateProcessTapFn fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (MLAudioHardwareCreateProcessTapFn)dlsym(RTLD_DEFAULT, "AudioHardwareCreateProcessTap");
    });
    return fn;
}

static MLAudioHardwareDestroyProcessTapFn MLDestroyTapFn(void) {
    static MLAudioHardwareDestroyProcessTapFn fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (MLAudioHardwareDestroyProcessTapFn)dlsym(RTLD_DEFAULT, "AudioHardwareDestroyProcessTap");
    });
    return fn;
}

static MLAudioHardwareCreateAggregateDeviceFn MLCreateAggFn(void) {
    static MLAudioHardwareCreateAggregateDeviceFn fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (MLAudioHardwareCreateAggregateDeviceFn)dlsym(RTLD_DEFAULT,
                                                           "AudioHardwareCreateAggregateDevice");
    });
    return fn;
}

static MLAudioHardwareDestroyAggregateDeviceFn MLDestroyAggFn(void) {
    static MLAudioHardwareDestroyAggregateDeviceFn fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (MLAudioHardwareDestroyAggregateDeviceFn)dlsym(RTLD_DEFAULT,
                                                            "AudioHardwareDestroyAggregateDevice");
    });
    return fn;
}

static NSError *MLMuteError(NSInteger code, NSString *message, OSStatus status) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[NSLocalizedDescriptionKey] = message ?: @"mute failed";
    if (status != noErr) {
        info[@"osStatus"] = @(status);
    }
    return [NSError errorWithDomain:@"MLAppAudioMuteErrorDomain" code:code userInfo:info];
}

/** Discard tapped audio; do not play it back to the output device. */
static OSStatus MLMuteDiscardIOProc(AudioObjectID inDevice,
                                    const AudioTimeStamp *inNow,
                                    const AudioBufferList *inInputData,
                                    const AudioTimeStamp *inInputTime,
                                    AudioBufferList *outOutputData,
                                    const AudioTimeStamp *inOutputTime,
                                    void *inClientData) {
    (void)inDevice;
    (void)inNow;
    (void)inInputData;
    (void)inInputTime;
    (void)inOutputTime;
    (void)inClientData;
    if (outOutputData) {
        for (UInt32 i = 0; i < outOutputData->mNumberBuffers; i++) {
            if (outOutputData->mBuffers[i].mData && outOutputData->mBuffers[i].mDataByteSize > 0) {
                memset(outOutputData->mBuffers[i].mData, 0, outOutputData->mBuffers[i].mDataByteSize);
            }
        }
    }
    return noErr;
}

#pragma mark - Device change

static OSStatus MLDefaultOutputListener(AudioObjectID inObjectID,
                                        UInt32 inNumberAddresses,
                                        const AudioObjectPropertyAddress *inAddresses,
                                        void *inClientData) {
    (void)inObjectID;
    (void)inNumberAddresses;
    (void)inAddresses;
    MLAppAudioMuteController *ctl = (__bridge MLAppAudioMuteController *)inClientData;
    dispatch_async(dispatch_get_main_queue(), ^{
        [ctl rebuildMutedTapsAfterDeviceChange];
    });
    return noErr;
}

+ (NSString *)identityKeyForPID:(pid_t)pid bundleID:(NSString *)bundleID {
    if (bundleID.length > 0) {
        return [@"bid:" stringByAppendingString:bundleID];
    }
    if (pid > 0) {
        return [NSString stringWithFormat:@"pid:%d", (int)pid];
    }
    return nil;
}

- (void)installDeviceListenerIfNeeded {
    if (self.deviceListenerInstalled || ![MLAppAudioMuteController isAvailable]) {
        return;
    }
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    OSStatus st = AudioObjectAddPropertyListener(kAudioObjectSystemObject,
                                                 &addr,
                                                 MLDefaultOutputListener,
                                                 (__bridge void *)self);
    if (st == noErr) {
        self.deviceListenerInstalled = YES;
    }
}

- (void)removeDeviceListener {
    if (!self.deviceListenerInstalled) {
        return;
    }
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject,
                                      &addr,
                                      MLDefaultOutputListener,
                                      (__bridge void *)self);
    self.deviceListenerInstalled = NO;
}

#pragma mark - HAL helpers

static NSString * _Nullable MLCopyDefaultOutputDeviceUID(OSStatus *outStatus) {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectID deviceID = kAudioObjectUnknown;
    UInt32 size = sizeof(AudioObjectID);
    OSStatus st = AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &deviceID);
    if (st != noErr || deviceID == kAudioObjectUnknown) {
        if (outStatus) {
            *outStatus = st;
        }
        return nil;
    }
    addr.mSelector = kAudioDevicePropertyDeviceUID;
    CFStringRef uid = NULL;
    size = sizeof(CFStringRef);
    st = AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, &uid);
    if (outStatus) {
        *outStatus = st;
    }
    if (st != noErr || !uid) {
        return nil;
    }
    return CFBridgingRelease(uid);
}

#pragma mark - Public state

- (BOOL)isMutedPID:(pid_t)pid {
    return [self isMutedPID:pid bundleID:nil];
}

- (BOOL)isMutedPID:(pid_t)pid bundleID:(NSString *)bundleID {
    NSString *key = [MLAppAudioMuteController identityKeyForPID:pid bundleID:bundleID];
    if (!key) {
        return NO;
    }
    if (self.sessionByKey[key] != nil) {
        return YES;
    }
    if (bundleID.length > 0 && pid > 0) {
        NSString *pidKey = [MLAppAudioMuteController identityKeyForPID:pid bundleID:nil];
        return self.sessionByKey[pidKey] != nil;
    }
    return NO;
}

#pragma mark - Mute / unmute

- (BOOL)mutePID:(pid_t)pid error:(NSError *__autoreleasing *)outError {
    return [self mutePID:pid bundleID:nil error:outError];
}

- (BOOL)mutePID:(pid_t)pid bundleID:(NSString *)bundleID error:(NSError *__autoreleasing *)outError {
    if (![MLAppAudioMuteController isAvailable]) {
        if (outError) {
            *outError = MLMuteError(MLAppAudioMuteErrorUnavailable,
                                    @"Process Tap requires macOS 14.2+",
                                    noErr);
        }
        return NO;
    }
    NSString *key = [MLAppAudioMuteController identityKeyForPID:pid bundleID:bundleID];
    if (!key) {
        if (outError) {
            *outError = MLMuteError(MLAppAudioMuteErrorBadPID, @"invalid identity", noErr);
        }
        return NO;
    }
    if (self.sessionByKey[key] != nil) {
        return YES;
    }

    NSArray<NSNumber *> *processObjs =
        [MLAudioProcessSupport copyProcessObjectIDsToMuteForPID:pid bundleID:bundleID];
    if (processObjs.count == 0) {
        if (outError) {
            *outError = MLMuteError(MLAppAudioMuteErrorNoProcessObject,
                                    @"no Core Audio process object for app",
                                    noErr);
        }
        return NO;
    }

    MLAudioHardwareCreateProcessTapFn createTap = MLCreateTapFn();
    MLAudioHardwareCreateAggregateDeviceFn createAgg = MLCreateAggFn();
    Class tapClass = NSClassFromString(@"CATapDescription");
    if (!createTap || !createAgg || !tapClass) {
        if (outError) {
            *outError = MLMuteError(MLAppAudioMuteErrorMissingSymbol,
                                    @"Process Tap / Aggregate API unavailable",
                                    noErr);
        }
        return NO;
    }

    OSStatus st = noErr;
    NSString *outputUID = MLCopyDefaultOutputDeviceUID(&st);
    if (outputUID.length == 0) {
        if (outError) {
            *outError = MLMuteError(MLAppAudioMuteErrorAggregate,
                                    @"no default output device",
                                    st);
        }
        return NO;
    }

    /*
     * mutedWhenTapped: process is silent while a client reads the tap.
     * We attach a private aggregate + discard IOProc so read stays active.
     */
    NSUUID *tapUUID = [NSUUID UUID];
    CATapDescription *desc = [[tapClass alloc] initStereoMixdownOfProcesses:processObjs];
    if (!desc) {
        if (outError) {
            *outError = MLMuteError(MLAppAudioMuteErrorCreateTap,
                                    @"failed to build CATapDescription",
                                    noErr);
        }
        return NO;
    }
    desc.UUID = tapUUID;
    desc.privateTap = YES;
    desc.name = [NSString stringWithFormat:@"MeoLaunch mute %@", key];
    desc.muteBehavior = CATapMutedWhenTapped;

    AudioObjectID tapID = kAudioObjectUnknown;
    st = createTap(desc, &tapID);
    if (st != noErr || tapID == kAudioObjectUnknown) {
        if (outError) {
            *outError = MLMuteError(MLAppAudioMuteErrorCreateTap,
                                    @"AudioHardwareCreateProcessTap failed",
                                    st);
        }
        return NO;
    }

    NSString *aggUID = [NSString stringWithFormat:@"MeoLaunchMute-%@", tapUUID.UUIDString];
    NSDictionary *aggDesc = @{
        @(kAudioAggregateDeviceNameKey) : [NSString stringWithFormat:@"MeoLaunch Mute %@", key],
        @(kAudioAggregateDeviceUIDKey) : aggUID,
        @(kAudioAggregateDeviceMainSubDeviceKey) : outputUID,
        @(kAudioAggregateDeviceIsPrivateKey) : @YES,
        @(kAudioAggregateDeviceIsStackedKey) : @NO,
        @(kAudioAggregateDeviceTapAutoStartKey) : @YES,
        @(kAudioAggregateDeviceSubDeviceListKey) : @[ @{
            @(kAudioSubDeviceUIDKey) : outputUID,
        } ],
        @(kAudioAggregateDeviceTapListKey) : @[ @{
            @(kAudioSubTapUIDKey) : tapUUID.UUIDString,
            @(kAudioSubTapDriftCompensationKey) : @YES,
        } ],
    };

    AudioObjectID aggregateID = kAudioObjectUnknown;
    st = createAgg((__bridge CFDictionaryRef)aggDesc, &aggregateID);
    if (st != noErr || aggregateID == kAudioObjectUnknown) {
        MLAudioHardwareDestroyProcessTapFn destroyTap = MLDestroyTapFn();
        if (destroyTap) {
            destroyTap(tapID);
        }
        if (outError) {
            *outError = MLMuteError(MLAppAudioMuteErrorAggregate,
                                    @"AudioHardwareCreateAggregateDevice failed",
                                    st);
        }
        return NO;
    }

    AudioDeviceIOProcID ioProcID = NULL;
    st = AudioDeviceCreateIOProcID(aggregateID, MLMuteDiscardIOProc, NULL, &ioProcID);
    if (st != noErr || !ioProcID) {
        MLAudioHardwareDestroyAggregateDeviceFn destroyAgg = MLDestroyAggFn();
        MLAudioHardwareDestroyProcessTapFn destroyTap = MLDestroyTapFn();
        if (destroyAgg) {
            destroyAgg(aggregateID);
        }
        if (destroyTap) {
            destroyTap(tapID);
        }
        if (outError) {
            *outError = MLMuteError(MLAppAudioMuteErrorIOProc,
                                    @"AudioDeviceCreateIOProcID failed",
                                    st);
        }
        return NO;
    }

    st = AudioDeviceStart(aggregateID, ioProcID);
    if (st != noErr) {
        AudioDeviceDestroyIOProcID(aggregateID, ioProcID);
        MLAudioHardwareDestroyAggregateDeviceFn destroyAgg = MLDestroyAggFn();
        MLAudioHardwareDestroyProcessTapFn destroyTap = MLDestroyTapFn();
        if (destroyAgg) {
            destroyAgg(aggregateID);
        }
        if (destroyTap) {
            destroyTap(tapID);
        }
        if (outError) {
            *outError = MLMuteError(MLAppAudioMuteErrorIOProc,
                                    @"AudioDeviceStart failed",
                                    st);
        }
        return NO;
    }

    MLMuteSession *session = [[MLMuteSession alloc] init];
    session.tapID = tapID;
    session.aggregateID = aggregateID;
    session.ioProcID = ioProcID;
    self.sessionByKey[key] = session;

    NSMutableDictionary *req = [NSMutableDictionary dictionary];
    if (pid > 0) {
        req[@"pid"] = @(pid);
    }
    if (bundleID.length > 0) {
        req[@"bundleID"] = bundleID;
    }
    self.muteRequestByKey[key] = req;
    [self installDeviceListenerIfNeeded];
    return YES;
}

- (BOOL)unmutePID:(pid_t)pid error:(NSError *__autoreleasing *)outError {
    return [self unmutePID:pid bundleID:nil error:outError];
}

- (BOOL)unmutePID:(pid_t)pid bundleID:(NSString *)bundleID error:(NSError *__autoreleasing *)outError {
    NSString *key = [MLAppAudioMuteController identityKeyForPID:pid bundleID:bundleID];
    NSString *pidKey = (pid > 0) ? [MLAppAudioMuteController identityKeyForPID:pid bundleID:nil] : nil;
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    if (key) {
        [keys addObject:key];
    }
    if (pidKey && ![pidKey isEqualToString:key]) {
        [keys addObject:pidKey];
    }
    BOOL any = NO;
    BOOL ok = YES;
    for (NSString *k in keys) {
        if (!self.sessionByKey[k]) {
            continue;
        }
        any = YES;
        if (![self destroySessionForKey:k error:outError]) {
            ok = NO;
        }
    }
    if (!any) {
        return YES;
    }
    if (self.sessionByKey.count == 0) {
        [self removeDeviceListener];
    }
    return ok;
}

- (BOOL)destroySessionForKey:(NSString *)key error:(NSError *__autoreleasing *)outError {
    MLMuteSession *session = self.sessionByKey[key];
    if (!session) {
        return YES;
    }
    [self.sessionByKey removeObjectForKey:key];
    [self.muteRequestByKey removeObjectForKey:key];

    AudioObjectID aggregateID = session.aggregateID;
    AudioDeviceIOProcID ioProcID = session.ioProcID;
    AudioObjectID tapID = session.tapID;

    if (aggregateID != kAudioObjectUnknown && ioProcID) {
        AudioDeviceStop(aggregateID, ioProcID);
        AudioDeviceDestroyIOProcID(aggregateID, ioProcID);
    }
    if (aggregateID != kAudioObjectUnknown) {
        MLAudioHardwareDestroyAggregateDeviceFn destroyAgg = MLDestroyAggFn();
        if (destroyAgg) {
            OSStatus st = destroyAgg(aggregateID);
            if (st != noErr && outError && !*outError) {
                *outError = MLMuteError(MLAppAudioMuteErrorAggregate,
                                        @"AudioHardwareDestroyAggregateDevice failed",
                                        st);
            }
        }
    }
    if (tapID != kAudioObjectUnknown) {
        MLAudioHardwareDestroyProcessTapFn destroyTap = MLDestroyTapFn();
        if (destroyTap) {
            OSStatus st = destroyTap(tapID);
            if (st != noErr && outError && !*outError) {
                *outError = MLMuteError(MLAppAudioMuteErrorCreateTap,
                                        @"AudioHardwareDestroyProcessTap failed",
                                        st);
            }
        }
    }
    return YES;
}

- (BOOL)toggleMutePID:(pid_t)pid
             outMuted:(BOOL *)outMuted
                error:(NSError *__autoreleasing *)outError {
    return [self toggleMutePID:pid bundleID:nil outMuted:outMuted error:outError];
}

- (BOOL)toggleMutePID:(pid_t)pid
             bundleID:(NSString *)bundleID
             outMuted:(BOOL *)outMuted
                error:(NSError *__autoreleasing *)outError {
    if ([self isMutedPID:pid bundleID:bundleID]) {
        BOOL ok = [self unmutePID:pid bundleID:bundleID error:outError];
        if (ok && outMuted) {
            *outMuted = NO;
        }
        return ok;
    }
    BOOL ok = [self mutePID:pid bundleID:bundleID error:outError];
    if (ok && outMuted) {
        *outMuted = YES;
    }
    return ok;
}

- (void)unmuteAll {
    NSArray<NSString *> *keys = self.sessionByKey.allKeys;
    for (NSString *key in keys) {
        [self destroySessionForKey:key error:NULL];
    }
    [self removeDeviceListener];
}

- (NSArray<NSNumber *> *)copyMutedPIDs {
    NSMutableArray<NSNumber *> *pids = [NSMutableArray array];
    for (NSDictionary *req in self.muteRequestByKey.allValues) {
        NSNumber *pidNum = req[@"pid"];
        if (pidNum) {
            [pids addObject:pidNum];
        }
    }
    return pids;
}

- (NSArray<NSString *> *)copyMutedIdentityKeys {
    return self.sessionByKey.allKeys ?: @[];
}

- (void)rebuildMutedTapsAfterDeviceChange {
    NSDictionary<NSString *, NSDictionary *> *reqs = [self.muteRequestByKey copy];
    for (NSString *key in reqs) {
        [self destroySessionForKey:key error:NULL];
    }
    for (NSString *key in reqs) {
        NSDictionary *req = reqs[key];
        pid_t pid = [req[@"pid"] intValue];
        NSString *bid = req[@"bundleID"];
        [self mutePID:pid bundleID:bid error:NULL];
    }
}

@end
