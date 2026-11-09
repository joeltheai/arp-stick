#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import "macos.h"
#include <math.h>
#include <string.h>

// ---------------------------------------------------------------------------
// Shared industrial-style editor. The layout follows the JSFX ArpStick panel:
// 960 x 640 logical points, scaled to the available view.
// ---------------------------------------------------------------------------

enum {
    MOD_SHIFT = 1 << 0,
    MOD_COMMAND = 1 << 1,
    MOD_ALT = 1 << 2,
};

@interface ArpStickEditorView : NSView {
@public
    ArpStickUIConfig _config;
    CGFloat _sc, _ox, _oy;
    int _drag;
    int _dragVoice;
    double _dragV0;
    double _dragY0;
    int _dragCol;
    int _dragPatternFrom;
    int _menu; // 1 chord menu, 2 chord presets, 3 arp presets
    double _menuX, _menuY;
    int _keyScroll;
    int _nameEditing;
    int _nameLen;
    NSTimer *_timer;
}
- (instancetype)initWithConfig:(const ArpStickUIConfig *)config;
- (void)refresh;
- (void)testClickX:(double)x y:(double)y mods:(uint32_t)mods;
- (void)testDragX:(double)x y:(double)y mods:(uint32_t)mods;
- (void)testReleaseX:(double)x y:(double)y mods:(uint32_t)mods;
- (void)testKey:(uint32_t)key;
- (void)importMidiAtPath:(NSString *)path;
@end

static NSColor *C(int r, int g, int b) {
    return [NSColor colorWithSRGBRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1];
}
static NSColor *CA(int r, int g, int b, double a) {
    return [NSColor colorWithSRGBRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}

static NSGradient *G(int r1, int g1, int b1, int r2, int g2, int b2) {
    return [[NSGradient alloc] initWithStartingColor:C(r1, g1, b1) endingColor:C(r2, g2, b2)];
}

@implementation ArpStickEditorView
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }

- (instancetype)initWithConfig:(const ArpStickUIConfig *)config {
    self = [super initWithFrame:NSMakeRect(0, 0, 960, 640)];
    if (!self) return nil;
    _config = *config;
    _keyScroll = 3;
    _drag = 0;
    self.wantsLayer = YES;
    self.layer.backgroundColor = C(20, 20, 20).CGColor;
    return self;
}

- (void)dealloc { [_timer invalidate]; }

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    [_timer invalidate];
    _timer = nil;
    if (!hidden) {
        [self refresh];
        __weak ArpStickEditorView *weakSelf = self;
        _timer = [NSTimer timerWithTimeInterval:1.0 / 30.0 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            ArpStickEditorView *s = weakSelf;
            if (s) [s setNeedsDisplay:YES];
        }];
        [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    }
}
- (void)refresh { [self setNeedsDisplay:YES]; }

// ---- backend helpers ----
static int32_t field(ArpStickEditorView *v, uint32_t f, uint32_t a, uint32_t b) {
    return v->_config.read_field(v->_config.context, f, a, b);
}
static void writeField(ArpStickEditorView *v, uint32_t f, uint32_t a, uint32_t b, int32_t value) {
    (void)v->_config.write_field(v->_config.context, f, a, b, value);
}
static int32_t param(ArpStickEditorView *v, uint32_t id) {
    return v->_config.read_param(v->_config.context, id);
}
static void setParam(ArpStickEditorView *v, uint32_t id, int32_t value) {
    (void)v->_config.write_param(v->_config.context, id, value);
}
static void act(ArpStickEditorView *v, uint32_t action, int32_t a, int32_t b) {
    (void)v->_config.action(v->_config.context, action, a, b);
}
static NSString *textAt(ArpStickEditorView *v, uint32_t kind, uint32_t a, uint32_t b) {
    char buf[160] = {0};
    v->_config.read_text(v->_config.context, kind, a, b, buf, sizeof(buf));
    return [NSString stringWithUTF8String:buf] ?: @"";
}

// ---- drawing primitives ----
static void rect(NSRect r, NSColor *c) {
    [c setFill];
    NSRectFill(r);
}
static void plate(NSRect r, int t1, int g1, int b1, int t2, int g2, int b2) {
    [G(t1, g1, b1, t2, g2, b2) drawInRect:r angle:90];
    [CA(74, 74, 74, 0.75) setStroke];
    NSFrameRect(r);
}
static void well(NSRect r) {
    [G(21, 21, 21, 11, 11, 11) drawInRect:r angle:90];
    [CA(15, 15, 15, 0.9) setStroke];
    NSFrameRect(r);
}
static void cap(NSRect r, BOOL on, BOOL pressed) {
    if (on) [G(87, 167, 255, 28, 80, 146) drawInRect:r angle:90];
    else [G(58, 58, 58, 30, 30, 30) drawInRect:r angle:90];
    [CA(pressed ? 15 : 120, pressed ? 15 : 120, pressed ? 15 : 120, 0.9) setStroke];
    NSFrameRect(r);
}
static void frameOutline(NSRect r, NSColor *c) {
    [c setStroke];
    NSFrameRect(r);
}
static void circle(double x, double y, double radius, NSColor *c) {
    NSBezierPath *p = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x - radius, y - radius, radius * 2, radius * 2)];
    [c setFill];
    [p fill];
}
static void gmLine(double x1, double y1, double x2, double y2, NSColor *c) {
    NSBezierPath *p = [NSBezierPath bezierPath];
    p.lineWidth = 1.4;
    [p moveToPoint:NSMakePoint(x1, y1)];
    [p lineToPoint:NSMakePoint(x2, y2)];
    [c setStroke];
    [p stroke];
}
static void text(NSString *s, double x, double y, double w, double h, double size, NSColor *c, NSTextAlignment align) {
    NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];
    p.alignment = align;
    p.lineBreakMode = NSLineBreakByClipping;
    [s drawInRect:NSMakeRect(x, y, w, h) withAttributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:size weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: c,
        NSParagraphStyleAttributeName: p,
    }];
}
static void centerText(NSString *s, double x, double y, double w, double h, double size, NSColor *c) {
    text(s, x, y, w, h, size, c, NSTextAlignmentCenter);
}

- (void)drawButton:(NSRect)r label:(NSString *)label on:(BOOL)on {
    cap(r, on, on);
    centerText(label, r.origin.x, r.origin.y + 2, r.size.width, r.size.height - 2, 10,
               on ? NSColor.whiteColor : C(220, 220, 220));
}
- (void)drawLed:(double)x y:(double)y radius:(double)r color:(NSColor *)color lit:(BOOL)lit {
    if (lit) {
        circle(x, y, r * 2.2, [color colorWithAlphaComponent:0.12]);
        circle(x, y, r, color);
        circle(x - r * 0.3, y - r * 0.3, r * 0.3, CA(255, 255, 255, 0.75));
    } else {
        circle(x, y, r, CA(18, 52, 99, 1));
        circle(x, y, r * 0.5, CA(5, 5, 5, 0.7));
    }
}

- (void)drawKnob:(NSPoint)center radius:(double)r value:(double)value min:(double)vmin max:(double)vmax {
    circle(center.x + 2, center.y + 2, r, CA(5, 5, 5, 0.55));
    NSBezierPath *body = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(center.x - r, center.y - r, r * 2, r * 2)];
    [G(74, 74, 74, 30, 30, 30) drawInBezierPath:body angle:90];
    circle(center.x, center.y, r * 0.78, C(42, 42, 42));
    double t = (value - vmin) / MAX(vmax - vmin, 0.0001);
    for (int i = 0; i <= 12; i++) {
        double a = -0.75 * M_PI + (i / 12.0) * 1.5 * M_PI;
        NSColor *c = (i / 12.0 <= t + 0.0001) ? C(255, 147, 0) : CA(15, 15, 15, 0.7);
        gmLine(center.x + cos(a) * r * 0.86, center.y + sin(a) * r * 0.86,
               center.x + cos(a) * r, center.y + sin(a) * r, c);
    }
    double a = t * 1.5 * M_PI - 0.75 * M_PI;
    gmLine(center.x - cos(a) * r * 0.2, center.y - sin(a) * r * 0.2,
           center.x + cos(a) * r * 0.55, center.y + sin(a) * r * 0.55, C(255, 147, 0));
}

