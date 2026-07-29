#import <Cocoa/Cocoa.h>

#include "ml_app_index.h"
#include "ml_grid.h"

@class MLIconCache;

@protocol MLGridViewDelegate <NSObject>
- (void)gridView:(NSView *)gridView didActivateAppAtPath:(NSString *)path;
- (void)gridViewDidClickBackground:(NSView *)gridView;
@optional
- (void)gridView:(NSView *)gridView didChangePage:(NSInteger)page pageCount:(NSInteger)pageCount;
@end

@interface MLGridView : NSView

@property (nonatomic, weak) id<MLGridViewDelegate> delegate;
@property (nonatomic, assign) MLGridConfig gridConfig;
@property (nonatomic, assign) const MLAppIndex *appIndex; /* not owned */
@property (nonatomic, assign) NSInteger currentPage;
@property (nonatomic, strong) MLIconCache *iconCache;
@property (nonatomic, assign) CGFloat wheelThreshold; /* unused for paging; kept for config compat */

/// Filtered app indices into appIndex; NULL means identity 0..count-1.
@property (nonatomic, assign) const uint32_t *visibleIndices;
@property (nonatomic, assign) size_t visibleCount;

/// Selected item in the filtered list; -1 = none.
@property (nonatomic, assign) NSInteger selectedVisibleIndex;

- (void)reloadData;
- (size_t)visibleItemCount;
- (NSInteger)pageCount;
- (void)goToPage:(NSInteger)page;
- (void)nudgePage:(NSInteger)delta;

- (void)selectFirstVisibleItem;
- (void)clearSelection;
- (BOOL)activateSelection;
- (void)moveSelectionByColumns:(NSInteger)dCol rows:(NSInteger)dRow;

/// Icon rect in this view’s coordinates for a visible index; NSZeroRect if unknown.
- (NSRect)iconRectForVisibleIndex:(NSInteger)vis;
- (NSImage *)iconImageForVisibleIndex:(NSInteger)vis;

@end
