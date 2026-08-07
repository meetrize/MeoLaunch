#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>

#import "MLRunningAppsMonitor.h"
#import "MLTaskbarScreenBar.h"
#import "MLTaskbarView.h"

@class MLTaskbarController;

NS_ASSUME_NONNULL_BEGIN

@interface MLTaskbarController (Items)

- (void)rebuildItems;
- (NSString *)displayNameForPath:(NSString *)path;
- (pid_t)pidForPath:(NSString *)path snapshot:(MLRunningAppsSnapshot *)snap;
- (BOOL)pinSet:(NSSet<NSString *> *)pinSet containsPath:(NSString *)path;
- (MLTaskbarItem *)itemWithPath:(NSString *)path
                            pid:(pid_t)pid
                       windowID:(CGWindowID)windowID
                          title:(NSString *)title
                           kind:(MLTaskbarItemKind)kind
                         pinned:(BOOL)pinned
                      minimized:(BOOL)minimized
                         active:(BOOL)active
                      seenOrder:(NSUInteger)seenOrder;
- (CGWindowID)frontmostTrackedWindowID;
- (CGWindowID)topmostUserWindowIDExcludingSelf;
- (NSScreen *)screenForWindowBounds:(CGRect)bounds;
- (NSScreen *)screenWithID:(NSNumber *)sid;
- (BOOL)boundsClearlyOnAScreen:(CGRect)bounds;
- (void)rememberChipScreenAffinityFromBars;
- (void)rememberChipScreenAffinityFromFrozenShots;
- (BOOL)pendingMovesChipsAcrossScreens;
- (NSArray<MLTaskbarWindowInfo *> *)windowsOnScreen:(NSScreen *)screen
                                           fromSnap:(MLRunningAppsSnapshot *)snap
                                                cap:(NSUInteger)cap;
- (NSInteger)windowChipCountInItems:(NSArray<MLTaskbarItem *> *)items;
- (NSArray<MLTaskbarItem *> *)deepCopyItems:(NSArray<MLTaskbarItem *> *)src;
- (void)rebuildItemsForBar:(MLTaskbarScreenBar *)bar screen:(NSScreen *)screen;
- (NSInteger)windowChipCountOnBar:(MLTaskbarScreenBar *)bar;
- (BOOL)displayedItemsContainWindowID:(CGWindowID)wid;
- (void)paintActiveHighlightForWindowID:(CGWindowID)frontWid;
- (CGWindowID)windowIDOnBarsForPID:(pid_t)pid matchingTitle:(NSString *)focusTitle;
- (void)applyActiveHighlightForWindowID:(CGWindowID)hintWid;
- (void)applyActiveHighlightImmediate;
- (void)cancelItemsCommitTimer;
- (void)scheduleItemsCommitWithDelay:(NSTimeInterval)delay;
- (void)commitPendingItemsForce:(BOOL)force;
- (void)computePendingItemsForAllBars;
- (void)rebuildItemsImmediate:(BOOL)immediate;
- (NSMutableArray<MLTaskbarItem *> *)fitItems:(NSMutableArray<MLTaskbarItem *> *)items
                                      toWidth:(CGFloat)width
                                      spacing:(CGFloat)spacing
                                     minWidth:(CGFloat)minW;

@end

@interface MLTaskbarController (Peek)

- (void)handleDesktopPeekClickAtCocoaPoint:(NSPoint)cocoaPoint;
- (void)restoreFrozenItemsOntoBars;
- (BOOL)isDesktopRevealArmed;
- (void)measureDesktopRevealWithCenterCover:(CGFloat *)outCover
                                   onScreen:(NSInteger *)outOnScreen
                                        all:(NSInteger *)outAll;
- (void)updateStableLiveCensus;
- (NSInteger)frozenWindowChipTotal;
- (BOOL)shouldUnfreezeDesktopReveal;
- (void)freezeDesktopReveal;
- (void)unfreezeDesktopRevealAndRefresh;
- (NSInteger)liveNonMinimizedWindowCount;
- (NSInteger)liveOnScreenNonMinimizedWindowCount;
- (NSSet<NSNumber *> *)hiddenTaskWindowIDSet;
- (BOOL)allDisplayedWindowChipsAreHidden;
- (NSInteger)countForeignOffscreenWindowsExcluding:(NSSet<NSNumber *> *)hiddenIDs;
- (BOOL)isPassiveMinimizeAllState;
- (BOOL)hasShowDesktopParkedEvidence;
- (BOOL)shouldIgnoreDesktopRevealBecauseAllMinimized;
- (NSInteger)totalWindowChipsOnBars;
- (BOOL)looksLikeDesktopReveal;
- (BOOL)shouldFreezeForDesktopReveal;
- (void)applyPeekPresentationForBar:(MLTaskbarScreenBar *)bar
                            peeking:(BOOL)peeking
                           animated:(BOOL)animated;
