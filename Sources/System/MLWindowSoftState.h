#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>

FOUNDATION_EXPORT NSNotificationName const MLWindowSoftStateDidChangeNotification;

typedef NS_ENUM(NSInteger, MLWindowHideMethod) {
    MLWindowHideMethodNone = 0,
    MLWindowHideMethodAlpha = 1,
    MLWindowHideMethodAXMinimized = 2,
};

@interface MLWindowSoftRecord : NSObject
@property (nonatomic, assign) CGWindowID windowID;
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign) NSRect restoreFrameCocoa;
@property (nonatomic, strong) NSNumber *affinityScreenID;
@property (nonatomic, assign) MLWindowHideMethod hideMethod;
@property (nonatomic, assign) NSUInteger seenOrder;
/** Retained AX window for reliable restore (esp. Finder). */
@property (nonatomic, assign) AXUIElementRef axWindow;
@end

/**
 * Soft-hidden window lifecycle keyed by CGWindowID.
 * Soft entries keep taskbar chips alive while CG cannot see the window.
 * Clear only after a verified restore (or confirmed close).
 */
@interface MLWindowSoftState : NSObject

- (BOOL)isSoftHiddenWindowID:(CGWindowID)windowID;
- (MLWindowSoftRecord *)recordForWindowID:(CGWindowID)windowID;
- (NSArray<MLWindowSoftRecord *> *)allRecords;
- (NSSet<NSNumber *> *)softHiddenWindowIDs;
- (BOOL)hasRestoreFrameForWindowID:(CGWindowID)windowID;
- (NSRect)restoreFrameForWindowID:(CGWindowID)windowID;

/** Mark soft-hidden BEFORE mutating the real window. axWindow is retained. */
- (void)markSoftHiddenWindowID:(CGWindowID)windowID
                           pid:(pid_t)pid
                          path:(NSString *)path
                         title:(NSString *)title
                 restoreFrame:(NSRect)restoreFrameCocoa
                     screenID:(NSNumber *)screenID
                   hideMethod:(MLWindowHideMethod)method
                    seenOrder:(NSUInteger)seenOrder
                     axWindow:(AXUIElementRef)axWindow;

- (void)updateHideMethod:(MLWindowHideMethod)method forWindowID:(CGWindowID)windowID;

/** Only after restore verification succeeds. */
- (void)clearVerifiedWindowID:(CGWindowID)windowID;

/** Window truly gone (closed / process quit). */
- (void)removeClosedWindowID:(CGWindowID)windowID;

- (void)removeAll;

@end
