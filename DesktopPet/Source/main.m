#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

typedef NS_ENUM(NSInteger, YXPetState) {
    YXPetStateIdle,
    YXPetStateStartingWalk,
    YXPetStateWalking,
    YXPetStateStoppingWalk,
    YXPetStateWaving,
    YXPetStateSleeping,
};

@class YXPetController;

@interface YXPetView : NSView
@property(nonatomic, weak) YXPetController *controller;
@property(nonatomic, strong) NSImageView *imageView;
@property(nonatomic, strong) CALayer *contactShadowLayer;
@property(nonatomic, strong) NSArray<NSImage *> *sequenceFrames;
@property(nonatomic, strong) NSArray<NSNumber *> *frameDurations;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSArray<NSImage *> *> *sequenceCache;
@property(nonatomic) NSTimeInterval sequenceStartedAt;
@property(nonatomic) NSTimeInterval pausedAt;
@property(nonatomic) NSInteger displayedFrame;
@property(nonatomic) BOOL sequencePaused;
@property(nonatomic) BOOL sequenceLoops;
@property(nonatomic) NSPoint dragStartMouse;
@property(nonatomic) NSPoint dragStartOrigin;
@property(nonatomic) BOOL didDrag;
- (void)showSequenceAtDirectory:(NSString *)directory
                      durations:(NSArray<NSNumber *> *)durations
                       mirrored:(BOOL)mirrored
                          loops:(BOOL)loops;
- (void)animationTickAtTime:(NSTimeInterval)now;
- (void)setMirrored:(BOOL)mirrored;
- (void)setAnimationPaused:(BOOL)paused;
- (void)setContactShadowOpacity:(CGFloat)opacity;
@end

@interface YXPetController : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic, strong) NSPanel *window;
@property(nonatomic, strong) YXPetView *petView;
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenu *menu;
@property(nonatomic, strong) NSMenuItem *stateItem;
@property(nonatomic, strong) NSMenuItem *autoItem;
@property(nonatomic, strong) NSMenuItem *pauseItem;
@property(nonatomic, strong) NSTimer *movementTimer;
@property(nonatomic, strong) NSTimer *decisionTimer;
@property(nonatomic) YXPetState state;
@property(nonatomic) NSTimeInterval stateStartedAt;
@property(nonatomic) NSTimeInterval stateEndsAt;
@property(nonatomic) NSTimeInterval nextDecisionAt;
@property(nonatomic) NSTimeInterval lastInteractionAt;
@property(nonatomic) NSTimeInterval pendingWalkDuration;
@property(nonatomic) CGFloat direction;
@property(nonatomic) CGFloat scale;
@property(nonatomic) BOOL automaticActivity;
@property(nonatomic) BOOL paused;
- (void)petClicked;
- (void)petWasDragged;
- (void)beginWalkingForDuration:(NSTimeInterval)duration;
- (NSMenu *)contextMenu;
@end

@implementation YXPetView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.clearColor.CGColor;

        _contactShadowLayer = [CALayer layer];
        _contactShadowLayer.backgroundColor = NSColor.blackColor.CGColor;
        _contactShadowLayer.opacity = 0.14;
        _contactShadowLayer.shadowColor = NSColor.blackColor.CGColor;
        _contactShadowLayer.shadowOpacity = 0.20;
        _contactShadowLayer.shadowRadius = 5.0;
        _contactShadowLayer.shadowOffset = CGSizeZero;
        _contactShadowLayer.actions = @{
            @"bounds": NSNull.null, @"position": NSNull.null,
            @"cornerRadius": NSNull.null, @"opacity": NSNull.null
        };
        [self.layer addSublayer:_contactShadowLayer];

        _imageView = [[NSImageView alloc] initWithFrame:self.bounds];
        _imageView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
        _imageView.imageAlignment = NSImageAlignCenter;
        _imageView.animates = NO;
        _imageView.wantsLayer = YES;
        _imageView.layer.magnificationFilter = kCAFilterLinear;
        _imageView.layer.minificationFilter = kCAFilterTrilinear;
        [self addSubview:_imageView];

        _sequenceCache = [NSMutableDictionary dictionary];
        _displayedFrame = NSNotFound;
    }
    return self;
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    CGFloat shadowWidth = width * 0.27;
    CGFloat shadowHeight = MAX(5.0, width * 0.026);
    self.contactShadowLayer.frame = CGRectMake((width - shadowWidth) / 2.0,
                                               width * 0.012,
                                               shadowWidth,
                                               shadowHeight);
    self.contactShadowLayer.cornerRadius = shadowHeight / 2.0;
}

