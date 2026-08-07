#import "MLHotKeyRecorder.h"

#import "MLHotKeyDisplay.h"
#import "MLStrings.h"

#import <Carbon/Carbon.h>

@interface MLHotKeyRecorder ()
@property (nonatomic, assign) id localMonitor;
@property (nonatomic, assign, readwrite) BOOL recording;
@end

@implementation MLHotKeyRecorder

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.bezelStyle = NSBezelStyleRounded;
        self.target = self;
        self.action = @selector(beginRecording:);
        self.capturedKeyCode = kVK_ANSI_8;
        self.capturedCommand = YES;
        self.capturedOption = YES;
        self.capturedControl = NO;
        self.capturedShift = YES;
        [self updateTitle];
    }
    return self;
}

- (void)dealloc {
    [self stopRecording];
}

- (NSString *)displayString {
    return [MLHotKeyDisplay displayStringForKeyCode:self.capturedKeyCode
                                            command:self.capturedCommand
                                             option:self.capturedOption
                                            control:self.capturedControl
                                              shift:self.capturedShift];
}

- (void)updateTitle {
    self.title = self.recording ? [MLStrings t:@"prefs.hotkey_record_prompt"] : [self displayString];
}

- (void)setKeyCode:(NSInteger)keyCode
           command:(BOOL)command
            option:(BOOL)option
           control:(BOOL)control
             shift:(BOOL)shift {
    self.capturedKeyCode = keyCode;
    self.capturedCommand = command;
    self.capturedOption = option;
    self.capturedControl = control;
    self.capturedShift = shift;
    [self updateTitle];
}

- (BOOL)isModifierOnlyKeyCode:(unsigned short)keyCode {
    switch (keyCode) {
        case kVK_Shift:
        case kVK_RightShift:
        case kVK_Control:
        case kVK_RightControl:
        case kVK_Option:
        case kVK_RightOption:
        case kVK_Command:
        case kVK_RightCommand:
        case kVK_CapsLock:
        case kVK_Function:
            return YES;
        default:
            return NO;
    }
}

- (void)beginRecording:(id)sender {
    (void)sender;
    if (self.recording) {
        return;
    }
    [self stopRecording];
    self.recording = YES;
    [self updateTitle];
    __weak typeof(self) weakSelf = self;
    self.localMonitor =
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                              handler:^NSEvent *(NSEvent *event) {
                                                  __strong typeof(weakSelf) self = weakSelf;
                                                  if (!self || !self.recording) {
                                                      return event;
                                                  }
                                                  unsigned short keyCode = event.keyCode;
                                                  if (keyCode == kVK_Escape) {
                                                      [self stopRecording];
                                                      [self updateTitle];
                                                      return nil;
                                                  }
                                                  if ([self isModifierOnlyKeyCode:keyCode]) {
                                                      return nil;
                                                  }
                                                  NSEventModifierFlags flags =
                                                      event.modifierFlags &
                                                      NSEventModifierFlagDeviceIndependentFlagsMask;
                                                  BOOL cmd = (flags & NSEventModifierFlagCommand) != 0;
                                                  BOOL opt = (flags & NSEventModifierFlagOption) != 0;
                                                  BOOL ctrl = (flags & NSEventModifierFlagControl) != 0;
                                                  BOOL shift = (flags & NSEventModifierFlagShift) != 0;
                                                  if (!cmd && !opt && !ctrl && !shift) {
                                                      return nil;
                                                  }
                                                  self.capturedKeyCode = keyCode;
                                                  self.capturedCommand = cmd;
                                                  self.capturedOption = opt;
                                                  self.capturedControl = ctrl;
                                                  self.capturedShift = shift;
                                                  [self stopRecording];
                                                  [self updateTitle];
                                                  if (self.onChange) {
                                                      self.onChange();
                                                  }
                                                  return nil;
                                              }];
}

- (void)stopRecording {
    self.recording = NO;
    if (self.localMonitor) {
        [NSEvent removeMonitor:self.localMonitor];
        self.localMonitor = nil;
    }
}

@end