- (void)drawNoteSymbol:(NSRect)r value:(int)v {
    if (v < 0) return;
    double cx = NSMidX(r);
    double top = r.origin.y + 4, bot = NSMaxY(r) - 4;
    if (v < 8) {
        centerText([NSString stringWithFormat:@"%d", v + 1], r.origin.x, NSMidY(r) - 7, r.size.width, 16, 11, C(150, 245, 156));
        return;
    }
    NSColor *blue = C(144, 216, 255);
    switch (v) {
        case 8:
            gmLine(cx, bot, cx, top, blue);
            gmLine(cx - 4, top + 6, cx, top, blue);
            gmLine(cx + 4, top + 6, cx, top, blue);
            break;
        case 9:
            gmLine(cx, top, cx, bot, blue);
            gmLine(cx - 4, bot - 6, cx, bot, blue);
            gmLine(cx + 4, bot - 6, cx, bot, blue);
            break;
        case 10:
            gmLine(cx, top, cx, bot, blue);
            gmLine(cx - 4, top + 6, cx, top, blue);
            gmLine(cx + 4, top + 6, cx, top, blue);
            gmLine(cx - 4, bot - 6, cx, bot, blue);
            gmLine(cx + 4, bot - 6, cx, bot, blue);
            break;
        case 11:
            gmLine(cx, top, cx, bot, blue);
            gmLine(cx - 4, top, cx, top + 6, blue);
            gmLine(cx + 4, top, cx, top + 6, blue);
            gmLine(cx - 4, bot, cx, bot - 6, blue);
            gmLine(cx + 4, bot, cx, bot - 6, blue);
            break;
        case 12:
            gmLine(cx - 5, top, cx + 5, top, blue);
            gmLine(cx, top + 2, cx, bot - 2, blue);
            gmLine(cx - 5, bot, cx + 5, bot, blue);
            break;
        case 13:
            gmLine(cx - 5, top, cx + 5, top, blue);
            gmLine(cx, top + 2, cx, bot - 2, blue);
            gmLine(cx - 5, bot, cx + 5, bot, blue);
            break;
        case 14:
            gmLine(cx - 4, top, cx + 4, top, blue);
            gmLine(r.origin.x + 3, bot - 3, cx, top + 4, blue);
            gmLine(cx, top + 4, NSMaxX(r) - 3, bot - 3, blue);
            break;
        default:
            gmLine(cx - 4, bot, cx + 4, bot, blue);
            gmLine(r.origin.x + 3, top + 3, cx, bot - 4, blue);
            gmLine(cx, bot - 4, NSMaxX(r) - 3, top + 3, blue);
            break;
    }
}