- (void)applyUserArmedPeekPresentationAnimated:(BOOL)animated;

@end

@interface MLTaskbarController (Bars)

+ (BOOL)isSystemWindowOwner:(NSString *)owner;
- (NSDictionary<NSNumber *, NSScreen *> *)screensByID;
- (CGFloat)barHeightForBar:(MLTaskbarScreenBar *)bar;
- (NSRect)normalFrameForScreen:(NSScreen *)screen height:(CGFloat)height;
- (void)setBar:(MLTaskbarScreenBar *)bar frame:(NSRect)frame animated:(BOOL)animated;
- (MLTaskbarScreenBar *)makeBarForScreen:(NSScreen *)screen;
- (void)syncBarsToScreens;
- (void)scheduleStartupVisibilityRechecks;
- (void)scheduleFullscreenVisibilityCheck;
- (void)updateVisibilitySafetyTimer;
- (NSSet<NSNumber *> *)detectFullscreenScreenIDs;
- (NSSet<NSNumber *> *)detectDesktopRevealScreenIDsExcludingFullscreen:(NSSet<NSNumber *> *)fullscreenIDs;
- (void)refreshFullscreenVisibility;
- (void)applyBarVisibility;
- (BOOL)cocoaPointHitsOwnTaskbar:(NSPoint)cocoaPoint;
- (BOOL)cocoaPointIsExposedDesktop:(NSPoint)cocoaPoint;

@end

@interface MLTaskbarController (WindowActions) <MLTaskbarViewDelegate>

- (void)refreshAfterCustomMinimize;
- (CGWindowID)rememberWindowForCustomMinimizePID:(pid_t)pid
                                           title:(NSString *)title
                                          bounds:(CGRect)bounds
                                        windowID:(CGWindowID)windowID;
- (void)markSoftHiddenWindowID:(CGWindowID)windowID
                           pid:(pid_t)pid
                         title:(NSString *)title
                 restoreFrame:(NSRect)restoreFrame
                     screenID:(NSNumber *)screenID
                     axWindow:(AXUIElementRef)axWindow;
- (void)updateSoftHideMethod:(MLWindowHideMethod)method forWindowID:(CGWindowID)windowID;
- (void)markSoftMinimizedWindowID:(CGWindowID)windowID;
- (BOOL)softMinimizeWindowWithAX:(AXUIElementRef)win
                        windowID:(CGWindowID)windowID
                             pid:(pid_t)pid
                           title:(NSString *)title
                    restoreFrame:(NSRect)restoreFrame;
- (void)softStateDidChange:(NSNotification *)note;
- (MLWindowHideMethod)applySoftHideToWindow:(AXUIElementRef)win
                                   windowID:(CGWindowID)windowID
                                        pid:(pid_t)pid;
- (AXUIElementRef)copyAXWindowForItem:(MLTaskbarItem *)item;
- (BOOL)isItemSoftHiddenOrMinimized:(MLTaskbarItem *)item;
- (BOOL)isItemFrontmostWindow:(MLTaskbarItem *)item;
- (BOOL)softMinimizeItem:(MLTaskbarItem *)item;
- (BOOL)title:(NSString *)full matchesHint:(NSString *)hint;
- (BOOL)frame:(NSRect)frame matchesRestore:(NSRect)restore tolerance:(CGFloat)tol;
- (BOOL)applyRestoreFrame:(NSRect)restoreFrame
                toAXWindow:(AXUIElementRef)target
                  windowID:(CGWindowID)wid
             clearIfMatched:(BOOL)clearIfMatched;
- (void)raiseAndFocusWindowForItem:(MLTaskbarItem *)item;
- (void)activateApplicationForItem:(MLTaskbarItem *)item;
- (void)openApplicationAtPath:(NSString *)path;
- (BOOL)isApplicationRunningAtPath:(NSString *)path;
- (void)activateOrLaunchItem:(MLTaskbarItem *)item;
- (BOOL)readFullscreenForAXWindow:(AXUIElementRef)win;
- (BOOL)canReadFullscreenForAXWindow:(AXUIElementRef)win;
- (void)closeWindowForItem:(MLTaskbarItem *)item;
- (void)toggleMinimizeForItem:(MLTaskbarItem *)item;
- (void)toggleFullscreenForItem:(MLTaskbarItem *)item;

@end

@interface MLTaskbarController (Drag)

- (BOOL)taskbarViewShouldBeginDrag:(MLTaskbarView *)view;
- (void)taskbarView:(MLTaskbarView *)view beganDragAtIndex:(NSInteger)index;
- (void)taskbarView:(MLTaskbarView *)view draggedToScreenPoint:(NSPoint)screenPoint;
- (void)taskbarView:(MLTaskbarView *)view
    endedDragAtScreenPoint:(NSPoint)screenPoint
                 cancelled:(BOOL)cancelled;
- (void)cancelChipDragSession;

@end

NS_ASSUME_NONNULL_END
