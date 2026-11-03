#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const MLZedActivityDidChangeNotification;

/**
 * Detects in-progress Zed agent work by reading Zed's local thread store
 * (`~/Library/Application Support/Zed/threads/threads.db`).
 *
 * Zed persists a thread when the user sends a prompt and after every model
 * response. An Agent message that still contains any `ToolUse` block means the
 * turn continues (a tool is running or the next response is streaming); a
 * final response has no `ToolUse` blocks. The stored JSON is zstd-compressed,
 * so this monitor links a decoder-only copy of Zstandard.
 */
@interface MLZedActivityMonitor : NSObject

/// Yes when a recent Zed thread in the project matching the window title is
/// generating a response or has a tool call in flight.
- (BOOL)isBusyForWindowTitle:(nullable NSString *)title;

/// Any recent Zed thread is busy.
@property (nonatomic, assign, readonly) BOOL hasAnyBusy;
/// Lowercased project-folder basenames that are busy.
@property (nonatomic, copy, readonly) NSSet<NSString *> *busyFolderNames;

- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