// ---- main drawing ----
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect bounds = self.bounds;
    _sc = MIN(bounds.size.width / 960.0, bounds.size.height / 640.0);
    _sc = MAX(0.01, _sc);
    _ox = (bounds.size.width - 960 * _sc) / 2;
    _oy = (bounds.size.height - 640 * _sc) / 2;

    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, _ox, _oy);
    CGContextScaleCTM(ctx, _sc, _sc);

    [G(44, 44, 44, 25, 25, 25) drawInRect:NSMakeRect(0, 0, 960, 640) angle:90];

    int32_t pattern = param(self, 7);
    uint32_t rate = (uint32_t)field(self, ARP_FIELD_RATE, 0, 0);
    BOOL arpOn = param(self, 1) != 0;
    BOOL chordOn = param(self, 0) != 0;
    BOOL latch = param(self, 3) != 0;
    BOOL freeOn = field(self, ARP_FIELD_FREE_ON, 0, 0) != 0;
    uint32_t lane = (uint32_t)field(self, ARP_FIELD_CUR_GRAPH, 0, 0);
    BOOL playing = field(self, ARP_FIELD_PLAYING, 0, 0) != 0;
    int lastFired = field(self, ARP_FIELD_LAST_FIRED, 0, 0);
    int64_t lastOut = field(self, ARP_FIELD_LAST_OUT, 0, 0);
    uint32_t curSlot = (uint32_t)field(self, ARP_FIELD_CUR_SLOT, 0, 0);
    BOOL learning = field(self, ARP_FIELD_LEARNING, 0, 0) != 0;
    BOOL watchOn = field(self, ARP_FIELD_WATCH_ON, 0, 0) != 0;

    // ---- top bar ----
    plate(NSMakeRect(0, 0, 960, 26), 54, 54, 54, 30, 30, 30);
    text(@"ARPSTICK", 12, 3, 90, 18, 15, NSColor.whiteColor, NSTextAlignmentLeft);
    text(@"chord player + pattern arp", 88, 10, 180, 12, 8, C(150, 158, 170), NSTextAlignmentLeft);
    [self drawLed:240 y:13 radius:2.6 color:C(57, 157, 255) lit:YES];
    [self drawLed:256 y:13 radius:2.6 color:C(255, 147, 0) lit:(playing || freeOn) && arpOn];
    [self drawButton:NSMakeRect(300, 5, 56, 16) label:@"CHORD" on:chordOn];
    [self drawButton:NSMakeRect(390, 5, 56, 16) label:@"ARP" on:arpOn];
    [self drawButton:NSMakeRect(480, 5, 56, 16) label:@"LATCH" on:latch];
    [self drawButton:NSMakeRect(550, 3, 70, 20) label:[NSString stringWithFormat:@"TONE %d%%", param(self, 4)] on:NO];
    int trans = (int)param(self, 2);
    [self drawButton:NSMakeRect(628, 3, 70, 20) label:[NSString stringWithFormat:@"TRANS %+d", trans] on:NO];
    int32_t outCh = param(self, 5);
    [self drawButton:NSMakeRect(710, 5, 112, 16)
               label:(outCh == 0 ? @"OUT: INPUT" : [NSString stringWithFormat:@"OUT: CH %d", outCh])
                  on:outCh > 0];
    [self drawButton:NSMakeRect(830, 5, 122, 16)
               label:(param(self, 6) ? @"MIDI REMOTE: ON" : @"MIDI REMOTE: OFF")
                  on:param(self, 6) != 0];

    // ---- pattern bank ----
    for (int p = 0; p < 12; p++) {
        double bx = 8 + (p % 2) * 54;
        double by = 34 + (p / 2) * 24;
        BOOL active = (pattern == p);
        BOOL used = field(self, ARP_FIELD_PATTERN_USED, (uint32_t)p, 0) != 0;
        cap(NSMakeRect(bx, by, 46, 18), active, active);
        if (active || used) [self drawLed:bx + 7 y:by + 9 radius:2.2 color:C(57, 157, 255) lit:YES];
        centerText([NSString stringWithFormat:@"%c", 'A' + p], bx + (active ? 15 : 8), by + 3, 28, 14, 10,
                   active ? C(229, 229, 229) : C(170, 170, 170));
    }
    NSString *patternName = textAt(self, ARP_TEXT_PATTERN_NAME, (uint32_t)pattern, 0);
    if (_nameEditing) patternName = [patternName stringByAppendingString:@"_"];
    text(patternName, 8, 174, 150, 14, 9, C(200, 200, 200), NSTextAlignmentLeft);
    [self drawButton:NSMakeRect(8, 186, 42, 15) label:@"COPY" on:NO];
    [self drawButton:NSMakeRect(54, 186, 42, 15) label:@"PASTE" on:NO];
    [self drawButton:NSMakeRect(100, 186, 42, 15) label:@"RAND" on:NO];
    text(@"DIV", 8, 208, 24, 12, 8, C(158, 158, 158), NSTextAlignmentLeft);
    well(NSMakeRect(34, 205, 26, 15));
    centerText([NSString stringWithFormat:@"%d", field(self, ARP_FIELD_DIV, lane, 0)], 34, 207, 26, 12, 9, C(255, 147, 0));
    text(@"RATE", 52, 235, 40, 12, 8, C(158, 158, 158), NSTextAlignmentLeft);
    [self drawKnob:NSMakePoint(26, 246) radius:17 value:rate min:0 max:15];
    centerText(textAt(self, ARP_TEXT_RATE, rate, 0), 0, 264, 52, 12, 8, C(222, 222, 222));
    [self drawButton:NSMakeRect(8, 292, 40, 14) label:@"FREE" on:freeOn];
    [self drawKnob:NSMakePoint(26, 318) radius:10 value:field(self, ARP_FIELD_FREE_HZ, 0, 0) / 100.0 min:0.05 max:40];
    centerText([NSString stringWithFormat:@"%.1fHz", field(self, ARP_FIELD_FREE_HZ, 0, 0) / 100.0], 0, 330, 52, 12, 8, C(222, 222, 222));
    [self drawButton:NSMakeRect(8, 348, 48, 14) label:@"RETRIG" on:field(self, ARP_FIELD_RETRIG, 0, 0) != 0];
    [self drawButton:NSMakeRect(62, 348, 48, 14) label:@"LINK" on:field(self, ARP_FIELD_LINK, 0, 0) != 0];
    [self drawButton:NSMakeRect(116, 348, 54, 14) label:@"CHRD" on:field(self, ARP_FIELD_CHORD_MODE, 0, 0) != 0];
    [self drawButton:NSMakeRect(8, 366, 96, 16) label:@"ARP PRESET >" on:NO];
    [self drawKnob:NSMakePoint(102, 250) radius:14 value:field(self, ARP_FIELD_SWING, 0, 0) min:0 max:75];
    centerText([NSString stringWithFormat:@"SWING %d%%", field(self, ARP_FIELD_SWING, 0, 0)], 52, 269, 100, 12, 9, C(214, 221, 232));

    // ---- lane tabs ----
    const char *tabNames[8] = {"NOTE", "RAND", "OCT", "PITCH", "VEL", "GATE", "LATE", "HARM"};
    for (int t = 0; t < 8; t++) {
        BOOL on = (lane == (uint32_t)t);
        cap(NSMakeRect(178 + t * 76, 28, 72, 16), on, on);
        centerText([NSString stringWithUTF8String:tabNames[t]], 178 + t * 76, 31, 72, 13, 9,
                   on ? C(229, 229, 229) : C(180, 180, 180));
    }

    // ---- grid ----
    well(NSMakeRect(178, 48, 672, 296));
    int laneLen = field(self, ARP_FIELD_LEN, lane, 0);
    int laneDiv = MAX(1, field(self, ARP_FIELD_DIV, lane, 0));
    int activeStep = -1;
    if (lastFired >= 0 && playing && arpOn)
        activeStep = (lastFired / laneDiv) % MAX(1, laneLen);
    for (int col = 0; col < 16; col++) {
        BOOL beyond = col >= laneLen;
        BOOL muted = field(self, ARP_FIELD_MUTE, 0, col) != 0;
        NSColor *columnColor = beyond ? C(21, 21, 21) : (col == activeStep ? C(76, 62, 42) : C(42, 42, 42));
        rect(NSMakeRect(178 + col * 42 + 1, 48, 40, 296), muted ? C(21, 21, 21) : columnColor);
        rect(NSMakeRect(178 + col * 42 + 1, 48, 1, 296), CA(15, 15, 15, 0.7));
        int v = field(self, ARP_FIELD_CELL, lane, col);
        if (lane == 0) {
            [self drawNoteSymbol:NSMakeRect(178 + col * 42 + 4, 145, 34, 70) value:v];
            NSString *label = v < 0 ? @"REST" : v < 8 ? [NSString stringWithFormat:@"%d", v + 1]
                : v == 8 ? @"UP" : v == 9 ? @"DOWN" : v == 10 ? @"U/D" : v == 11 ? @"D/U"
                : v == 12 ? @"U+D" : v == 13 ? @"D+U" : v == 14 ? @"TOP" : @"BOT";
            centerText(label, 178 + col * 42, 234, 42, 14, 9, C(144, 216, 255));
            if (field(self, ARP_FIELD_RESET, 0, col)) {
                gmLine(178 + col * 42 + 17, 340, 178 + col * 42 + 25, 340, C(144, 216, 255));
                gmLine(178 + col * 42 + 25, 340, 178 + col * 42 + 21, 332, C(144, 216, 255));
                gmLine(178 + col * 42 + 21, 332, 178 + col * 42 + 17, 340, C(144, 216, 255));
            }
        } else {
            double cy = 48 + 148;
            double bar = 0;
            if (lane == 1 || lane == 2) bar = v / 8.0 * 148;
            else if (lane == 3 || lane == 7) bar = v / 12.0 * 148;
            else if (lane == 6) bar = v / 100.0 * 148;
            if (lane == 4) {
                double h = v / 200.0 * 296;
                rect(NSMakeRect(178 + col * 42 + 14, 48 + 296 - h, 14, h), C(46, 134, 254));
                gmLine(178 + col * 42 + 2, cy, 178 + col * 42 + 40, cy, CA(15, 15, 15, 0.8));
            } else if (lane == 5) {
                rect(NSMakeRect(178 + col * 42 + 14, 48, 14, v / 100.0 * 296), C(46, 134, 254));
            } else {
                gmLine(178 + col * 42 + 2, cy, 178 + col * 42 + 40, cy, CA(15, 15, 15, 0.8));
                if (bar >= 0) rect(NSMakeRect(178 + col * 42 + 14, cy - bar, 14, bar), C(46, 134, 254));
                else rect(NSMakeRect(178 + col * 42 + 14, cy, 14, -bar), C(46, 134, 254));
                if (v != 0) centerText([NSString stringWithFormat:@"%+d", v], 178 + col * 42, cy - bar - 14, 42, 12, 8, C(222, 222, 222));
            }
        }
    }
    // length marker
    int len = field(self, ARP_FIELD_LEN, lane, 0);
    double lx = 178 + len * 42;
    rect(NSMakeRect(lx - 2, 48, 5, 296), CA(46, 134, 254, 0.13));
    rect(NSMakeRect(lx - 1, 48, 2, 296), CA(46, 134, 254, 0.95));

    // mutes / hints
    if (lane == 0) {
        for (int col = 0; col < 16; col++) {
            BOOL m = field(self, ARP_FIELD_MUTE, 0, col) != 0;
            cap(NSMakeRect(178 + col * 42 + 4, 348, 34, 15), m, m);
            centerText(m ? @"x" : [NSString stringWithFormat:@"%d", col + 1], 178 + col * 42 + 4, 350, 34, 13, 8,
                       m ? NSColor.whiteColor : C(180, 180, 180));
        }
        text(@"mutes", 862, 352, 60, 12, 8, C(158, 158, 158), NSTextAlignmentLeft);
        text(@"arrows: up / down / up-down / down-up / bars = extremes / zigzag = fingered / 1-8 = chord notes low to high",
             178, 370, 660, 12, 8, C(172, 172, 172), NSTextAlignmentLeft);
    } else {
        NSString *hint = lane == 3 ? @"pitch shifts only notes whose degree is enabled ->"
            : lane == 4 ? @"step velocity scaling 0-200%"
            : lane == 5 ? @"gate: step duration (100% = tie)"
            : lane == 6 ? @"late/early step offset"
            : lane == 1 ? @"random note-selection offset"
            : lane == 2 ? @"octave transposition per step"
            : @"second note per step, relative";
        text(hint, 178, 370, 660, 12, 8, C(172, 172, 172), NSTextAlignmentLeft);
    }

    // ---- constraints ----
    text(@"BLOCK", 858, 28, 60, 12, 8, C(180, 180, 180), NSTextAlignmentLeft);
    for (int pc = 0; pc < 12; pc++) {
        int st = field(self, ARP_FIELD_CONSTRAINT, pc, 0);
        cap(NSMakeRect(858, 48 + pc * 21, 30, 19), st != 0, st != 0);
        text(textAt(self, ARP_TEXT_NOTE, pc, 0), 862, 52 + pc * 21, 24, 12, 8,
             st == 0 ? C(180, 180, 180) : NSColor.whiteColor, NSTextAlignmentLeft);
        if (st == 1) centerText(@"x", 872, 50 + pc * 21, 16, 14, 9, NSColor.whiteColor);
        if (st == 2) centerText(@">", 872, 50 + pc * 21, 16, 14, 9, NSColor.whiteColor);
        if (st == 3) centerText(@"<", 872, 50 + pc * 21, 16, 14, 9, NSColor.whiteColor);
    }
    if (lane == 3) {
        text(@"DEG", 894, 28, 40, 12, 8, C(180, 180, 180), NSTextAlignmentLeft);
        for (int d = 0; d < 7; d++) {
            BOOL on = field(self, ARP_FIELD_PEN, d, 0) != 0;
            cap(NSMakeRect(894, 48 + d * 15, 22, 14), on, on);
            centerText([NSString stringWithFormat:@"%d", d + 1], 894, 50 + d * 15, 22, 12, 8,
                       on ? NSColor.whiteColor : C(180, 180, 180));
        }
    }
    text(@"OUT", 894, 178, 40, 12, 8, C(180, 180, 180), NSTextAlignmentLeft);
    well(NSMakeRect(894, 190, 58, 24));
    centerText(lastOut >= 0 && lastOut <= 127 ? textAt(self, ARP_TEXT_NOTE, (uint32_t)lastOut, 0) : @"-",
               894, 194, 58, 16, 11, C(255, 147, 0));

    // ---- chord section ----
    text(@"CHORD SLOT", 8, 394, 100, 12, 8, C(180, 180, 180), NSTextAlignmentLeft);
    well(NSMakeRect(8, 404, 150, 54));
    NSString *slotNote = textAt(self, ARP_TEXT_NOTE, curSlot, 0);
    centerText([NSString stringWithFormat:@"%@  (%u)", slotNote, curSlot], 8, 410, 150, 14, 10, C(255, 147, 0));
    centerText(textAt(self, ARP_TEXT_CHORD_NAME, curSlot, 0), 8, 434, 150, 20, 13, NSColor.whiteColor);
    [self drawButton:NSMakeRect(8, 474, 64, 16) label:@"MENU" on:NO];
    [self drawButton:NSMakeRect(78, 474, 64, 16) label:@"PRESETS" on:NO];
    [self drawButton:NSMakeRect(8, 496, 46, 15) label:learning ? @"LEARN*" : @"LEARN" on:learning];
    [self drawButton:NSMakeRect(58, 496, 46, 15) label:@"COPY" on:NO];
    [self drawButton:NSMakeRect(108, 496, 46, 15) label:@"PASTE" on:NO];
    [self drawButton:NSMakeRect(158, 496, 46, 15) label:@"RAND" on:NO];
    [self drawButton:NSMakeRect(208, 496, 24, 15) label:@"eye" on:watchOn];
    [self drawButton:NSMakeRect(8, 580, 145, 18) label:@"IMPORT MIDI FILE" on:NO];

    for (int v = 0; v < 8; v++) {
        double vx = 8 + v * 30;
        centerText([NSString stringWithFormat:@"%d", v + 1], vx, 512, 26, 12, 8, C(172, 172, 172));
        well(NSMakeRect(vx, 526, 26, 16));
        int n = field(self, ARP_FIELD_CHORD_NOTE, curSlot, v);
        centerText(n >= 0 ? textAt(self, ARP_TEXT_NOTE, n, 0) : @"off", vx, 528, 26, 14, 8,
                   n >= 0 ? C(255, 147, 0) : CA(74, 42, 0, 1));
        well(NSMakeRect(vx, 544, 26, 18));
        centerText([NSString stringWithFormat:@"%d%%", field(self, ARP_FIELD_CHORD_VEL, curSlot, v)],
                   vx, 548, 26, 14, 8, C(255, 147, 0));
        BOOL lock = field(self, ARP_FIELD_LOCK_ON, v, 0) != 0;
        cap(NSMakeRect(vx, 566, 26, 14), lock, lock);
        centerText(@"L", vx, 568, 26, 12, 8, lock ? NSColor.whiteColor : C(172, 172, 172));
    }

    // piano
    well(NSMakeRect(252, 394, 692, 202));
    [self drawButton:NSMakeRect(260, 398, 26, 16) label:@"<" on:NO];
    [self drawButton:NSMakeRect(450, 398, 26, 16) label:@">" on:NO];
    well(NSMakeRect(292, 398, 146, 16));
    NSString *range = [NSString stringWithFormat:@"%@..%@", textAt(self, ARP_TEXT_NOTE, _keyScroll * 12, 0),
                       textAt(self, ARP_TEXT_NOTE, _keyScroll * 12 + 35, 0)];
    centerText(range, 292, 400, 146, 14, 9, C(255, 147, 0));

    static const int white[7] = {0, 2, 4, 5, 7, 9, 11};
    static const int blackStep[6] = {0, 2, 4, 5, 7, 9};
    int learnCount = field(self, ARP_FIELD_LEARN_COUNT, 0, 0);
    // blips
    for (int o = 0; o < 3; o++) {
        for (int w = 0; w < 7; w++) {
            int n = _keyScroll * 12 + o * 12 + white[w];
            BOOL inChord = NO;
            for (int v = 0; v < 8; v++) if (field(self, ARP_FIELD_CHORD_NOTE, curSlot, v) == n) inChord = YES;
            BOOL inLearn = NO;
            for (int i = 0; i < learnCount; i++) if (field(self, ARP_FIELD_LEARN_NOTE, i, 0) == n) inLearn = YES;
            NSColor *c = inLearn ? CA(255, 68, 52, 1) : (int)curSlot == n ? C(57, 157, 255)
                : inChord ? C(255, 147, 0) : C(46, 134, 254);
            if (inChord || inLearn || (int)curSlot == n) rect(NSMakeRect(260 + (o * 7 + w) * 32 + 3, 424, 27, 4), c);
        }
    }
    // white keys
    for (int o = 0; o < 3; o++) {
        for (int w = 0; w < 7; w++) {
            int n = _keyScroll * 12 + o * 12 + white[w];
            BOOL inChord = NO;
            for (int v = 0; v < 8; v++) if (field(self, ARP_FIELD_CHORD_NOTE, curSlot, v) == n) inChord = YES;
            BOOL inLearn = NO;
            for (int i = 0; i < learnCount; i++) if (field(self, ARP_FIELD_LEARN_NOTE, i, 0) == n) inLearn = YES;
            NSRect r = NSMakeRect(260 + (o * 7 + w) * 32, 430, 32, 160);
            [G(inChord ? 255 : 244, inChord ? 178 : 244, inChord ? 88 : 244,
               inChord ? 214 : 207, inChord ? 105 : 207, inChord ? 0 : 207) drawInRect:r angle:90];
            if (inLearn) [G(255, 110, 92, 170, 32, 22) drawInRect:r angle:90];
            frameOutline(r, C(64, 62, 56));
            if ((int)curSlot == n) frameOutline(NSInsetRect(r, 1, 1), C(57, 157, 255));
            if (w == 0) text(textAt(self, ARP_TEXT_NOTE, n, 0), r.origin.x + 6, 573, 28, 12, 9, C(40, 40, 40), NSTextAlignmentLeft);
        }
    }
    // black keys
    for (int o = 0; o < 3; o++) {
        for (int w = 0; w < 6; w++) {
            int n = _keyScroll * 12 + o * 12 + blackStep[w] + 1;
            BOOL inChord = NO;
            for (int v = 0; v < 8; v++) if (field(self, ARP_FIELD_CHORD_NOTE, curSlot, v) == n) inChord = YES;
            BOOL inLearn = NO;
            for (int i = 0; i < learnCount; i++) if (field(self, ARP_FIELD_LEARN_NOTE, i, 0) == n) inLearn = YES;
            NSRect r = NSMakeRect(260 + (o * 7 + w) * 32 + 24, 430, 18, 96);
            if (inChord) [G(255, 152, 40, 120, 55, 0) drawInRect:r angle:90];
            else if (inLearn) [G(220, 88, 72, 90, 18, 12) drawInRect:r angle:90];
            else [G(42, 42, 42, 10, 10, 10) drawInRect:r angle:90];
            if ((int)curSlot == n) frameOutline(r, C(57, 157, 255));
        }
    }

    // ---- footer ----
    [G(21, 21, 21, 11, 11, 11) drawInRect:NSMakeRect(0, 602, 960, 38) angle:90];
    [self drawLed:12 y:613 radius:2.6 color:C(57, 157, 255) lit:playing || freeOn];
    text(playing ? (freeOn ? @"FREE CLOCK" : @"HOST SYNC / PLAYING") : @"STOPPED / LIVE CLOCK",
         22, 606, 220, 16, 10, C(255, 147, 0), NSTextAlignmentLeft);
    text([NSString stringWithFormat:@"%d held  /  %d voices  /  pattern %c",
          field(self, ARP_FIELD_ARP_COUNT, 0, 0), field(self, ARP_FIELD_SND_COUNT, 0, 0), 'A' + pattern],
         290, 606, 400, 16, 10, C(172, 172, 172), NSTextAlignmentLeft);
    [self drawLed:12 y:629 radius:2.6 color:C(255, 147, 0) lit:freeOn];
    text(@"Drag: edit   Alt: reset   Shift: audition   Cmd/Ctrl: chord note",
         22, 624, 600, 14, 9, C(158, 158, 158), NSTextAlignmentLeft);
    [self drawButton:NSMakeRect(894, 224, 58, 22) label:@"PANIC" on:NO];

    // ---- menus ----
    if (_menu) {
        int count = _menu == 1 ? 22 : _menu == 2 ? 56 : 11;
        int cols = _menu == 2 ? 4 : _menu == 1 ? 2 : 1;
        int rows = (count + cols - 1) / cols;
        plate(NSMakeRect(_menuX - 4, _menuY - 4, cols * 150 + 8, rows * 14 + 8), 54, 54, 54, 30, 30, 30);
        for (int m = 0; m < count; m++) {
            int col = m / rows, row = m % rows;
            if (col >= cols) break;
            NSString *label = [self menuLabel:_menu index:m];
            double mx = _menuX + col * 150, my = _menuY + row * 14;
            if ([label isEqualToString:@"-"]) {
                gmLine(mx, my + 7, mx + 146, my + 7, CA(15, 15, 15, 0.8));
            } else {
                text(label, mx + 4, my + 1, 142, 13, 9, C(232, 232, 232), NSTextAlignmentLeft);
            }
        }
    }

    CGContextRestoreGState(ctx);
}

