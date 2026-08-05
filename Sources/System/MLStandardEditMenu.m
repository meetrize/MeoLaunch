#import "MLStandardEditMenu.h"

void MLInstallStandardEditMenu(void) {
    NSMenu *mainMenu = [NSApp mainMenu];
    if (!mainMenu) {
        mainMenu = [[NSMenu alloc] init];
        [NSApp setMainMenu:mainMenu];
    }

    for (NSMenuItem *item in mainMenu.itemArray) {
        if ([item.title isEqualToString:@"Edit"] ||
            [item.title isEqualToString:@"编辑"] ||
            [item.title isEqualToString:@"編輯"]) {
            return;
        }
    }

    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:NULL keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    [[editMenu itemAtIndex:0] setKeyEquivalentModifierMask:NSEventModifierFlagCommand];

    NSMenuItem *redo = [editMenu addItemWithTitle:@"Redo"
                                           action:@selector(redo:)
                                    keyEquivalent:@"Z"];
    [redo setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagShift];

    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Delete" action:@selector(delete:) keyEquivalent:@""];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];

    editItem.submenu = editMenu;
    [mainMenu addItem:editItem];
}

BOOL MLIsStandardTextEditingCommand(SEL commandSelector) {
    return commandSelector == @selector(selectAll:)
        || commandSelector == @selector(cut:)
        || commandSelector == @selector(copy:)
        || commandSelector == @selector(paste:)
        || commandSelector == @selector(pasteAsPlainText:)
        || commandSelector == @selector(undo:)
        || commandSelector == @selector(redo:)
        || commandSelector == @selector(delete:)
        || commandSelector == @selector(deleteBackward:)
        || commandSelector == @selector(deleteForward:)
        || commandSelector == @selector(cancelOperation:)
        || commandSelector == @selector(moveLeft:)
        || commandSelector == @selector(moveRight:)
        || commandSelector == @selector(moveUp:)
        || commandSelector == @selector(moveWordLeft:)
        || commandSelector == @selector(moveWordRight:)
        || commandSelector == @selector(moveToBeginningOfLine:)
        || commandSelector == @selector(moveToEndOfLine:)
        || commandSelector == @selector(moveToBeginningOfParagraph:)
        || commandSelector == @selector(moveToEndOfParagraph:)
        || commandSelector == @selector(deleteWordBackward:)
        || commandSelector == @selector(deleteWordForward:)
        || commandSelector == @selector(insertTab:)
        || commandSelector == @selector(insertBacktab:);
}
