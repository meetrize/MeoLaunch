#import "MLHotKeyManager.h"

#import "MLConfigStore.h"
#import "MLHotKeyDisplay.h"

#import <Carbon/Carbon.h>

@interface MLHotKeyManager ()
@property (nonatomic, assign) EventHotKeyRef overlayHotKeyRef;
@property (nonatomic, assign) EventHotKeyRef chipLocatorHotKeyRef;
@property (nonatomic, assign) EventHandlerRef handlerRef;

@property (nonatomic, assign) BOOL overlayEnabled;
@property (nonatomic, assign) UInt32 overlayKeyCode;
@property (nonatomic, assign) UInt32 overlayModifiers;

@property (nonatomic, assign) BOOL chipLocatorEnabled;
@property (nonatomic, assign) UInt32 chipLocatorKeyCode;
@property (nonatomic, assign) UInt32 chipLocatorModifiers;

@property (nonatomic, assign, readwrite, getter=isRegistered) BOOL registered;
@property (nonatomic, assign, readwrite, getter=isOverlayRegistered) BOOL overlayRegistered;
@property (nonatomic, assign, readwrite, getter=isChipLocatorRegistered) BOOL chipLocatorRegistered;
@end

static OSStatus MLHotKeyEventHandler(EventHandlerCallRef nextHandler,
                                     EventRef theEvent,
                                     void *userData) {
    (void)nextHandler;
    MLHotKeyManager *manager = (__bridge MLHotKeyManager *)userData;
    EventHotKeyID hotKeyID;
    OSStatus paramStatus = GetEventParameter(theEvent,
                                             kEventParamDirectObject,
                                             typeEventHotKeyID,
                                             NULL,
                                             sizeof(hotKeyID),
                                             NULL,
                                             &hotKeyID);
    if (paramStatus != noErr) {
        return paramStatus;
    }
    MLHotKeyAction action = (MLHotKeyAction)hotKeyID.id;
    if (action != MLHotKeyActionOverlay && action != MLHotKeyActionChipLocator) {
        return noErr;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [manager.delegate hotKeyManager:manager didFireAction:action];
    });
    return noErr;
}

@implementation MLHotKeyManager

- (instancetype)init {
    self = [super init];
    if (self) {
        _overlayEnabled = YES;
        _overlayKeyCode = kVK_ANSI_8;
        _overlayModifiers = cmdKey | optionKey | shiftKey;

        _chipLocatorEnabled = YES;
        _chipLocatorKeyCode = kVK_Space;
        _chipLocatorModifiers = controlKey | cmdKey;

        _overlayHotKeyRef = NULL;
        _chipLocatorHotKeyRef = NULL;
        _handlerRef = NULL;
        _registered = NO;
        _overlayRegistered = NO;
        _chipLocatorRegistered = NO;
    }
    return self;
}

- (void)dealloc {
    [self unregisterAll];
}

- (UInt32)carbonModifiersFromOption:(BOOL)option
                            command:(BOOL)command
                            control:(BOOL)control
                              shift:(BOOL)shift
                       fallbackMask:(UInt32)fallback {
    UInt32 mods = 0;
    if (option) mods |= optionKey;
    if (command) mods |= cmdKey;
    if (control) mods |= controlKey;
    if (shift) mods |= shiftKey;
    if (mods == 0) {
        mods = fallback;
    }
    return mods;
}

- (void)applyConfig:(MLConfigStore *)config {
    if (!config) {
        return;
    }
    self.overlayEnabled = config.hotkeyEnabled;
    self.overlayKeyCode = (UInt32)config.hotkeyKeyCode;
    self.overlayModifiers = [self carbonModifiersFromOption:config.hotkeyOption
                                                    command:config.hotkeyCommand
                                                    control:config.hotkeyControl
                                                      shift:config.hotkeyShift
                                               fallbackMask:optionKey];

    self.chipLocatorEnabled = config.chipLocatorHotkeyEnabled;
    self.chipLocatorKeyCode = (UInt32)config.chipLocatorHotkeyKeyCode;
    self.chipLocatorModifiers =
        [self carbonModifiersFromOption:config.chipLocatorHotkeyOption
                                command:config.chipLocatorHotkeyCommand
                                control:config.chipLocatorHotkeyControl
                                  shift:config.chipLocatorHotkeyShift
                           fallbackMask:(controlKey | cmdKey)];
}

