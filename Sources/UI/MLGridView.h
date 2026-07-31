#import <Cocoa/Cocoa.h>

#include "ml_app_index.h"
#include "ml_grid.h"
#include "ml_layout.h"

@class MLIconCache;
@class MLGridView;

@protocol MLGridViewDelegate <NSObject>
- (void)gridView:(MLGridView *)gridView didActivateAppAtPath:(NSString *)path;
- (void)gridViewDidClickBackground:(MLGridView *)gridView;
@optional
- (void)gridView:(MLGridView *)gridView didChangePage:(NSInteger)page pageCount:(NSInteger)pageCount;
- (BOOL)gridViewAllowsReorder:(MLGridView *)gridView;
- (void)gridView:(MLGridView *)gridView didReorderFrom:(NSInteger)fromIndex to:(NSInteger)toIndex;
- (void)gridView:(MLGridView *)gridView didMergeItem:(NSInteger)fromIndex ontoItem:(NSInteger)toIndex;
- (void)gridView:(MLGridView *)gridView didAddItem:(NSInteger)fromIndex toFolderAt:(NSInteger)folderIndex;
- (void)gridView:(MLGridView *)gridView didActivateFolderId:(NSString *)folderId;
- (void)gridView:(MLGridView *)gridView didExtractItemAt:(NSInteger)index;
- (void)gridViewDidBeginDragging:(MLGridView *)gridView;
- (void)gridViewDidEndDragging:(MLGridView *)gridView;
- (void)gridView:(MLGridView *)gridView dragMovedToWindowPoint:(NSPoint)windowPoint;
- (BOOL)gridView:(MLGridView *)gridView isExtractDropAtWindowPoint:(NSPoint)windowPoint;
@end

@interface MLGridView : NSView

@property (nonatomic, weak) id<MLGridViewDelegate> delegate;
@property (nonatomic, assign) MLGridConfig gridConfig;
@property (nonatomic, assign) const MLAppIndex *appIndex; /* not owned */
@property (nonatomic, assign) NSInteger currentPage;
@property (nonatomic, strong) MLIconCache *iconCache;
@property (nonatomic, assign) CGFloat wheelThreshold;

/// Search / folder-inner mode: filtered app indices. Ignored when layout != NULL.
@property (nonatomic, assign) const uint32_t *visibleIndices;
@property (nonatomic, assign) size_t visibleCount;

/// Browse mode: show root nodes (apps + folders). Non-NULL takes precedence over visibleIndices.
@property (nonatomic, assign) const MLLayout *layout;

/// When YES (folder interior), dragging outside the grid extracts the app to root.
@property (nonatomic, assign) BOOL allowsExtractOnDragOutside;

@property (nonatomic, assign) NSInteger selectedVisibleIndex;

- (void)reloadData;
- (void)clearFolderCompositeCache;
- (size_t)visibleItemCount;
- (NSInteger)pageCount;
- (void)goToPage:(NSInteger)page;
- (void)nudgePage:(NSInteger)delta;

- (void)selectFirstVisibleItem;
- (void)clearSelection;
- (BOOL)activateSelection;
- (void)moveSelectionByColumns:(NSInteger)dCol rows:(NSInteger)dRow;

- (NSRect)iconRectForVisibleIndex:(NSInteger)vis;
- (NSImage *)iconImageForVisibleIndex:(NSInteger)vis;
- (BOOL)isFolderAtVisibleIndex:(NSInteger)vis;
- (NSString *)folderIdAtVisibleIndex:(NSInteger)vis;

/// Brief spring/glow on a cell after merge or add-to-folder.
- (void)pulseVisibleIndex:(NSInteger)vis;

@end