- (NSString *)menuLabel:(int)mid index:(int)idx {
    if (mid == 1) {
        NSArray *labels = @[@"Sort by Low Note", @"Sort by Low (Pitch Class)", @"Sort by High Note",
            @"Sort by Note Count", @"Sort by Root (Chromatic)", @"Sort by Root (Circle 5ths)", @"-",
            @"Remove Duplicates", @"Remove 1-Note Chords", @"Remove 2-Note Chords", @"Remove 3-Note Chords",
            @"Remove Unwatched", @"-", @"Make Majors Minor", @"Make Minors Major", @"Make All Suspended", @"-",
            @"Transform: Note-Prevent Rules", @"Transform: Match Selected Chord", @"Populate Empty Slots", @"-",
            @"Clear All Slots"];
        return idx >= 0 && idx < (int)labels.count ? labels[idx] : @"";
    }
    if (mid == 2) {
        if (idx < 12) return [NSString stringWithFormat:@"Scale: %@ major", textAt(self, ARP_TEXT_PC, idx, 0)];
        if (idx == 12) return @"-";
        if (idx == 13) return @"Silence (Empty)";
        if (idx < 26) return [NSString stringWithFormat:@"Scale: %@ natural minor", textAt(self, ARP_TEXT_PC, idx - 14, 0)];
        if (idx == 26) return @"-";
        if (idx == 27) return @"Prog: C I-V-vi-IV";
        if (idx < 40) return [NSString stringWithFormat:@"Scale: %@ major diat. 7ths", textAt(self, ARP_TEXT_PC, idx - 28, 0)];
        if (idx == 40) return @"-";
        if (idx == 41) return @"Prog: Am i-VI-III-VII";
        if (idx < 54) return [NSString stringWithFormat:@"Scale: %@ nat. min diat. 7ths", textAt(self, ARP_TEXT_PC, idx - 42, 0)];
        if (idx == 54) return @"-";
        return @"Prog: G I-vi-IV-V";
    }
    NSArray *labels = @[@"Up 16ths", @"Down 16ths", @"Up/Down", @"Down/Up", @"Up+Down (Bounce)",
        @"Fingered Top", @"Fingered Bottom", @"Random Selection", @"Octave Sweep", @"Clear", @"Down+Up (Bounce)"];
    return idx >= 0 && idx < (int)labels.count ? labels[idx] : @"";
}

