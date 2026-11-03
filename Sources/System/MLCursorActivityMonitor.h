#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const MLCursorActivityDidChangeNotification;

/**
 * Detects in-progress Cursor agent work.
 *
 * Cursor windows are titled `<project> - <file>`; the project label is read
 * from each extension-host's `CURSOR_WORKSPACE_LABEL` env var. Busy state comes
 * from `~/.cursor/projects/<slug>/agent-transcripts/<uuid>/<uuid>.jsonl`
 * (last complete JSONL row / incomplete trailer / file growth), with the same
 * agent-tools / terminals / AgentStores side channels used by MeoCursor.
 */
@interface MLCursorActivityMonitor : NSObject

- (BOOL)isBusyForWindowTitle:(nullable NSString *)title;

@property (nonatomic, assign, readonly) BOOL hasAnyBusy;
/// Lowercased open project labels (diagnostics).
@property (copy, readonly) NSSet<NSString *> *openLabels;
/// Lowercased labels with an active turn / tool call.
@property (copy, readonly) NSSet<NSString *> *busyLabels;

- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
