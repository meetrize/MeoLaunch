#import <Cocoa/Cocoa.h>

@interface MLHotKeyRecorder : NSButton

@property (nonatomic, assign) NSInteger capturedKeyCode;
@property (nonatomic, assign) BOOL capturedCommand;
@property (nonatomic, assign) BOOL capturedOption;
@property (nonatomic, assign) BOOL capturedControl;
@property (nonatomic, assign) BOOL capturedShift;
@property (nonatomic, assign, readonly, getter=isRecording) BOOL recording;
@property (nonatomic, copy, nullable) void (^onChange)(void);

- (void)setKeyCode:(NSInteger)keyCode
           command:(BOOL)command
            option:(BOOL)option
           control:(BOOL)control
             shift:(BOOL)shift;

- (NSString * _Nonnull)displayString;

@end