- (void)doMenu:(int)mid index:(int)idx {
    if (mid == 1) {
        switch (idx) {
            case 0 ... 5: act(self, ARP_ACTION_SORT, idx, 0); break;
            case 7: act(self, ARP_ACTION_REMOVE_DUPS, 0, 0); break;
            case 8 ... 10: act(self, ARP_ACTION_REMOVE_N, idx - 7, 0); break;
            case 11: act(self, ARP_ACTION_REMOVE_UNWATCHED, 0, 0); break;
            case 13: act(self, ARP_ACTION_MAKE_THIRD, 3, 0); break;
            case 14: act(self, ARP_ACTION_MAKE_THIRD, 4, 0); break;
            case 15: act(self, ARP_ACTION_MAKE_THIRD, 5, 0); break;
            case 17: act(self, ARP_ACTION_TRANSFORM_PREVENT, 0, 0); break;
            case 18: act(self, ARP_ACTION_TRANSFORM_MATCH, (int32_t)field(self, ARP_FIELD_CUR_SLOT, 0, 0), 0); break;
            case 19: act(self, ARP_ACTION_POPULATE_EMPTY, 0, 0); break;
            case 21: act(self, ARP_ACTION_CLEAR_ALL, 0, 0); break;
            default: break;
        }
    } else if (mid == 2) {
        if (idx != 12 && idx != 26 && idx != 40 && idx != 54) act(self, ARP_ACTION_CHORD_PRESET, idx, 0);
    } else {
        act(self, ARP_ACTION_ARP_PRESET, idx, 0);
    }
}

// ---- hit testing ----
- (int)hitTest:(NSPoint)p hitCol:(int *)col hitPc:(int *)pc hitDeg:(int *)deg {
    double x = p.x, y = p.y;
    *col = -1; *pc = -1; *deg = -1;
    if (NSMouseInRect(p, NSMakeRect(894, 224, 58, 22), YES)) return 95; // panic
    if (NSMouseInRect(p, NSMakeRect(8, 580, 145, 18), YES)) return 97; // import
    if (NSMouseInRect(p, NSMakeRect(8, 168, 155, 16), YES)) return 98; // name
    if (NSMouseInRect(p, NSMakeRect(74, 232, 64, 46), YES)) return 96; // swing
    if (NSMouseInRect(p, NSMakeRect(710, 5, 112, 16), YES)) return 99;
    if (NSMouseInRect(p, NSMakeRect(830, 5, 122, 16), YES)) return 100;
    if (NSMouseInRect(p, NSMakeRect(300, 5, 56, 16), YES)) return 70;
    if (NSMouseInRect(p, NSMakeRect(390, 5, 56, 16), YES)) return 71;
    if (NSMouseInRect(p, NSMakeRect(480, 5, 56, 16), YES)) return 72;
    if (NSMouseInRect(p, NSMakeRect(550, 3, 70, 20), YES)) return 2;
    if (NSMouseInRect(p, NSMakeRect(628, 3, 70, 20), YES)) return 1;
    if (y >= 34 && y < 34 + 6 * 24 && x >= 8 && x < 8 + 2 * 54) {
        int letter = (int)floor((x - 8) / 54) + (int)floor((y - 34) / 24) * 2;
        if (letter < 12) return 41 + letter;
    }
    if (NSMouseInRect(p, NSMakeRect(8, 186, 42, 15), YES)) return 80;
    if (NSMouseInRect(p, NSMakeRect(54, 186, 42, 15), YES)) return 81;
    if (NSMouseInRect(p, NSMakeRect(100, 186, 42, 15), YES)) return 82;
    if (NSMouseInRect(p, NSMakeRect(34, 205, 26, 15), YES)) return 5;
    if (hypot(x - 26, y - 246) <= 19) return 3;
    if (NSMouseInRect(p, NSMakeRect(8, 292, 40, 14), YES)) return 76;
    if (hypot(x - 26, y - 318) <= 11) return 4;
    if (NSMouseInRect(p, NSMakeRect(8, 348, 48, 14), YES)) return 73;
    if (NSMouseInRect(p, NSMakeRect(62, 348, 48, 14), YES)) return 74;
    if (NSMouseInRect(p, NSMakeRect(116, 348, 54, 14), YES)) return 75;
    if (NSMouseInRect(p, NSMakeRect(8, 366, 96, 16), YES)) return 83;
    if (y >= 28 && y < 44 && x >= 178 && x < 178 + 8 * 76) {
        int tab = (int)floor((x - 178) / 76);
        if (tab < 8) return 200 + tab;
    }
    if (x >= 178 && x < 850 && y >= 48 && y < 344) {
        int lx = (int)field(self, ARP_FIELD_LEN, field(self, ARP_FIELD_CUR_GRAPH, 0, 0), 0);
        if (fabs(x - (178 + lx * 42)) <= 6) return 7;
        *col = (int)floor((x - 178) / 42);
        if (*col < 16) return 6;
    }
    if (y >= 348 && y < 364 && x >= 178 && x < 850) {
        *col = (int)floor((x - 178) / 42);
        if (*col < 16) return 92;
    }
    if (x >= 858 && x < 888 && y >= 48 && y < 48 + 12 * 21) {
        *pc = (int)floor((y - 48) / 21);
        if (*pc < 12) return 90;
    }
    if (field(self, ARP_FIELD_CUR_GRAPH, 0, 0) == 3 && x >= 894 && x < 916 && y >= 48 && y < 48 + 7 * 15) {
        *deg = (int)floor((y - 48) / 15);
        if (*deg < 7) return 91;
    }
    if (NSMouseInRect(p, NSMakeRect(8, 474, 64, 16), YES)) return 65;
    if (NSMouseInRect(p, NSMakeRect(78, 474, 64, 16), YES)) return 66;
    if (NSMouseInRect(p, NSMakeRect(8, 496, 46, 15), YES)) return 60;
    if (NSMouseInRect(p, NSMakeRect(58, 496, 46, 15), YES)) return 61;
    if (NSMouseInRect(p, NSMakeRect(108, 496, 46, 15), YES)) return 62;
    if (NSMouseInRect(p, NSMakeRect(158, 496, 46, 15), YES)) return 63;
    if (NSMouseInRect(p, NSMakeRect(208, 496, 24, 15), YES)) return 64;
    if (y >= 520 && y < 588 && x >= 8 && x < 8 + 8 * 30) {
        int i = (int)floor((x - 8) / 30);
        if (y < 544) return 10 + i;
        if (y < 566) return 20 + i;
        if (y < 584) return 30 + i;
    }
    if (NSMouseInRect(p, NSMakeRect(260, 398, 26, 16), YES)) return 52;
    if (NSMouseInRect(p, NSMakeRect(450, 398, 26, 16), YES)) return 53;
    if (y >= 420 && y < 590 && x >= 260 && x < 932) {
        static const int bstep[6] = {0, 2, 4, 5, 7, 9};
        for (int o = 0; o < 3; o++) {
            for (int w = 0; w < 6; w++) {
                NSRect b = NSMakeRect(260 + (o * 7 + w) * 32 + 24, 430, 18, 96);
                if (y < 526 && NSMouseInRect(p, b, YES)) {
                    return 300 + _keyScroll * 12 + o * 12 + bstep[w] + 1;
                }
            }
        }
        static const int wstep[7] = {0, 2, 4, 5, 7, 9, 11};
        for (int o = 0; o < 3; o++) {
            for (int w = 0; w < 7; w++) {
                NSRect r = NSMakeRect(260 + (o * 7 + w) * 32, 420, 32, 170);
                if (NSMouseInRect(p, r, YES)) return 300 + _keyScroll * 12 + o * 12 + wstep[w];
            }
        }
    }
    return 0;
}

