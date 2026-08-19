#import <Cocoa/Cocoa.h>

/** Borderless NSWindow cannot become key by default — required for search typing. */
@interface MLOverlayWindow : NSWindow

/**
 * Shared, owned field editor for overlay text fields.
 * Always transparent — AppKit's default editor can show an opaque / material
 * chrome on a clear key window (the intermittent "ghost panel" under search).
 */
- (NSTextView *)ml_styledFieldEditor;

/** Existing owned editor, or nil if AppKit has not requested one yet. */
- (NSTextView *)ml_ownedFieldEditorIfAny;

/** Re-apply transparent chrome (safe to call often while editing). */
- (void)ml_restyleFieldEditor;

/** Search / folder title that should host (and clip) the field editor. */
- (void)ml_setHostSearchField:(NSTextField *)field titleField:(NSTextField *)titleField;

/** Fit field editor / focus clip inside the active host (in-place; never reparent out of AppKit clip). */
- (void)ml_pinFieldEditorToHostField;

@end
