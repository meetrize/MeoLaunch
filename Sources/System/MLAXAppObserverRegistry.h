#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>

@class MLAXAppObserverRegistry;

@protocol MLAXAppObserverRegistryDelegate <NSObject>
- (void)axRegistryDidRequestStructuralPoll:(MLAXAppObserverRegistry *)registry;
- (void)axRegistryDidRequestGeometryPoll:(MLAXAppObserverRegistry *)registry;
- (void)axRegistry:(MLAXAppObserverRegistry *)registry didDestroyElement:(AXUIElementRef)element;
- (void)axRegistry:(MLAXAppObserverRegistry *)registry didCreateWindow:(AXUIElementRef)element;
- (void)axRegistry:(MLAXAppObserverRegistry *)registry didChangeTitleOnElement:(AXUIElementRef)element;
- (void)axRegistry:(MLAXAppObserverRegistry *)registry didMoveOrResizeElement:(AXUIElementRef)element;
- (void)axRegistry:(MLAXAppObserverRegistry *)registry
    didChangeFocusedWindow:(CGWindowID)wid
                       pid:(pid_t)pid;
- (CGWindowID)axRegistry:(MLAXAppObserverRegistry *)registry windowIDForElement:(AXUIElementRef)el;
@end

/** Per-PID AXObserver for low-latency window lifecycle events. */
@interface MLAXAppObserverRegistry : NSObject

@property (nonatomic, weak) id<MLAXAppObserverRegistryDelegate> delegate;
@property (nonatomic, assign, getter=isActive) BOOL active;
/** Number of live per-PID AX observers (diagnostics). */
@property (nonatomic, assign, readonly) NSUInteger watchCount;

- (void)registerNotificationsOnWindow:(AXUIElementRef)win;
- (void)installWatchForPID:(pid_t)pid;
- (void)removeWatchForPID:(pid_t)pid;
- (void)syncWatchesForPIDs:(NSSet<NSNumber *> *)pids;
- (void)removeAllWatches;

@end