- (void)rightMouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    [self handleDownAtX:p.x y:p.y mods:MOD_COMMAND];
}
- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    uint32_t mods = 0;
    if (event.modifierFlags & NSEventModifierFlagShift) mods |= MOD_SHIFT;
    if (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) mods |= MOD_COMMAND;
    if (event.modifierFlags & NSEventModifierFlagOption) mods |= MOD_ALT;
    [self handleDownAtX:p.x y:p.y mods:mods];
}
- (void)mouseDragged:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    uint32_t mods = 0;
    if (event.modifierFlags & NSEventModifierFlagShift) mods |= MOD_SHIFT;
    if (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) mods |= MOD_COMMAND;
    if (event.modifierFlags & NSEventModifierFlagOption) mods |= MOD_ALT;
    [self handleDragAtX:p.x y:p.y mods:mods];
}
- (void)mouseUp:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    uint32_t mods = 0;
    if (event.modifierFlags & NSEventModifierFlagShift) mods |= MOD_SHIFT;
    if (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) mods |= MOD_COMMAND;
    if (event.modifierFlags & NSEventModifierFlagOption) mods |= MOD_ALT;
    [self handleUpAtX:p.x y:p.y mods:mods];
}

- (NSPoint)logical:(double)x y:(double)y {
    return NSMakePoint((x - _ox) / _sc, (y - _oy) / _sc);
}

- (void)handleDownAtX:(double)vx y:(double)vy mods:(uint32_t)mods {
    NSPoint p = [self logical:vx y:vy];
    double x = p.x, y = p.y;
    [self.window makeFirstResponder:self];
    _drag = 0;
    _dragVoice = -1;
    _dragPatternFrom = -1;
    _dragY0 = y;
    _dragV0 = 0;

    if (_menu) {
        int count = _menu == 1 ? 22 : _menu == 2 ? 56 : 11;
        int cols = _menu == 2 ? 4 : _menu == 1 ? 2 : 1;
        int rows = (count + cols - 1) / cols;
        if (x >= _menuX && x < _menuX + cols * 150 && y >= _menuY && y < _menuY + rows * 14) {
            int col = (int)floor((x - _menuX) / 150);
            int row = (int)floor((y - _menuY) / 14);
            int idx = col * rows + row;
            BOOL separator = (_menu == 1 && (idx == 6 || idx == 12 || idx == 16 || idx == 20)) ||
                (_menu == 2 && (idx == 12 || idx == 26 || idx == 40 || idx == 54));
            if (idx < count && !separator) [self doMenu:_menu index:idx];
        }
        _menu = 0;
        [self setNeedsDisplay:YES];
        return;
    }

    int col, pc, deg;
    int id = [self hitTest:p hitCol:&col hitPc:&pc hitDeg:&deg];
    uint32_t lane = (uint32_t)field(self, ARP_FIELD_CUR_GRAPH, 0, 0);
    if (id >= 300) {
        int note = id - 300;
        if (mods & MOD_SHIFT) {
            act(self, ARP_ACTION_PREVIEW_CHORD, note, -1);
            writeField(self, ARP_FIELD_CUR_SLOT, 0, 0, note);
        } else if (mods & MOD_COMMAND) {
            int found = -1;
            for (int v = 0; v < 8; v++) if (field(self, ARP_FIELD_CHORD_NOTE, (uint32_t)field(self, ARP_FIELD_CUR_SLOT, 0, 0), v) == note) found = v;
            if (found >= 0) writeField(self, ARP_FIELD_CHORD_NOTE, (uint32_t)field(self, ARP_FIELD_CUR_SLOT, 0, 0), (uint32_t)found, -1);
            else {
                for (int v = 0; v < 8; v++) {
                    if (field(self, ARP_FIELD_CHORD_NOTE, (uint32_t)field(self, ARP_FIELD_CUR_SLOT, 0, 0), v) < 0) {
                        writeField(self, ARP_FIELD_CHORD_NOTE, (uint32_t)field(self, ARP_FIELD_CUR_SLOT, 0, 0), (uint32_t)v, note);
                        break;
                    }
                }
            }
        } else {
            writeField(self, ARP_FIELD_CUR_SLOT, 0, 0, note);
            for (int v = 0; v < 8; v++) if (field(self, ARP_FIELD_CHORD_NOTE, (uint32_t)note, v) == note) _dragVoice = v;
            _drag = 50;
            _dragV0 = note;
        }
        [self setNeedsDisplay:YES];
        return;
    }
    if (id >= 41 && id <= 52) {
        int p = id - 41;
        setParam(self, 7, p);
        _drag = 41;
        _dragPatternFrom = p;
        [self setNeedsDisplay:YES];
        return;
    }
    if (id >= 200 && id <= 207) writeField(self, ARP_FIELD_CUR_GRAPH, 0, 0, id - 200);
    else if (id >= 10 && id < 18) { _drag = id; _dragV0 = field(self, ARP_FIELD_CHORD_NOTE, (uint32_t)field(self, ARP_FIELD_CUR_SLOT, 0, 0), id - 10); }
    else if (id >= 20 && id < 28) { _drag = id; _dragV0 = field(self, ARP_FIELD_CHORD_VEL, (uint32_t)field(self, ARP_FIELD_CUR_SLOT, 0, 0), id - 20); }
    else if (id >= 30 && id < 38) {
        int v = id - 30;
        BOOL on = field(self, ARP_FIELD_LOCK_ON, v, 0) != 0;
        writeField(self, ARP_FIELD_LOCK_ON, v, 0, on ? 0 : 1);
    }
    else switch (id) {
        case 70: setParam(self, 0, param(self, 0) ? 0 : 1); break;
        case 71: setParam(self, 1, param(self, 1) ? 0 : 1); break;
        case 72: setParam(self, 3, param(self, 3) ? 0 : 1); break;
        case 73: writeField(self, ARP_FIELD_RETRIG, 0, 0, !field(self, ARP_FIELD_RETRIG, 0, 0)); break;
        case 74: writeField(self, ARP_FIELD_LINK, 0, 0, !field(self, ARP_FIELD_LINK, 0, 0)); break;
        case 75: writeField(self, ARP_FIELD_CHORD_MODE, 0, 0, !field(self, ARP_FIELD_CHORD_MODE, 0, 0)); break;
        case 76: writeField(self, ARP_FIELD_FREE_ON, 0, 0, !field(self, ARP_FIELD_FREE_ON, 0, 0)); break;
        case 99: setParam(self, 5, (param(self, 5) + 1) % 17); break;
        case 100: setParam(self, 6, param(self, 6) ? 0 : 1); break;
        case 95: act(self, ARP_ACTION_PANIC, 0, 0); break;
        case 97: [self importMidi]; break;
        case 98:
            _nameEditing = 1;
            _nameLen = 0;
            while (_nameLen < 23 && field(self, ARP_FIELD_NAME_CHAR, (uint32_t)_nameLen, 0) > 0) _nameLen++;
            [self setNeedsDisplay:YES];
            break;
        case 96: _drag = 96; _dragV0 = field(self, ARP_FIELD_SWING, 0, 0); break;
        case 5: writeField(self, ARP_FIELD_DIV, lane, 0, (field(self, ARP_FIELD_DIV, lane, 0) % 8) + 1); break;
        case 80: act(self, ARP_ACTION_COPY_GRAPH, 0, 0); break;
        case 81: act(self, ARP_ACTION_PASTE_GRAPH, 0, 0); break;
        case 82: act(self, ARP_ACTION_RAND_GRAPH, 0, 0); break;
        case 90: writeField(self, ARP_FIELD_CONSTRAINT, (uint32_t)pc, 0, (field(self, ARP_FIELD_CONSTRAINT, (uint32_t)pc, 0) + 1) % 4); break;
        case 91: writeField(self, ARP_FIELD_PEN, (uint32_t)deg, 0, !field(self, ARP_FIELD_PEN, (uint32_t)deg, 0)); break;
        case 92: writeField(self, ARP_FIELD_MUTE, 0, (uint32_t)col, !field(self, ARP_FIELD_MUTE, 0, (uint32_t)col)); break;
        case 60:
            if (field(self, ARP_FIELD_LEARNING, 0, 0)) act(self, ARP_ACTION_TOGGLE_LEARN, 1, 0);
            else act(self, ARP_ACTION_TOGGLE_LEARN, (mods & MOD_ALT) ? 2 : (mods & MOD_COMMAND) ? 3 : 1, (mods & MOD_SHIFT) ? 1 : 0);
            break;
        case 61: act(self, ARP_ACTION_COPY_CHORD, (int32_t)field(self, ARP_FIELD_CUR_SLOT, 0, 0), 0); break;
        case 62: act(self, ARP_ACTION_PASTE_CHORD, (int32_t)field(self, ARP_FIELD_CUR_SLOT, 0, 0), 0); break;
        case 63: act(self, ARP_ACTION_RAND_CHORD, (int32_t)field(self, ARP_FIELD_CUR_SLOT, 0, 0), 0); break;
        case 64: {
            BOOL on = field(self, ARP_FIELD_WATCH_ON, 0, 0) != 0;
            writeField(self, ARP_FIELD_WATCH_ON, 0, 0, on ? 0 : 1);
            break;
        }
        case 65: _menu = 1; _menuX = 8; _menuY = 396; break;
        case 66: _menu = 2; _menuX = 8; _menuY = 396; break;
        case 83: _menu = 3; _menuX = 8; _menuY = 396; break;
        case 52: _keyScroll = MAX(0, _keyScroll - 1); break;
        case 53: _keyScroll = MIN(8, _keyScroll + 1); break;
        case 1: _drag = 1; _dragV0 = param(self, 2); break;
        case 2: _drag = 2; _dragV0 = param(self, 4); break;
        case 3: _drag = 3; _dragV0 = field(self, ARP_FIELD_RATE, 0, 0); break;
        case 4: _drag = 4; _dragV0 = field(self, ARP_FIELD_FREE_HZ, 0, 0) / 100.0; break;
        case 6:
            if ((mods & MOD_ALT) && lane == 0) {
                writeField(self, ARP_FIELD_RESET, 0, (uint32_t)col, !field(self, ARP_FIELD_RESET, 0, (uint32_t)col));
            } else {
                _drag = 6;
                writeField(self, ARP_FIELD_CELL, lane, (uint32_t)col, [ArpStickEditorView cellValue:lane y:y]);
            }
            break;
        case 7: _drag = 7; break;
        default: break;
    }
    [self setNeedsDisplay:YES];
}

