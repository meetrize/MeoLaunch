#import "MLPageIndicator.h"

@implementation MLPageIndicator

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _pageCount = 1;
        _currentPage = 0;
        self.wantsLayer = NO;
    }
    return self;
}

- (BOOL)isOpaque {
    return NO;
}

- (void)setPageCount:(NSInteger)pageCount {
    if (pageCount < 1) {
        pageCount = 1;
    }
    _pageCount = pageCount;
    if (_currentPage >= _pageCount) {
        _currentPage = _pageCount - 1;
    }
    self.hidden = (_pageCount <= 1);
    [self setNeedsDisplay:YES];
}

- (void)setCurrentPage:(NSInteger)currentPage {
    if (currentPage < 0) {
        currentPage = 0;
    }
    if (_pageCount > 0 && currentPage >= _pageCount) {
        currentPage = _pageCount - 1;
    }
    _currentPage = currentPage;
    [self setNeedsDisplay:YES];
}

- (void)updateWithPage:(NSInteger)page pageCount:(NSInteger)pageCount {
    if (pageCount < 1) {
        pageCount = 1;
    }
    if (page < 0) {
        page = 0;
    }
    if (page >= pageCount) {
        page = pageCount - 1;
    }
    _pageCount = pageCount;
    _currentPage = page;
    self.hidden = (pageCount <= 1);
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    if (self.pageCount <= 1) {
        return;
    }

    CGFloat diameter = 9.0;
    CGFloat gap = 12.0;
    CGFloat totalW = self.pageCount * diameter + (self.pageCount - 1) * gap;
    CGFloat x = NSMidX(self.bounds) - totalW * 0.5;
    CGFloat y = NSMidY(self.bounds) - diameter * 0.5;

    for (NSInteger i = 0; i < self.pageCount; i++) {
        NSRect r = NSMakeRect(x + i * (diameter + gap), y, diameter, diameter);
        NSBezierPath *path = [NSBezierPath bezierPathWithOvalInRect:r];
        if (i == self.currentPage) {
            [[NSColor whiteColor] setFill];
        } else {
            [[[NSColor whiteColor] colorWithAlphaComponent:0.40] setFill];
        }
        [path fill];
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];

    if (self.pageCount > 1) {
        CGFloat diameter = 9.0;
        CGFloat gap = 12.0;
        CGFloat hitPad = 6.0;
        CGFloat totalW = self.pageCount * diameter + (self.pageCount - 1) * gap;
        CGFloat x0 = NSMidX(self.bounds) - totalW * 0.5;
        CGFloat y = NSMidY(self.bounds) - diameter * 0.5;

        for (NSInteger i = 0; i < self.pageCount; i++) {
            NSRect r = NSMakeRect(x0 + i * (diameter + gap) - hitPad,
                                  y - hitPad,
                                  diameter + hitPad * 2,
                                  diameter + hitPad * 2);
            if (NSPointInRect(p, r)) {
                [self.delegate pageIndicator:self didSelectPage:i];
                return;
            }
        }
    }

    if ([self.delegate respondsToSelector:@selector(pageIndicatorDidClickBackground:)]) {
        [self.delegate pageIndicatorDidClickBackground:self];
    }
}

@end
