#import <Foundation/Foundation.h>

@interface MLHotKeyDisplay : NSObject

+ (NSString *)displayStringForKeyCode:(NSInteger)keyCode
                              command:(BOOL)command
                               option:(BOOL)option
                              control:(BOOL)control
                                shift:(BOOL)shift;

+ (NSString *)displayStringFromConfig:(id)config;

@end
