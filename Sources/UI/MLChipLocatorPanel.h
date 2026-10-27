#import <Cocoa/Cocoa.h>

@class MLChipLocatorPanel;
@class MLIconCache;

NS_ASSUME_NONNULL_BEGIN

@protocol MLChipLocatorPanelDelegate <NSObject>
- (void)chipLocatorPanelQueryDidChange:(MLChipLocatorPanel *)panel;
- (void)chipLocatorPanel:(MLChipLocatorPanel *)panel didMoveHighlightBy:(NSInteger)delta;
- (void)chipLocatorPanelDidConfirm:(MLChipLocatorPanel *)panel;
- (void)chipLocatorPanelDidCancel:(MLChipLocatorPanel *)panel;
- (void)chipLocatorPanelDidClickShowAll:(MLChipLocatorPanel *)panel;
- (void)chipLocatorPanel:(MLChipLocatorPanel *)panel didClickRow:(NSInteger)row;
/** Mouse hover over a candidate row (or keyboard highlight). */
- (void)chipLocatorPanel:(MLChipLocatorPanel *)panel didHoverCandidateIndex:(NSInteger)index;
@end

/** One list row: section header, candidate, empty placeholder, or show-all footer. */
@interface MLChipLocatorRow : NSObject
@property (nonatomic, assign) BOOL isSectionHeader;
@property (nonatomic, assign) BOOL isShowAllFooter;
@property (nonatomic, assign) BOOL isEmptyPlaceholder;
@property (nonatomic, copy, nullable) NSString *headerTitle;
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy, nullable) NSString *subtitle;
@property (nonatomic, copy, nullable) NSString *iconPath;
@property (nonatomic, assign) NSInteger candidateIndex; /* index into filtered candidates; -1 if n/a */
@property (nonatomic, assign) NSUInteger remainingHiddenCount; /* for show-all footer */
@end

@interface MLChipLocatorPanel : NSPanel <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>

@property (nonatomic, weak) id<MLChipLocatorPanelDelegate> locatorDelegate;
@property (nonatomic, weak) MLIconCache *iconCache;
@property (nonatomic, copy) NSArray<MLChipLocatorRow *> *rows;
@property (nonatomic, assign) NSInteger highlightedCandidateIndex; /* among candidates, not table rows */
@property (nonatomic, copy) NSString *query;
@property (nonatomic, assign, readonly) BOOL showingAll;

- (instancetype)initPanel;
- (void)reloadListKeepingHighlight:(BOOL)keep;
- (void)focusSearchField;
- (void)setShowingAll:(BOOL)showingAll;
- (void)updateEmptyMessage:(nullable NSString *)message;
- (void)layoutForScreen:(NSScreen *)screen;

@end

NS_ASSUME_NONNULL_END