- (NSView *)hitTest:(NSPoint)point {
    return NSPointInRect(point, self.bounds) ? self : nil;
}

- (NSArray<NSImage *> *)framesAtDirectory:(NSString *)directory {
    NSArray<NSImage *> *cached = self.sequenceCache[directory];
    if (cached) return cached;

    NSError *error = nil;
    NSArray<NSString *> *names = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:directory error:&error];
    if (error) return @[];

    NSPredicate *pngFrames = [NSPredicate predicateWithBlock:^BOOL(NSString *name,
                                                                    NSDictionary *bindings) {
        (void)bindings;
        return [name hasPrefix:@"frame_"] &&
               [[name.pathExtension lowercaseString] isEqualToString:@"png"];
    }];
    names = [[names filteredArrayUsingPredicate:pngFrames]
        sortedArrayUsingSelector:@selector(localizedStandardCompare:)];

    NSMutableArray<NSImage *> *frames = [NSMutableArray arrayWithCapacity:names.count];
    for (NSString *name in names) {
        NSImage *image = [[NSImage alloc]
            initWithContentsOfFile:[directory stringByAppendingPathComponent:name]];
        if (image) [frames addObject:image];
    }
    NSArray<NSImage *> *loaded = frames.copy;
    self.sequenceCache[directory] = loaded;
    return loaded;
}

- (void)showSequenceAtDirectory:(NSString *)directory
                      durations:(NSArray<NSNumber *> *)durations
                       mirrored:(BOOL)mirrored
                          loops:(BOOL)loops {
    self.sequenceFrames = [self framesAtDirectory:directory];
    self.frameDurations = durations;
    self.sequenceStartedAt = NSDate.timeIntervalSinceReferenceDate;
    self.pausedAt = 0.0;
    self.sequencePaused = NO;
    self.sequenceLoops = loops;
    self.displayedFrame = NSNotFound;
    if (self.sequenceFrames.count > 0) self.imageView.image = self.sequenceFrames.firstObject;
    [self setMirrored:mirrored];
}

- (void)animationTickAtTime:(NSTimeInterval)now {
    if (self.sequencePaused || self.sequenceFrames.count == 0) return;

    NSTimeInterval defaultDuration = 0.10;
    NSTimeInterval cycleDuration = 0.0;
    for (NSUInteger index = 0; index < self.sequenceFrames.count; index++) {
        cycleDuration += index < self.frameDurations.count
            ? MAX(0.02, self.frameDurations[index].doubleValue) : defaultDuration;
    }
    if (cycleDuration <= 0.0) return;

    NSTimeInterval elapsed = MAX(0.0, now - self.sequenceStartedAt);
    NSTimeInterval position = self.sequenceLoops
        ? fmod(elapsed, cycleDuration) : MIN(elapsed, cycleDuration - 0.001);
    NSTimeInterval cursor = 0.0;
    NSInteger nextFrame = self.sequenceFrames.count - 1;
    for (NSUInteger index = 0; index < self.sequenceFrames.count; index++) {
        cursor += index < self.frameDurations.count
            ? MAX(0.02, self.frameDurations[index].doubleValue) : defaultDuration;
        if (position < cursor) {
            nextFrame = (NSInteger)index;
            break;
        }
    }
    if (nextFrame != self.displayedFrame) {
        self.displayedFrame = nextFrame;
        self.imageView.image = self.sequenceFrames[(NSUInteger)nextFrame];
    }
}

- (void)setMirrored:(BOOL)mirrored {
    self.imageView.layer.transform = mirrored
        ? CATransform3DMakeScale(-1.0, 1.0, 1.0)
        : CATransform3DIdentity;
}

