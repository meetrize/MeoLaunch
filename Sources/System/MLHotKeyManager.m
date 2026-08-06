#import "MLHotKeyManager.h"

#import "MLConfigStore.h"
#import "MLHotKeyDisplay.h"

#import <Carbon/Carbon.h>

@interface MLHotKeyManager ()
@property (nonatomic, assign) EventHotKeyRef hotKeyRef;
@property (nonatomic, assign) EventHandlerRef handlerRef;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) UInt32 keyCode;
@property (nonatomic, assign) UInt32 modifiers; /* Carbon modifiers */
@property (nonatomic, assign, readwrite, getter=isRegistered) BOOL registered;
@end

static OSStatus MLHotKeyEventHandler(EventHandlerCallRef nextHandler,
                                     EventRef theEvent,
                                     void *userData) {
    (void)nextHandler;
    (void)theEvent;
    MLHotKeyManager *manager = (__bridge MLHotKeyManager *)userData;
    dispatch_async(dispatch_get_main_queue(), ^{
        [manager.delegate hotKeyManagerDidFire:manager];
    });
    return noErr;
}

@implementation MLHotKeyManager

- (instancetype)init {
    self = [super init];
    if (self) {
        _enabled = YES;
        _keyCode = kVK_Space; /* 49 */
        _modifiers = optionKey;
        _hotKeyRef = NULL;
        _handlerRef = NULL;
        _registered = NO;
    }
    return self;
}

- (void)dealloc {
    [self unregisterAll];
}

- (void)applyConfig:(MLConfigStore *)config {
    if (!config) {
        return;
    }
    self.enabled = config.hotkeyEnabled;
    self.keyCode = (UInt32)config.hotkeyKeyCode;
    UInt32 mods = 0;
    if (config.hotkeyOption) mods |= optionKey;
    if (config.hotkeyCommand) mods |= cmdKey;
    if (config.hotkeyControl) mods |= controlKey;
    if (config.hotkeyShift) mods |= shiftKey;
    if (mods == 0) {
        mods = optionKey;
    }
    self.modifiers = mods;
}

- (BOOL)registerDefaultHotKey {
    [self unregisterAll];

    if (!self.enabled) {
        NSLog(@"[MeoLaunch] HotKey disabled");
        return NO;
    }

    EventTypeSpec eventType = {kEventClassKeyboard, kEventHotKeyPressed};
    OSStatus status = InstallEventHandler(GetApplicationEventTarget(),
                                          MLHotKeyEventHandler,
                                          1,
                                          &eventType,
                                          (__bridge void *)self,
                                          &_handlerRef);
    if (status != noErr) {
        NSLog(@"[MeoLaunch] InstallEventHandler failed: %d", (int)status);
        self.handlerRef = NULL;
        return NO;
    }

    EventHotKeyID hotKeyID;
    hotKeyID.signature = 'MEOL';
    hotKeyID.id = 1;

    status = RegisterEventHotKey(self.keyCode,
                                 self.modifiers,
                                 hotKeyID,
                                 GetApplicationEventTarget(),
                                 0,
                                 &_hotKeyRef);
    if (status != noErr) {
        NSLog(@"[MeoLaunch] RegisterEventHotKey failed: %d (⌥Space may be in use)", (int)status);
        if (self.handlerRef) {
            RemoveEventHandler(self.handlerRef);
            self.handlerRef = NULL;
        }
        self.hotKeyRef = NULL;
        self.registered = NO;
        return NO;
    }

    self.registered = YES;
    NSLog(@"[MeoLaunch] HotKey registered: %@ (key=%u)",
          [MLHotKeyDisplay displayStringForKeyCode:self.keyCode
                                           command:(self.modifiers & cmdKey) != 0
                                            option:(self.modifiers & optionKey) != 0
                                           control:(self.modifiers & controlKey) != 0
                                             shift:(self.modifiers & shiftKey) != 0],
          (unsigned)self.keyCode);
    return YES;
}

- (void)unregisterAll {
    if (self.hotKeyRef) {
        UnregisterEventHotKey(self.hotKeyRef);
        self.hotKeyRef = NULL;
    }
    if (self.handlerRef) {
        RemoveEventHandler(self.handlerRef);
        self.handlerRef = NULL;
    }
    self.registered = NO;
}

@end
