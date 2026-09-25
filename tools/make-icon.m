// Draws the Agent Belt app icon: a utility belt whose pouches light up in the
// state colors of the keypad LEDs (red waits for you, green finished, cyan
// transcribing). Regenerate with: tools/make-icon.sh
#import <AppKit/AppKit.h>

static NSColor *rgb(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a];
}

static void glow(NSPoint center, CGFloat radius, NSColor *color) {
    NSGradient *halo = [[NSGradient alloc] initWithStartingColor:[color colorWithAlphaComponent:0.55]
                                                     endingColor:[color colorWithAlphaComponent:0]];
    [halo drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(center.x - radius * 2.2, center.y - radius * 2.2, radius * 4.4, radius * 4.4)]
    relativeCenterPosition:NSZeroPoint];
    [color setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(center.x - radius, center.y - radius, radius * 2, radius * 2)] fill];
    [[NSColor colorWithWhite:1 alpha:0.55] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(center.x - radius * 0.45, center.y + radius * 0.1, radius * 0.6, radius * 0.5)] fill];
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 2) { fprintf(stderr, "usage: make-icon <output.png>\n"); return 2; }
    const CGFloat S = 1024;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:S pixelsHigh:S
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];

    // macOS icon grid: 824 pt squircle centred in 1024 with room for the shadow.
    const NSRect tile = NSMakeRect(100, 100, 824, 824);
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.45];
    shadow.shadowOffset = NSMakeSize(0, -12);
    shadow.shadowBlurRadius = 28;
    [NSGraphicsContext saveGraphicsState];
    [shadow set];
    NSBezierPath *squircle = [NSBezierPath bezierPathWithRoundedRect:tile xRadius:185 yRadius:185];
    [[[NSGradient alloc] initWithStartingColor:rgb(0.16, 0.18, 0.25, 1) endingColor:rgb(0.06, 0.07, 0.1, 1)]
        drawInBezierPath:squircle angle:-90];
    [NSGraphicsContext restoreGraphicsState];
    [rgb(1, 1, 1, 0.08) setStroke];
    squircle.lineWidth = 3;
    [squircle stroke];

    // The strap, slightly curved like a belt worn around the waist.
    NSBezierPath *strap = [NSBezierPath bezierPath];
    [strap moveToPoint:NSMakePoint(100, 470)];
    [strap curveToPoint:NSMakePoint(924, 470) controlPoint1:NSMakePoint(360, 410) controlPoint2:NSMakePoint(664, 410)];
    [strap lineToPoint:NSMakePoint(924, 590)];
    [strap curveToPoint:NSMakePoint(100, 590) controlPoint1:NSMakePoint(664, 530) controlPoint2:NSMakePoint(360, 530)];
    [strap closePath];
    [NSGraphicsContext saveGraphicsState];
    [squircle addClip];
    [[[NSGradient alloc] initWithStartingColor:rgb(0.3, 0.33, 0.42, 1) endingColor:rgb(0.17, 0.19, 0.25, 1)]
        drawInBezierPath:strap angle:-90];
    // Stitching along both edges.
    NSBezierPath *stitch = [NSBezierPath bezierPath];
    [stitch moveToPoint:NSMakePoint(100, 490)];
    [stitch curveToPoint:NSMakePoint(924, 490) controlPoint1:NSMakePoint(360, 432) controlPoint2:NSMakePoint(664, 432)];
    [stitch moveToPoint:NSMakePoint(100, 570)];
    [stitch curveToPoint:NSMakePoint(924, 570) controlPoint1:NSMakePoint(360, 510) controlPoint2:NSMakePoint(664, 510)];
    const CGFloat dash[] = {14, 12};
    [stitch setLineDash:dash count:2 phase:0];
    stitch.lineWidth = 4;
    [rgb(0.62, 0.68, 0.82, 0.45) setStroke];
    [stitch stroke];

    // Pouches hanging from the strap, each with its state light.
    const CGFloat pouchX[] = {200, 690};
    NSColor *lights[] = {rgb(1.0, 0.36, 0.33, 1), rgb(0.32, 0.9, 0.56, 1)};
    for (int i = 0; i < 2; i++) {
        NSRect body = NSMakeRect(pouchX[i], 250, 134, 230);
        NSBezierPath *pouch = [NSBezierPath bezierPathWithRoundedRect:body xRadius:30 yRadius:30];
        [[[NSGradient alloc] initWithStartingColor:rgb(0.24, 0.27, 0.35, 1) endingColor:rgb(0.12, 0.13, 0.18, 1)]
            drawInBezierPath:pouch angle:-90];
        [rgb(1, 1, 1, 0.07) setStroke];
        pouch.lineWidth = 3;
        [pouch stroke];
        NSBezierPath *flap = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(body.origin.x - 6, 400, 146, 84) xRadius:24 yRadius:24];
        [[[NSGradient alloc] initWithStartingColor:rgb(0.34, 0.38, 0.48, 1) endingColor:rgb(0.22, 0.25, 0.32, 1)]
            drawInBezierPath:flap angle:-90];
        glow(NSMakePoint(NSMidX(body), 330), 22, lights[i]);
    }
    [NSGraphicsContext restoreGraphicsState];

    // The buckle, a squircle frame with the cyan "transcribing" light at its heart.
    NSRect buckle = NSMakeRect(412, 402, 200, 200);
    NSBezierPath *frame = [NSBezierPath bezierPathWithRoundedRect:buckle xRadius:54 yRadius:54];
    [frame appendBezierPath:[[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(buckle, 38, 38) xRadius:26 yRadius:26] bezierPathByReversingPath]];
    [NSGraphicsContext saveGraphicsState];
    NSShadow *lift = [NSShadow new];
    lift.shadowColor = [NSColor colorWithWhite:0 alpha:0.5];
    lift.shadowOffset = NSMakeSize(0, -6);
    lift.shadowBlurRadius = 14;
    [lift set];
    [[[NSGradient alloc] initWithColorsAndLocations:rgb(0.96, 0.97, 1, 1), 0.0, rgb(0.66, 0.71, 0.82, 1), 0.55,
                                                    rgb(0.84, 0.87, 0.95, 1), 1.0, nil] drawInBezierPath:frame angle:-70];
    [NSGraphicsContext restoreGraphicsState];
    NSBezierPath *well = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(buckle, 38, 38) xRadius:26 yRadius:26];
    [[[NSGradient alloc] initWithStartingColor:rgb(0.05, 0.06, 0.09, 1) endingColor:rgb(0.12, 0.14, 0.19, 1)] drawInBezierPath:well angle:-90];
    glow(NSMakePoint(NSMidX(buckle), NSMidY(buckle)), 26, rgb(0.35, 0.86, 0.96, 1));

    [NSGraphicsContext restoreGraphicsState];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[1]) atomically:YES];
}}