- (void)setAnimationPaused:(BOOL)paused {
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (paused && !self.sequencePaused) {
        self.pausedAt = now;
    } else if (!paused && self.sequencePaused && self.pausedAt > 0.0) {
        self.sequenceStartedAt += now - self.pausedAt;
        self.pausedAt = 0.0;
    }
    self.sequencePaused = paused;
}

- (void)setContactShadowOpacity:(CGFloat)opacity {
    self.contactShadowLayer.opacity = MAX(0.0, MIN(0.22, opacity));
}

- (void)mouseDown:(NSEvent *)event {
    self.dragStartMouse = NSEvent.mouseLocation;
    self.dragStartOrigin = self.window.frame.origin;
    self.didDrag = NO;
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint current = NSEvent.mouseLocation;
    CGFloat dx = current.x - self.dragStartMouse.x;
    CGFloat dy = current.y - self.dragStartMouse.y;
    if (fabs(dx) > 2.0 || fabs(dy) > 2.0) self.didDrag = YES;
    [self.window setFrameOrigin:NSMakePoint(self.dragStartOrigin.x + dx,
                                             self.dragStartOrigin.y + dy)];
}

- (void)mouseUp:(NSEvent *)event {
    if (self.didDrag) {
        [self.controller petWasDragged];
    } else {
        [self.controller petClicked];
    }
}

- (void)rightMouseDown:(NSEvent *)event {
    [NSMenu popUpContextMenu:self.controller.contextMenu withEvent:event forView:self];
}

@end

@implementation YXPetController

static const CGFloat YXBasePetSize = 270.0;

static CGFloat YXSmoothStep(CGFloat value) {
    CGFloat clamped = MAX(0.0, MIN(1.0, value));
    return clamped * clamped * (3.0 - 2.0 * clamped);
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    CGFloat savedScale = [defaults doubleForKey:@"petScale"];
    self.scale = savedScale >= 0.7 && savedScale <= 1.5 ? savedScale : 1.0;
    self.automaticActivity = [defaults objectForKey:@"automaticActivity"]
        ? [defaults boolForKey:@"automaticActivity"] : YES;
    self.direction = -1.0;
    self.lastInteractionAt = NSDate.timeIntervalSinceReferenceDate;
    self.nextDecisionAt = self.lastInteractionAt + 6.0;

    [self createWindow];
    [self createMenuBarItem];
    [self switchToState:YXPetStateIdle duration:0.0];
    [self installTimers];
}

- (void)createWindow {
    CGFloat size = YXBasePetSize * self.scale;
    NSRect frame = NSMakeRect(0, 0, size, size);
    self.window = [[NSPanel alloc]
        initWithContentRect:frame
                  styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self.window.opaque = NO;
    self.window.backgroundColor = NSColor.clearColor;
    self.window.hasShadow = NO;
    self.window.level = NSFloatingWindowLevel;
    self.window.hidesOnDeactivate = NO;
    self.window.movable = NO;
    self.window.releasedWhenClosed = NO;
    self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                     NSWindowCollectionBehaviorFullScreenAuxiliary |
                                     NSWindowCollectionBehaviorTransient;

    self.petView = [[YXPetView alloc] initWithFrame:NSMakeRect(0, 0, size, size)];
    self.petView.controller = self;
    self.window.contentView = self.petView;

    NSRect visible = NSScreen.mainScreen.visibleFrame;
    NSPoint origin = NSMakePoint(NSMaxX(visible) - size - 24.0,
                                 NSMinY(visible) + 8.0);
    [self.window setFrameOrigin:origin];
    [self.window orderFrontRegardless];
}

- (NSMenuItem *)itemWithTitle:(NSString *)title action:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    return item;
}