- (BOOL)registerHotKeyWithID:(UInt32)hotKeyID
                     keyCode:(UInt32)keyCode
                   modifiers:(UInt32)modifiers
                         ref:(EventHotKeyRef *)outRef
                        name:(NSString *)name {
    EventHotKeyID eid;
    eid.signature = 'MEOL';
    eid.id = hotKeyID;
    OSStatus status = RegisterEventHotKey(keyCode,
                                          modifiers,
                                          eid,
                                          GetApplicationEventTarget(),
                                          0,
                                          outRef);
    if (status != noErr) {
        NSLog(@"[MeoLaunch] RegisterEventHotKey (%@) failed: %d", name, (int)status);
        *outRef = NULL;
        return NO;
    }
    NSLog(@"[MeoLaunch] HotKey registered (%@): %@ (key=%u)",
          name,
          [MLHotKeyDisplay displayStringForKeyCode:keyCode
                                           command:(modifiers & cmdKey) != 0
                                            option:(modifiers & optionKey) != 0
                                           control:(modifiers & controlKey) != 0
                                             shift:(modifiers & shiftKey) != 0],
          (unsigned)keyCode);
    return YES;
}

- (BOOL)registerDefaultHotKey {
    [self unregisterAll];

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

    BOOL any = NO;
    if (self.overlayEnabled) {
        self.overlayRegistered =
            [self registerHotKeyWithID:MLHotKeyActionOverlay
                               keyCode:self.overlayKeyCode
                             modifiers:self.overlayModifiers
                                   ref:&_overlayHotKeyRef
                                  name:@"overlay"];
        any = any || self.overlayRegistered;
    } else {
        NSLog(@"[MeoLaunch] Overlay HotKey disabled");
        self.overlayRegistered = NO;
    }

    if (self.chipLocatorEnabled) {
        /* Avoid registering the exact same combo twice. */
        BOOL sameAsOverlay = self.overlayEnabled &&
            self.overlayKeyCode == self.chipLocatorKeyCode &&
            self.overlayModifiers == self.chipLocatorModifiers;
        if (sameAsOverlay) {
            NSLog(@"[MeoLaunch] Chip Locator HotKey skipped (same as overlay)");
            self.chipLocatorRegistered = NO;
        } else {
            self.chipLocatorRegistered =
                [self registerHotKeyWithID:MLHotKeyActionChipLocator
                                   keyCode:self.chipLocatorKeyCode
                                 modifiers:self.chipLocatorModifiers
                                       ref:&_chipLocatorHotKeyRef
                                      name:@"chip-locator"];
            any = any || self.chipLocatorRegistered;
        }
    } else {
        NSLog(@"[MeoLaunch] Chip Locator HotKey disabled");
        self.chipLocatorRegistered = NO;
    }

    if (!any) {
        if (self.handlerRef) {
            RemoveEventHandler(self.handlerRef);
            self.handlerRef = NULL;
        }
        self.registered = NO;
        return NO;
    }

    self.registered = YES;
    return YES;
}

- (void)unregisterAll {
    if (self.overlayHotKeyRef) {
        UnregisterEventHotKey(self.overlayHotKeyRef);
        self.overlayHotKeyRef = NULL;
    }
    if (self.chipLocatorHotKeyRef) {
        UnregisterEventHotKey(self.chipLocatorHotKeyRef);
        self.chipLocatorHotKeyRef = NULL;
    }
    if (self.handlerRef) {
        RemoveEventHandler(self.handlerRef);
        self.handlerRef = NULL;
    }
    self.registered = NO;
    self.overlayRegistered = NO;
    self.chipLocatorRegistered = NO;
}

@end
