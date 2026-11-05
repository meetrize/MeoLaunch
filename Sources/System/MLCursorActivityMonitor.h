#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const MLCursorActivityDidChangeNotification;

/**
 * Detects in-progress Cursor agent work.
 *
 * Cursor windows are titled `<project> - <file>`; the project label is read
 * from each extension-host's `CURSOR_WORKSPACE_LABEL` env var.
 *
 * Primary busy signal (Cursor unified Agent UI):
 *   `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
 *   → `cursorDiskKV.composerData:*` (`unfinishedRunAt` / `generatingBubbleIds` /
 *   `chatGenerationUUID` / recent checkpoint), optionally confirmed by
 *   `bubbleId:*` tool rows with `status=loading`.
 *
 * Legacy / side channels (still used when present):
 *   `~/.cursor/projects/<slug>/agent-transcripts/...jsonl`, agent-tools,
 *   terminals, AgentStores WAL growth.
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
