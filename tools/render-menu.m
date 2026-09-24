// Renders the agent menu with sample sessions into assets/menu.png for the README.
#import "../src/status_item.m"
#include "../tests/ui_stubs.h"

int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 2) return 2;
    [NSApplication sharedApplication];
    MKMenuView *v = [[MKMenuView alloc] initWithFrame:NSMakeRect(0, 0, mk_menu_width, mk_menu_height(4, YES))];
    v.labels = @[@"Fix the login after the update", @"Review the payments PR", @"Move the queue to the new worker", @"Document the scheduling API"];
    v.details = @[@"codex · 42 min · $3.10 · 4.2M tok · Found it: the token expires before the refresh",
                  @"claude · 1 h 05 · $6.48 · 9.8M tok · Review done, two security comments",
                  @"claude · 18 min · $1.22 · 1.4M tok · Running the integration tests",
                  @"claude · 3 h 12 · $12.90 · 21.3M tok · Guide draft published"];
    v.tones = @[@3, @2, @1, @0];
    v.footer = @"Claude 5h 23% · 7d 41%   Codex 5h 6% · 7d 22%";
    v.selected = 0;
    const CGFloat pad = 24, scale = 2;
    const NSSize canvas = NSMakeSize(v.bounds.size.width + 2 * pad, v.bounds.size.height + 2 * pad);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)(canvas.width * scale)
        pixelsHigh:(NSInteger)(canvas.height * scale) bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    rep.size = canvas;
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
    [[[NSGradient alloc] initWithStartingColor:[NSColor colorWithSRGBRed:0.2 green:0.23 blue:0.32 alpha:1]
                                   endingColor:[NSColor colorWithSRGBRed:0.1 green:0.11 blue:0.16 alpha:1]]
        drawInRect:NSMakeRect(0, 0, canvas.width, canvas.height) angle:-90];
    NSAffineTransform *move = [NSAffineTransform transform];
    [move translateXBy:pad yBy:pad];
    [move concat];
    NSBitmapImageRep *menu = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
    [v cacheDisplayInRect:v.bounds toBitmapImageRep:menu];
    [menu drawInRect:v.bounds];
    [NSGraphicsContext restoreGraphicsState];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[1]) atomically:YES];
}}