- (void)createMenuBarItem {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"🦊";
    self.statusItem.button.toolTip = @"于曦桌面宠物";

    self.menu = [[NSMenu alloc] initWithTitle:@"于曦桌面宠物"];
    self.menu.delegate = self;
    self.stateItem = [[NSMenuItem alloc] initWithTitle:@"于曦正在待机" action:nil keyEquivalent:@""];
    self.stateItem.enabled = NO;
    [self.menu addItem:self.stateItem];
    [self.menu addItem:NSMenuItem.separatorItem];
    [self.menu addItem:[self itemWithTitle:@"唤醒" action:@selector(wakeAction:)]];
    [self.menu addItem:[self itemWithTitle:@"挥手" action:@selector(waveAction:)]];
    [self.menu addItem:[self itemWithTitle:@"散步" action:@selector(walkAction:)]];
    [self.menu addItem:[self itemWithTitle:@"睡觉" action:@selector(sleepAction:)]];
    [self.menu addItem:NSMenuItem.separatorItem];

    self.autoItem = [self itemWithTitle:@"自动活动" action:@selector(toggleAutomaticActivity:)];
    [self.menu addItem:self.autoItem];
    self.pauseItem = [self itemWithTitle:@"暂停动画" action:@selector(togglePause:)];
    [self.menu addItem:self.pauseItem];

    NSMenuItem *sizeRoot = [[NSMenuItem alloc] initWithTitle:@"角色大小" action:nil keyEquivalent:@""];
    NSMenu *sizeMenu = [[NSMenu alloc] initWithTitle:@"角色大小"];
    NSArray<NSArray *> *sizes = @[
        @[@"小（80%）", @0.8], @[@"标准（100%）", @1.0], @[@"大（125%）", @1.25]
    ];
    for (NSArray *entry in sizes) {
        NSMenuItem *sizeItem = [self itemWithTitle:entry[0] action:@selector(changeSize:)];
        sizeItem.representedObject = entry[1];
        [sizeMenu addItem:sizeItem];
    }
    sizeRoot.submenu = sizeMenu;
    [self.menu addItem:sizeRoot];
    [self.menu addItem:NSMenuItem.separatorItem];
    [self.menu addItem:[self itemWithTitle:@"退出于曦" action:@selector(quitAction:)]];
    self.statusItem.menu = self.menu;
    [self updateMenu];
}

- (void)installTimers {
    self.movementTimer = [NSTimer timerWithTimeInterval:(1.0 / 30.0)
                                                  target:self
                                                selector:@selector(movementTick:)
                                                userInfo:nil
                                                 repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.movementTimer forMode:NSRunLoopCommonModes];
    self.decisionTimer = [NSTimer timerWithTimeInterval:0.1
                                                  target:self
                                                selector:@selector(decisionTick:)
                                                userInfo:nil
                                                 repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.decisionTimer forMode:NSRunLoopCommonModes];
}

- (NSString *)resourceNameForState:(YXPetState)state {
    switch (state) {
        case YXPetStateStartingWalk: return @"start";
        case YXPetStateWalking: return @"walk";
        case YXPetStateStoppingWalk: return @"stop";
        case YXPetStateWaving: return @"wave";
        case YXPetStateSleeping: return @"sleep";
        case YXPetStateIdle: default: return @"idle";
    }
}

- (NSString *)displayNameForState:(YXPetState)state {
    switch (state) {
        case YXPetStateStartingWalk: return @"准备散步";
        case YXPetStateWalking: return @"散步";
        case YXPetStateStoppingWalk: return @"慢慢停下";
        case YXPetStateWaving: return @"向哥哥挥手";
        case YXPetStateSleeping: return @"睡觉";
        case YXPetStateIdle: default: return @"待机眨眼";
    }
}

- (NSArray<NSNumber *> *)frameDurationsForState:(YXPetState)state {
    switch (state) {
        case YXPetStateStartingWalk:
            return @[@0.16, @0.15, @0.14, @0.13];
        case YXPetStateWalking:
            return @[@0.095, @0.075, @0.065, @0.075,
                     @0.095, @0.075, @0.065, @0.075,
                     @0.095, @0.075, @0.065, @0.075];
        case YXPetStateStoppingWalk:
            return @[@0.12, @0.14, @0.16, @0.18];
        case YXPetStateWaving:
            return @[@0.22, @0.22, @0.22, @0.22];
        case YXPetStateSleeping:
            return @[@0.55, @0.55, @0.55, @0.55];
        case YXPetStateIdle:
        default:
            return @[@1.10, @0.35, @0.30, @0.45,
                     @1.80, @0.12, @0.11, @2.00];
    }
}