+ (int)cellValue:(uint32_t)lane y:(double)y {
    double f = (y - 48) / 296.0;
    switch (lane) {
        case 0: return 15 - (int)floor(f * 17);
        case 1:
        case 2: return 8 - (int)floor(f * 17);
        case 3:
        case 7: return 12 - (int)floor(f * 25);
        case 4: return 200 - (int)floor(f * 201);
        case 5: return 100 - (int)floor(f * 101);
        case 6: return 100 - (int)floor(f * 201);
        default: return 0;
    }
}

- (void)handleDragAtX:(double)vx y:(double)vy mods:(uint32_t)mods {
    (void)mods;
    NSPoint p = [self logical:vx y:vy];
    double x = p.x, y = p.y;
    double dy = _dragY0 - y;
    uint32_t lane = (uint32_t)field(self, ARP_FIELD_CUR_GRAPH, 0, 0);
    uint32_t slot = (uint32_t)field(self, ARP_FIELD_CUR_SLOT, 0, 0);
    switch (_drag) {
        case 96: writeField(self, ARP_FIELD_SWING, 0, 0, MAX(0, MIN(75, (int)floor(_dragV0 + dy / 3)))); break;
        case 1: setParam(self, 2, MAX(-36, MIN(36, (int)floor(_dragV0 + dy / 3)))); break;
        case 2: setParam(self, 4, MAX(0, MIN(100, (int)floor(_dragV0 + dy / 3)))); break;
        case 3: writeField(self, ARP_FIELD_RATE, 0, 0, MAX(0, MIN(15, (int)floor(_dragV0 + dy / 5)))); break;
        case 4: writeField(self, ARP_FIELD_FREE_HZ, 0, 0, (int)round(MAX(0.05, MIN(40, _dragV0 + dy / 30)) * 100)); break;
        case 6: {
            int col = (int)floor((x - 178) / 42);
            if (col >= 0 && col < 16) writeField(self, ARP_FIELD_CELL, lane, (uint32_t)col, [ArpStickEditorView cellValue:lane y:y]);
            break;
        }
        case 7: {
            int nl = MAX(1, MIN(16, (int)floor((x - 178) / 42 + 0.5)));
            if (field(self, ARP_FIELD_LINK, 0, 0)) {
                for (int i = 0; i < 8; i++) writeField(self, ARP_FIELD_LEN, i, 0, nl);
            } else writeField(self, ARP_FIELD_LEN, lane, 0, nl);
            break;
        }
        case 50:
            if (_dragVoice >= 0) writeField(self, ARP_FIELD_CHORD_NOTE, slot, (uint32_t)_dragVoice, MAX(0, MIN(127, (int)floor(_dragV0 + dy / 5))));
            break;
        default:
            if (_drag >= 10 && _drag < 18) writeField(self, ARP_FIELD_CHORD_NOTE, slot, _drag - 10, MAX(-1, MIN(127, (int)floor(_dragV0 + dy / 5))));
            else if (_drag >= 20 && _drag < 28) writeField(self, ARP_FIELD_CHORD_VEL, slot, _drag - 20, MAX(0, MIN(200, (int)floor(_dragV0 + dy / 3))));
            break;
    }
    [self setNeedsDisplay:YES];
}

- (void)handleUpAtX:(double)vx y:(double)vy mods:(uint32_t)mods {
    (void)mods;
    NSPoint p = [self logical:vx y:vy];
    if (_drag == 41) {
        int col, pc, deg;
        int id = [self hitTest:p hitCol:&col hitPc:&pc hitDeg:&deg];
        if (id >= 41 && id <= 52 && id - 41 != _dragPatternFrom) act(self, ARP_ACTION_COPY_PATTERN, _dragPatternFrom, id - 41);
    }
    _drag = 0;
    _dragVoice = -1;
    _dragPatternFrom = -1;
    [self setNeedsDisplay:YES];
}

// ---- keyboard / pattern naming ----
- (void)keyDown:(NSEvent *)event {
    unsigned short code = event.keyCode;
    if (_nameEditing) {
        if (code == 53 || code == 36) { _nameEditing = 0; [self setNeedsDisplay:YES]; return; }
        if (code == 51) {
            if (_nameLen > 0) {
                _nameLen--;
                writeField(self, ARP_FIELD_NAME_CHAR, (uint32_t)_nameLen, 0, 0);
            }
            [self setNeedsDisplay:YES];
            return;
        }
        NSString *chars = event.charactersIgnoringModifiers;
        if (chars.length == 1) {
            unichar c = [chars characterAtIndex:0];
            if (c >= 32 && c <= 126 && _nameLen < 23) {
                writeField(self, ARP_FIELD_NAME_CHAR, (uint32_t)_nameLen, 0, c);
                _nameLen++;
            }
        }
        [self setNeedsDisplay:YES];
        return;
    }
    if (code == 53) act(self, ARP_ACTION_PANIC, 0, 0);
}

- (void)testClickX:(double)x y:(double)y mods:(uint32_t)mods { [self handleDownAtX:x y:y mods:mods]; }
- (void)testDragX:(double)x y:(double)y mods:(uint32_t)mods { [self handleDragAtX:x y:y mods:mods]; }
- (void)testReleaseX:(double)x y:(double)y mods:(uint32_t)mods { [self handleUpAtX:x y:y mods:mods]; }
- (void)testKey:(uint32_t)key {
    if (key == 27) act(self, ARP_ACTION_PANIC, 0, 0);
}

