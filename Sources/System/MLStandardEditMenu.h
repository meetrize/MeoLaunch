#import <Cocoa/Cocoa.h>

/** Installs a minimal Edit menu so Cmd+A/C/V/X/Z work in LSUIElement apps. */
void MLInstallStandardEditMenu(void);

/** YES for undo/redo/cut/copy/paste/selectAll and common field-editor navigation. */
BOOL MLIsStandardTextEditingCommand(SEL commandSelector);