- (void)switchToState:(YXPetState)newState duration:(NSTimeInterval)duration {
    self.state = newState;
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    self.stateStartedAt = now;
    self.stateEndsAt = duration > 0.0 ? now + duration : 0.0;
    NSString *name = [self resourceNameForState:newState];
    NSString *path = [[[NSBundle.mainBundle resourcePath]
        stringByAppendingPathComponent:@"Sequences"] stringByAppendingPathComponent:name];
    BOOL isWalkingPose = newState == YXPetStateStartingWalk ||
                         newState == YXPetStateWalking ||
                         newState == YXPetStateStoppingWalk;
    BOOL mirror = isWalkingPose && self.direction < 0.0;
    BOOL loops = newState != YXPetStateStartingWalk && newState != YXPetStateStoppingWalk;
    [self.petView showSequenceAtDirectory:path
                                durations:[self frameDurationsForState:newState]
                                 mirrored:mirror
                                    loops:loops];
    [self.petView setAnimationPaused:self.paused];
    CGFloat shadowOpacity = newState == YXPetStateSleeping ? 0.09 : 0.14;
    [self.petView setContactShadowOpacity:shadowOpacity];
    [self updateMenu];
}

- (void)movementTick:(NSTimer *)timer {
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    [self.petView animationTickAtTime:now];
    BOOL isMoving = self.state == YXPetStateStartingWalk ||
                    self.state == YXPetStateWalking ||
                    self.state == YXPetStateStoppingWalk;
    if (self.paused || !isMoving) return;
    CGFloat footPhase = fmod((now - self.stateStartedAt) / 0.31, 1.0);
    CGFloat contactAmount = 0.5 + 0.5 * cos(footPhase * M_PI * 2.0);
    [self.petView setContactShadowOpacity:0.09 + 0.08 * contactAmount];
    NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
    NSRect visible = screen.visibleFrame;
    NSRect frame = self.window.frame;
    CGFloat speedFactor = 1.0;
    NSTimeInterval stateDuration = MAX(0.001, self.stateEndsAt - self.stateStartedAt);
    if (self.state == YXPetStateStartingWalk) {
        speedFactor = YXSmoothStep((now - self.stateStartedAt) / stateDuration);
    } else if (self.state == YXPetStateStoppingWalk) {
        speedFactor = YXSmoothStep((self.stateEndsAt - now) / stateDuration);
    }
    CGFloat speed = 52.0 * speedFactor * timer.timeInterval;
    frame.origin.x += self.direction * speed;
    frame.origin.y = NSMinY(visible) + 8.0;

    CGFloat minX = NSMinX(visible);
    CGFloat maxX = NSMaxX(visible) - NSWidth(frame);
    if (frame.origin.x <= minX) {
        frame.origin.x = minX;
        self.direction = 1.0;
        [self.petView setMirrored:NO];
    } else if (frame.origin.x >= maxX) {
        frame.origin.x = maxX;
        self.direction = -1.0;
        [self.petView setMirrored:YES];
    }
    [self.window setFrameOrigin:frame.origin];
}

- (void)decisionTick:(NSTimer *)timer {
    if (self.paused) return;
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;

    if (self.stateEndsAt > 0.0 && now >= self.stateEndsAt) {
        if (self.state == YXPetStateStartingWalk) {
            [self switchToState:YXPetStateWalking duration:self.pendingWalkDuration];
        } else if (self.state == YXPetStateWalking) {
            [self switchToState:YXPetStateStoppingWalk duration:0.60];
        } else {
            [self switchToState:YXPetStateIdle duration:0.0];
            self.nextDecisionAt = now + 5.0 + arc4random_uniform(6);
        }
        return;
    }
    if (!self.automaticActivity || self.state != YXPetStateIdle || now < self.nextDecisionAt) return;

    if (now - self.lastInteractionAt > 75.0) {
        [self switchToState:YXPetStateSleeping duration:0.0];
        return;
    }

    uint32_t choice = arc4random_uniform(4);
    if (choice <= 1) {
        self.direction = arc4random_uniform(2) == 0 ? -1.0 : 1.0;
        [self beginWalkingForDuration:8.0 + arc4random_uniform(7)];
    } else if (choice == 2) {
        [self switchToState:YXPetStateWaving duration:3.2];
    } else {
        self.nextDecisionAt = now + 5.0 + arc4random_uniform(7);
    }
}

