// Renders the dictation overlay offscreen into an animated GIF for the README:
// listening to a simulated voice, then deciphering while the text is on its way.
// Build and run with tools/render-overlay.sh.
#import "../src/status_item.m"
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// Hooks status_item.m expects from the rest of the daemon.
void mk_led_status(int s) { (void)s; }
void mk_agents_menu_click(void) {}
void mk_agents_menu_close(void) {}
void mk_agents_menu_open(int i) { (void)i; }
void mk_agents_bottom(void) {}
void mk_agents_menu_open_selected(void) {}
void mk_agents_menu_press(void) {}
void mk_agents_menu_step(int d) { (void)d; }
void mk_agents_next(int d) { (void)d; }
int mk_agents_menu_visible(void) { return 0; }

static double voice(double t) { // syllables with pauses between words
    const double word = fmod(t, 1.1);
    if (word > 0.8) return 0.03;
    return 0.1 + 0.75 * pow(fabs(sin(t * 13)), 1.6) * (0.6 + 0.4 * sin(t * 2.1));
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 2) { fprintf(stderr, "uso: render-overlay <saida.gif>\n"); return 2; }
    [NSApplication sharedApplication];
    const double fps = 25, listen = 3.4, decipher = 5.6;
    const CGFloat scale = 2, pad = 28;
    const NSSize canvas = NSMakeSize(mk_overlay_width + 2 * pad, mk_overlay_height + 2 * pad);
    MKOverlayView *view = [[MKOverlayView alloc] initWithFrame:NSMakeRect(0, 0, mk_overlay_width, mk_overlay_height)];
    NSURL *url = [NSURL fileURLWithPath:@(argv[1])];
    const size_t frames = (size_t)((listen + decipher) * fps);
    CGImageDestinationRef gif = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)UTTypeGIF.identifier, frames, NULL);
    CGImageDestinationSetProperties(gif, (__bridge CFDictionaryRef)@{(id)kCGImagePropertyGIFDictionary: @{(id)kCGImagePropertyGIFLoopCount: @0}});
    NSDictionary *frameProps = @{(id)kCGImagePropertyGIFDictionary: @{(id)kCGImagePropertyGIFDelayTime: @(1 / fps)}};
    [view showMode:1];
    [view.animationTimer invalidate];
    view.animationTimer = nil;
    view.reducedMotion = NO;
    for (size_t f = 0; f < frames; f++) {
        const double t = f / fps, dt = 1 / fps;
        if (t >= listen && view.mode == 1) { [view showMode:2]; [view.animationTimer invalidate]; view.animationTimer = nil; view.reducedMotion = NO; }
        view.phase = t;
        if (view.mode == 2) view.started = mk_now() - (t - listen); // morph follows simulated time
        [view updateAudio:view.mode == 1 ? voice(t) : 0 elapsed:dt];
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
            pixelsWide:(NSInteger)(canvas.width * scale) pixelsHigh:(NSInteger)(canvas.height * scale) bitsPerSample:8
            samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        rep.size = canvas;
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
        [[[NSGradient alloc] initWithStartingColor:[NSColor colorWithSRGBRed:0.2 green:0.23 blue:0.32 alpha:1]
                                       endingColor:[NSColor colorWithSRGBRed:0.1 green:0.11 blue:0.16 alpha:1]]
            drawInRect:NSMakeRect(0, 0, canvas.width, canvas.height) angle:-90];
        NSAffineTransform *move = [NSAffineTransform transform];
        [move translateXBy:pad yBy:pad];
        [move concat];
        [view displayRectIgnoringOpacity:view.bounds inContext:[NSGraphicsContext currentContext]];
        [NSGraphicsContext restoreGraphicsState];
        CGImageDestinationAddImage(gif, rep.CGImage, (__bridge CFDictionaryRef)frameProps);
    }
    const BOOL ok = CGImageDestinationFinalize(gif);
    CFRelease(gif);
    return ok ? 0 : 1;
}}
