#import "MLHotKeyDisplay.h"

#import "MLConfigStore.h"

#import <Carbon/Carbon.h>

@implementation MLHotKeyDisplay

+ (NSString *)modifierPrefixCommand:(BOOL)command
                             option:(BOOL)option
                            control:(BOOL)control
                              shift:(BOOL)shift {
    NSMutableString *s = [NSMutableString string];
    if (command) {
        [s appendString:@"⌘"];
    }
    if (shift) {
        [s appendString:@"⇧"];
    }
    if (option) {
        [s appendString:@"⌥"];
    }
    if (control) {
        [s appendString:@"⌃"];
    }
    return [s copy];
}

+ (NSString *)keyDisplayForKeyCode:(NSInteger)keyCode {
    switch (keyCode) {
        case kVK_Space: return @"Space";
        case kVK_Return: return @"↩";
        case kVK_Escape: return @"Esc";
        case kVK_Delete: return @"⌫";
        case kVK_ForwardDelete: return @"⌦";
        case kVK_Tab: return @"⇥";
        case kVK_LeftArrow: return @"←";
        case kVK_RightArrow: return @"→";
        case kVK_UpArrow: return @"↑";
        case kVK_DownArrow: return @"↓";
        case kVK_ANSI_0: return @"0";
        case kVK_ANSI_1: return @"1";
        case kVK_ANSI_2: return @"2";
        case kVK_ANSI_3: return @"3";
        case kVK_ANSI_4: return @"4";
        case kVK_ANSI_5: return @"5";
        case kVK_ANSI_6: return @"6";
        case kVK_ANSI_7: return @"7";
        case kVK_ANSI_8: return @"8";
        case kVK_ANSI_9: return @"9";
        default:
            break;
    }
    if (keyCode >= kVK_ANSI_A && keyCode <= kVK_ANSI_Z) {
        unichar c = (unichar)('A' + (keyCode - kVK_ANSI_A));
        return [[NSString stringWithFormat:@"%C", c] uppercaseString];
    }
    NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                      location:NSZeroPoint
                                 modifierFlags:0
                                     timestamp:0
                                  windowNumber:0
                                       context:nil
                                      characters:@""
                     charactersIgnoringModifiers:@"?"
                                       isARepeat:NO
                                         keyCode:(unsigned short)keyCode];
    NSString *chars = event.charactersIgnoringModifiers;
    if (chars.length > 0) {
        return [chars uppercaseString];
    }
    return [NSString stringWithFormat:@"Key %ld", (long)keyCode];
}

+ (NSString *)displayStringForKeyCode:(NSInteger)keyCode
                              command:(BOOL)command
                               option:(BOOL)option
                              control:(BOOL)control
                                shift:(BOOL)shift {
    NSString *mods = [self modifierPrefixCommand:command
                                          option:option
                                         control:control
                                           shift:shift];
    NSString *key = [self keyDisplayForKeyCode:keyCode];
    if (mods.length == 0) {
        return key;
    }
    return [mods stringByAppendingString:key];
}

+ (NSString *)displayStringFromConfig:(MLConfigStore *)config {
    if (!config.hotkeyEnabled) {
        return @"—";
    }
    return [self displayStringForKeyCode:config.hotkeyKeyCode
                                 command:config.hotkeyCommand
                                  option:config.hotkeyOption
                                 control:config.hotkeyControl
                                   shift:config.hotkeyShift];
}

@end