- (void)beginWalkingForDuration:(NSTimeInterval)duration {
    self.pendingWalkDuration = MAX(1.0, duration);
    [self switchToState:YXPetStateStartingWalk duration:0.58];
}

- (void)petClicked {
    self.lastInteractionAt = NSDate.timeIntervalSinceReferenceDate;
    self.paused = NO;
    if (self.state == YXPetStateSleeping) {
        [self switchToState:YXPetStateIdle duration:0.0];
    } else {
        [self switchToState:YXPetStateWaving duration:3.2];
    }
    self.nextDecisionAt = self.lastInteractionAt + 7.0;
}

- (void)petWasDragged {
    self.lastInteractionAt = NSDate.timeIntervalSinceReferenceDate;
    self.nextDecisionAt = self.lastInteractionAt + 8.0;
}

- (NSMenu *)contextMenu {
    [self updateMenu];
    return self.menu;
}

- (void)wakeAction:(id)sender {
    self.paused = NO;
    self.lastInteractionAt = NSDate.timeIntervalSinceReferenceDate;
    self.nextDecisionAt = self.lastInteractionAt + 7.0;
    [self switchToState:YXPetStateIdle duration:0.0];
}

- (void)waveAction:(id)sender {
    self.paused = NO;
    self.lastInteractionAt = NSDate.timeIntervalSinceReferenceDate;
    [self switchToState:YXPetStateWaving duration:3.2];
}

- (void)walkAction:(id)sender {
    self.paused = NO;
    self.lastInteractionAt = NSDate.timeIntervalSinceReferenceDate;
    [self beginWalkingForDuration:12.0];
}

- (void)sleepAction:(id)sender {
    self.paused = NO;
    [self switchToState:YXPetStateSleeping duration:0.0];
}

- (void)toggleAutomaticActivity:(id)sender {
    self.automaticActivity = !self.automaticActivity;
    [NSUserDefaults.standardUserDefaults setBool:self.automaticActivity forKey:@"automaticActivity"];
    self.nextDecisionAt = NSDate.timeIntervalSinceReferenceDate + 4.0;
    [self updateMenu];
}

- (void)togglePause:(id)sender {
    self.paused = !self.paused;
    [self.petView setAnimationPaused:self.paused];
    [self updateMenu];
}

- (void)changeSize:(NSMenuItem *)sender {
    CGFloat newScale = [sender.representedObject doubleValue];
    if (newScale < 0.7 || newScale > 1.5) return;
    self.scale = newScale;
    [NSUserDefaults.standardUserDefaults setDouble:newScale forKey:@"petScale"];

    NSRect oldFrame = self.window.frame;
    CGFloat newSize = YXBasePetSize * newScale;
    NSRect newFrame = NSMakeRect(oldFrame.origin.x, oldFrame.origin.y, newSize, newSize);
    [self.window setFrame:newFrame display:YES animate:YES];
    [self updateMenu];
}

- (void)quitAction:(id)sender {
    [NSApp terminate:nil];
}

- (void)menuWillOpen:(NSMenu *)menu {
    [self updateMenu];
}

- (void)updateMenu {
    self.stateItem.title = [NSString stringWithFormat:@"于曦正在%@", [self displayNameForState:self.state]];
    self.autoItem.state = self.automaticActivity ? NSControlStateValueOn : NSControlStateValueOff;
    self.pauseItem.title = self.paused ? @"继续动画" : @"暂停动画";

    NSMenuItem *sizeRoot = [self.menu itemWithTitle:@"角色大小"];
    for (NSMenuItem *item in sizeRoot.submenu.itemArray) {
        CGFloat candidate = [item.representedObject doubleValue];
        item.state = fabs(candidate - self.scale) < 0.01 ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        YXPetController *controller = [YXPetController new];
        application.delegate = controller;
        [application run];
    }
    return 0;
}