// ---- MIDI file import ----
static uint32_t read_be32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }
static uint32_t read_be16(const uint8_t *p) { return ((uint32_t)p[0] << 8) | p[1]; }
static uint32_t read_var(const uint8_t *p, size_t len, size_t *pos) {
    uint32_t v = 0;
    while (*pos < len) {
        uint8_t b = p[(*pos)++];
        v = (v << 7) | (b & 0x7f);
        if (!(b & 0x80)) break;
    }
    return v;
}

- (void)importMidi {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    if ([panel runModal] != NSModalResponseOK || panel.URL == nil) return;
    [self importMidiAtPath:panel.URL.path];
}

- (void)importMidiAtPath:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return;
    const uint8_t *p = data.bytes;
    size_t len = data.length;
    if (len < 14 || memcmp(p, "MThd", 4) != 0) return;
    size_t headerLen = read_be32(p + 4);
    size_t pos = 8 + headerLen;
    uint32_t division = read_be16(p + 12);
    if (division & 0x8000) return; // SMPTE timing is not supported

    typedef struct { int note; int start; int end; int vel; } Note;
    static Note notes[4096];
    int noteCount = 0;
    while (pos + 8 <= len) {
        if (memcmp(p + pos, "MTrk", 4) != 0) break;
        uint32_t trackLen = read_be32(p + pos + 4);
        size_t trackEnd = pos + 8 + trackLen;
        if (trackEnd > len) break;
        size_t t = pos + 8;
        uint32_t tick = 0;
        uint8_t running = 0;
        int openNote[16][128];
        int openVel[16][128];
        memset(openNote, -1, sizeof(openNote));
        memset(openVel, 0, sizeof(openVel));
        while (t < trackEnd) {
            tick += read_var(p, trackEnd, &t);
            if (t >= trackEnd) break;
            uint8_t status = p[t];
            if (status < 0x80) { status = running; }
            else { t++; running = status; }
            if (status == 0xff) {
                if (t >= trackEnd) break;
                uint8_t type = p[t++];
                uint32_t size = read_var(p, trackEnd, &t);
                t += size;
                if (type == 0x2f) break;
                continue;
            }
            if (status == 0xf0 || status == 0xf7) {
                uint32_t size = read_var(p, trackEnd, &t);
                t += size;
                continue;
            }
            uint8_t kind = status & 0xf0, ch = status & 15;
            int d1 = t < trackEnd ? p[t++] : 0;
            int d2 = 0;
            if (kind != 0xc0 && kind != 0xd0 && t < trackEnd) d2 = p[t++];
            if (kind == 0x90 && d2 > 0) {
                if (openNote[ch][d1 & 127] < 0) {
                    openNote[ch][d1 & 127] = (int)tick;
                    openVel[ch][d1 & 127] = d2;
                }
            } else if (kind == 0x80 || (kind == 0x90 && d2 == 0)) {
                int key = d1 & 127;
                int start = openNote[ch][key];
                if (start >= 0 && noteCount < 4096) {
                    notes[noteCount].note = key;
                    notes[noteCount].start = start;
                    notes[noteCount].end = (int)tick;
                    notes[noteCount].vel = openVel[ch][key];
                    noteCount++;
                    openNote[ch][key] = -1;
                }
            }
        }
        pos = trackEnd;
    }
    if (noteCount == 0) return;

    // Group simultaneous note-on events (same start tick) into chords and
    // write consecutive slots starting at the selected slot.
    int slot = (int)field(self, ARP_FIELD_CUR_SLOT, 0, 0);
    int i = 0;
    while (i < noteCount && slot < 128) {
        int start = notes[i].start;
        int chord[8];
        int chordVel[8];
        int count = 0;
        int j = i;
        while (j < noteCount && notes[j].start == start && count < 8) {
            chord[count] = notes[j].note;
            chordVel[count] = notes[j].vel;
            count++;
            j++;
        }
        // Keep chord voices in ascending pitch order.
        for (int a = 1; a < count; a++) {
            int n = chord[a], v = chordVel[a], b = a;
            while (b > 0 && chord[b - 1] > n) {
                chord[b] = chord[b - 1];
                chordVel[b] = chordVel[b - 1];
                b--;
            }
            chord[b] = n;
            chordVel[b] = v;
        }
        for (int v = 0; v < 8; v++) {
            writeField(self, ARP_FIELD_CHORD_NOTE, (uint32_t)slot, (uint32_t)v, v < count ? chord[v] : -1);
            writeField(self, ARP_FIELD_CHORD_VEL, (uint32_t)slot, (uint32_t)v, v < count ? chordVel[v] : 100);
        }
        slot++;
        i = j;
    }
    [self setNeedsDisplay:YES];
}

@end

void *arp_ui_create(const ArpStickUIConfig *config) {
    @autoreleasepool {
        return (__bridge_retained void *)[[ArpStickEditorView alloc] initWithConfig:config];
    }
}
void arp_ui_destroy(void *handle) {
    if (!handle) return;
    @autoreleasepool {
        ArpStickEditorView *view = (__bridge_transfer ArpStickEditorView *)handle;
        view.hidden = YES;
        [view removeFromSuperview];
    }
}
bool arp_ui_attach(void *handle, void *parent) {
    if (!handle || !parent) return false;
    @autoreleasepool {
        NSView *view = (__bridge NSView *)handle;
        NSView *container = (__bridge NSView *)parent;
        [view removeFromSuperview];
        view.frame = NSMakeRect(0, 0, 960, 640);
        [container addSubview:view];
        return true;
    }
}
void arp_ui_show(void *handle, bool visible) {
    if (handle) ((__bridge NSView *)handle).hidden = !visible;
}
void arp_ui_refresh(void *handle) {
    if (handle) [(__bridge ArpStickEditorView *)handle refresh];
}
void arp_ui_set_size(void *handle, uint32_t width, uint32_t height) {
    if (handle) ((__bridge NSView *)handle).frame = NSMakeRect(0, 0, width, height);
}
void arp_ui_click(void *handle, double x, double y, uint32_t modifiers) {
    if (handle) [(__bridge ArpStickEditorView *)handle testClickX:x y:y mods:modifiers];
}
void arp_ui_drag(void *handle, double x, double y, uint32_t modifiers) {
    if (handle) [(__bridge ArpStickEditorView *)handle testDragX:x y:y mods:modifiers];
}
void arp_ui_release(void *handle, double x, double y, uint32_t modifiers) {
    if (handle) [(__bridge ArpStickEditorView *)handle testReleaseX:x y:y mods:modifiers];
}
void arp_ui_key(void *handle, uint32_t key) {
    if (handle) [(__bridge ArpStickEditorView *)handle testKey:key];
}
void arp_ui_draw_now(void *handle) {
    if (handle) [(__bridge ArpStickEditorView *)handle display];
}
void arp_ui_import_midi(void *handle, const char *path) {
    if (!handle || !path) return;
    [(__bridge ArpStickEditorView *)handle importMidiAtPath:[NSString stringWithUTF8String:path]];
}

@interface ArpStickPreviewDelegate : NSObject <NSApplicationDelegate>
@end
@implementation ArpStickPreviewDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { (void)sender; return YES; }
@end

int arp_ui_preview(const ArpStickUIConfig *config) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        ArpStickPreviewDelegate *delegate = [ArpStickPreviewDelegate new];
        app.delegate = delegate;
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 960, 640)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
            backing:NSBackingStoreBuffered defer:NO];
        window.title = @"Arp Stick — UI preview";
        window.releasedWhenClosed = NO;
        window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        ArpStickEditorView *view = [[ArpStickEditorView alloc] initWithConfig:config];
        window.contentView = view;
        view.hidden = NO;
        NSMenu *menu = [NSMenu new];
        NSMenuItem *applicationItem = [NSMenuItem new];
        [menu addItem:applicationItem];
        NSMenu *applicationMenu = [NSMenu new];
        [applicationMenu addItemWithTitle:@"Quit Arp Stick Preview" action:@selector(terminate:) keyEquivalent:@"q"];
        applicationItem.submenu = applicationMenu;
        app.mainMenu = menu;
        [window center];
        [window makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];

        NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
        NSUInteger capture = [args indexOfObject:@"--screenshot"];
        if (capture != NSNotFound && capture + 1 < args.count) {
            NSString *path = args[capture + 1];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
                NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
                [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
                NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                if (![png writeToFile:path atomically:YES]) fprintf(stderr, "Could not save UI screenshot\n");
                [app terminate:nil];
            });
        }
        [app run];
        return 0;
    }
}
