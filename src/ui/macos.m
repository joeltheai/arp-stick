#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import "macos.h"

// Shared by the CLAP editor and the standalone preview. Zig owns parameter state.
@interface ArpStickEditorView : NSView
@property(nonatomic) ArpStickUIConfig config;
@property(nonatomic, strong) NSArray<NSControl *> *controls;
@property(nonatomic, strong) NSTimer *refreshTimer;
- (instancetype)initWithConfig:(const ArpStickUIConfig *)config;
- (void)refresh;
@end

@implementation ArpStickEditorView
- (BOOL)isFlipped { return YES; }

- (NSTextField *)label:(NSString *)text frame:(NSRect)frame size:(CGFloat)size color:(NSColor *)color {
    NSTextField *label = [NSTextField labelWithString:text];
    label.frame = frame;
    label.font = [NSFont systemFontOfSize:size];
    label.textColor = color;
    [self addSubview:label];
    return label;
}

- (instancetype)initWithConfig:(const ArpStickUIConfig *)config {
    self = [super initWithFrame:NSMakeRect(0, 0, 480, 340)];
    if (!self) return nil;
    _config = *config;
    self.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor colorWithSRGBRed:0.075 green:0.085 blue:0.10 alpha:1].CGColor;
    NSTextField *title = [self label:@"Arp Stick" frame:NSMakeRect(26, 22, 300, 34) size:27 color:NSColor.whiteColor];
    title.font = [NSFont systemFontOfSize:27 weight:NSFontWeightSemibold];
    [self label:@"Turn held notes into chords and patterns." frame:NSMakeRect(27, 62, 425, 22)
           size:12 color:NSColor.secondaryLabelColor];

    NSArray<NSString *> *names = @[@"Mode", @"Chord", @"Rate", @"Octaves"];
    NSMutableArray<NSControl *> *controls = [NSMutableArray array];
    NSColor *accent = [NSColor colorWithSRGBRed:0.35 green:0.85 blue:0.70 alpha:1];
    for (NSUInteger id = 0; id < 4; id++) {
        CGFloat y = 105 + id * 43;
        [self label:names[id] frame:NSMakeRect(28, y + 5, 90, 24) size:13 color:NSColor.labelColor];
        NSMutableArray<NSString *> *labels = [NSMutableArray array];
        for (uint32_t v = 0; v < config->counts[id]; v++)
            [labels addObject:[NSString stringWithUTF8String:config->options[id][v]]];
        NSControl *control;
        if (id == 1) {
            NSPopUpButton *menu = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(128, y, 324, 32) pullsDown:NO];
            [menu addItemsWithTitles:labels];
            control = menu;
        } else {
            NSSegmentedControl *segments = [NSSegmentedControl segmentedControlWithLabels:labels
                trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changed:)];
            segments.frame = NSMakeRect(128, y, 324, 32);
            segments.segmentStyle = NSSegmentStyleRounded;
            segments.selectedSegmentBezelColor = accent;
            for (NSUInteger v = 0; v < labels.count; v++) [segments setWidth:324.0 / labels.count forSegment:v];
            control = segments;
        }
        control.tag = (NSInteger)id;
        control.target = self;
        control.action = @selector(changed:);
        control.font = [NSFont systemFontOfSize:13];
        control.accessibilityLabel = names[id];
        [controls addObject:control];
        [self addSubview:control];
    }
    _controls = controls;
    NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(28, 286, 424, 1)];
    line.boxType = NSBoxSeparator;
    [self addSubview:line];
    [self label:@"MIDI effect · put a synth after Arp Stick" frame:NSMakeRect(28, 303, 424, 20)
           size:11 color:NSColor.secondaryLabelColor];
    [self refresh];
    self.hidden = YES;
    return self;
}

- (void)changed:(NSControl *)sender {
    uint32_t value = [sender isKindOfClass:NSPopUpButton.class]
        ? (uint32_t)((NSPopUpButton *)sender).indexOfSelectedItem
        : (uint32_t)((NSSegmentedControl *)sender).selectedSegment;
    if (!_config.change(_config.context, (uint32_t)sender.tag, value)) [self refresh];
}

- (void)refresh {
    for (NSUInteger id = 0; id < _controls.count; id++) {
        NSInteger value = (NSInteger)_config.read(_config.context, (uint32_t)id);
        if (value < 0 || value >= _config.counts[id]) continue;
        NSControl *control = _controls[id];
        if ([control isKindOfClass:NSPopUpButton.class]) [(NSPopUpButton *)control selectItemAtIndex:value];
        else ((NSSegmentedControl *)control).selectedSegment = value;
    }
}

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    [_refreshTimer invalidate];
    _refreshTimer = nil;
    if (!hidden) {
        [self refresh];
        __weak ArpStickEditorView *weakSelf = self;
        _refreshTimer = [NSTimer timerWithTimeInterval:1.0 / 30.0 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            [weakSelf refresh];
        }];
        [NSRunLoop.mainRunLoop addTimer:_refreshTimer forMode:NSRunLoopCommonModes];
    }
}
- (void)dealloc { [_refreshTimer invalidate]; }
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
        view.frame = NSMakeRect(0, 0, 480, 340);
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
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 480, 340)
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

        // Optional capture of this view only, for repeatable visual inspection.
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
