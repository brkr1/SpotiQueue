// Runs inside com.apple.springboard. Owns the actual queue sheet: a UIWindow overlay
// shown on kSQOpenNotify from MediaRemoteUIHalf's trigger button.
#import "../Shared.h"
#import "LightMessaging.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - LightMessaging client

// Fresh connection (and, for the two-way calls, a fresh reply port) per call - never
// shared across concurrent queries. Same reasoning as NextUp3's NUNextUpManager.
static LMConnection SQFreshConnection(void) {
    // serverName is name_t (a fixed char array) - a (char*) cast here would break
    // C's "char array initialized from a string literal" rule.
    LMConnection c = { MACH_PORT_NULL, kSQServiceNameSpotify };
    return c;
}

static NSDictionary *SQQueueSnapshot(void) {
    LMConnection conn = SQFreshConnection();
    LMResponseBuffer buffer;
    kern_return_t kr = LMConnectionSendTwoWay(&conn, kSQMsgIDQueueSnapshot, NULL, 0, &buffer);
    if (conn.serverPort != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), conn.serverPort);
    if (kr != KERN_SUCCESS) { SQLog("SQQueueSnapshot: LM kr=%d (Spotify not running / not injected?)", kr); return nil; }
    id result = LMResponseConsumePropertyList(&buffer);
    return [result isKindOfClass:NSDictionary.class] ? result : nil;
}

// Runs off-main (called from a background queue by the view controller) - a full
// round trip can take up to LIGHTMESSAGING_TIMEOUT (250ms) and must never jank scroll.
static NSDictionary<NSString *, NSData *> *SQArtworkBatch(NSArray<NSString *> *uris) {
    if (uris.count == 0) return @{};
    LMConnection conn = SQFreshConnection();
    LMResponseBuffer buffer;
    kern_return_t kr = LMConnectionSendTwoWayPropertyList(&conn, kSQMsgIDArtworkBatch, uris, &buffer);
    if (conn.serverPort != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), conn.serverPort);
    if (kr != KERN_SUCCESS) { SQLog("SQArtworkBatch: LM kr=%d", kr); return @{}; }
    id result = LMResponseConsumePropertyList(&buffer);
    return [result isKindOfClass:NSDictionary.class] ? result : @{};
}

static void SQSendOneWay(SInt32 msgID, NSDictionary *payload) {
    LMConnection conn = SQFreshConnection();
    NSData *data = LMDataForPropertyList(payload);
    kern_return_t kr = LMConnectionSendOneWay(&conn, msgID, data.bytes, (uint32_t)data.length);
    SQLog("SQSendOneWay msgID=%d payload=%{public}@ kr=%d", (int)msgID, payload, kr);
}

#pragma mark - Glass backdrop

// Dedicated CABackdropLayer-backed view (layerClass must be overridden at the class
// level), used only by the real-glass path in SQGlassBackdropView below.
@interface SQBackdropOnlyView : UIView
@end
@implementation SQBackdropOnlyView
+ (Class)layerClass { return NSClassFromString(@"CABackdropLayer") ?: [CALayer class]; }
@end

// Tries the real liquidass glass backdrop first (renders only if liquidass is
// installed/active - the filter type is a render-server-wide atom). Falls back to blur.
@interface SQGlassBackdropView : UIView
@end

@implementation SQGlassBackdropView {
    UIView *_realGlass;          // CABackdropLayer-backed, only if liquidass answered
    UIVisualEffectView *_blur;   // fallback
    CAGradientLayer *_specular;
    CAShapeLayer *_specularMask;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    [self installBackdrop];
    [self installSpecularEdge];
    return self;
}

- (void)installBackdrop {
    Class backdropCls = NSClassFromString(@"CABackdropLayer");
    Class filterCls = NSClassFromString(@"CAFilter");
    id glassFilter = nil;
    if (backdropCls && filterCls) {
        @try {
            glassFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
                filterCls, NSSelectorFromString(@"filterWithType:"), @"dylv.liquidglass.refraction");
        } @catch (__unused NSException *e) {}
    }
    if (glassFilter) {
        SQLog("glass backdrop: liquidass filter resolved, using real backdrop");
        _realGlass = [[SQBackdropOnlyView alloc] initWithFrame:self.bounds];
        @try {
            [_realGlass.layer setValue:@NO forKey:@"layerUsesCoreImageFilters"];
            [_realGlass.layer setValue:@YES forKey:@"ignoresScreenClip"];
            _realGlass.layer.filters = @[glassFilter];
        } @catch (NSException *e) { SQLog("glass backdrop: apply failed %{public}@", e.reason); }
        _realGlass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_realGlass];
    } else {
        SQLog("glass backdrop: liquidass filter unavailable, falling back to UIVisualEffectView blur");
        UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
        _blur = [[UIVisualEffectView alloc] initWithEffect:effect];
        _blur.frame = self.bounds;
        _blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_blur];
    }
}

// Cosmetic-only gradient sweep along the rounded edge - ordinary CoreAnimation,
// zero private API (static, unlike liquidass's gyro-reactive version).
- (void)installSpecularEdge {
    _specular = [CAGradientLayer layer];
    _specular.colors = @[
        (id)[UIColor colorWithWhite:1.0 alpha:0.10].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
        (id)[UIColor colorWithWhite:0.0 alpha:0.03].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.06].CGColor,
    ];
    _specular.startPoint = CGPointMake(0.1, 0.0);
    _specular.endPoint = CGPointMake(0.9, 1.0);
    _specularMask = [CAShapeLayer layer];
    _specularMask.fillColor = UIColor.clearColor.CGColor;
    _specularMask.strokeColor = UIColor.blackColor.CGColor;
    _specularMask.lineWidth = 1.0;
    _specular.mask = _specularMask;
    [self.layer addSublayer:_specular];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _realGlass.frame = self.bounds;
    _blur.frame = self.bounds;
    _specular.frame = self.bounds;
    CGFloat radius = self.layer.cornerRadius;
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:radius];
    _specularMask.path = path.CGPath;
    _specularMask.frame = self.bounds;
}

@end

#pragma mark - Queue view controller

static NSString *const kSQCellReuseID = @"track";

@interface SQQueueWindowController : NSObject
+ (instancetype)shared;
- (void)show:(BOOL)fromIsland;
- (void)hide;
- (void)refreshIfVisible;
@end

@interface SQQueueViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *currentTitleLabel;
@property (nonatomic, strong) UILabel *currentSubtitleLabel;
@property (nonatomic, strong) UIImageView *currentArtworkView;
@property (nonatomic, strong) SQGlassBackdropView *backdrop;
@property (nonatomic, copy) NSArray<NSDictionary *> *tracks;
@property (nonatomic, copy) NSString *currentURI;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIImage *> *artworkCache;
@property (nonatomic, strong) NSMutableSet<NSString *> *artworkPending;
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@property (nonatomic, assign) BOOL presentedFromIsland;
@end

@implementation SQQueueViewController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _artworkCache = [NSMutableDictionary dictionary];
    _artworkPending = [NSMutableSet set];
    _ioQueue = dispatch_queue_create("com.brkr1.tweaks.spotiqueue.io", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)loadView {
    UIView *root = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    root.backgroundColor = UIColor.clearColor;
    self.view = root;
}

- (void)setPresentedFromIsland:(BOOL)presentedFromIsland {
    if (_presentedFromIsland == presentedFromIsland) return;
    _presentedFromIsland = presentedFromIsland;
    if (self.backdrop) self.backdrop.frame = [self sq_cardFrame];
}

// Reserves the top of the screen when opened from the island, so the sheet doesn't
// fight the island's own expanded card for the same region.
- (CGRect)sq_cardFrame {
    CGFloat cardWidth = self.view.bounds.size.width * 0.88;
    CGFloat cardHeight = MIN(620.0, self.view.bounds.size.height * 0.7);
    CGFloat topReserved = self.presentedFromIsland ? self.view.bounds.size.height * 0.22 : 0;
    CGFloat y = topReserved + (self.view.bounds.size.height - topReserved - cardHeight) / 2.0;
    return CGRectMake((self.view.bounds.size.width - cardWidth) / 2.0, y, cardWidth, cardHeight);
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // Blurs everything behind the card (requested), not just a flat dim.
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    blur.frame = self.view.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:blur];

    UIControl *dim = [[UIControl alloc] initWithFrame:self.view.bounds];
    dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.1];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [dim addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:dim];

    // Centered card, not a bottom sheet (requested) - big continuous corner radius
    // reads as the rounded/"oval" shape asked for while staying usable for a list.
    CGRect cardFrame = [self sq_cardFrame];
    CGFloat cardWidth = cardFrame.size.width;
    CGFloat cardHeight = cardFrame.size.height;
    self.backdrop = [[SQGlassBackdropView alloc] initWithFrame:cardFrame];
    self.backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight
        | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin
        | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    self.backdrop.layer.cornerRadius = 40.0;
    self.backdrop.layer.cornerCurve = kCACornerCurveContinuous;
    self.backdrop.clipsToBounds = YES;
    [self.view addSubview:self.backdrop];

    UILabel *header = [[UILabel alloc] initWithFrame:CGRectMake(24, 16, cardWidth - 48, 28)];
    header.text = @"Queue";
    header.font = [UIFont boldSystemFontOfSize:22];
    header.textColor = UIColor.whiteColor;
    [self.backdrop addSubview:header];

    self.currentArtworkView = [[UIImageView alloc] initWithFrame:CGRectMake(24, 56, 48, 48)];
    self.currentArtworkView.layer.cornerRadius = 6;
    self.currentArtworkView.layer.cornerCurve = kCACornerCurveContinuous;
    self.currentArtworkView.clipsToBounds = YES;
    self.currentArtworkView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    self.currentArtworkView.contentMode = UIViewContentModeScaleAspectFill;
    [self.backdrop addSubview:self.currentArtworkView];

    self.currentTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(82, 56, cardWidth - 106, 22)];
    self.currentTitleLabel.font = [UIFont boldSystemFontOfSize:16];
    self.currentTitleLabel.textColor = [UIColor colorWithRed:0.12 green:0.85 blue:0.38 alpha:1.0]; // Spotify-green accent for the now-playing row
    [self.backdrop addSubview:self.currentTitleLabel];

    self.currentSubtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(82, 80, cardWidth - 106, 20)];
    self.currentSubtitleLabel.font = [UIFont systemFontOfSize:14];
    self.currentSubtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
    [self.backdrop addSubview:self.currentSubtitleLabel];

    CGFloat tableTop = 116;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, tableTop, cardWidth, cardHeight - tableTop)
                                                   style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.separatorColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    // Was the default (~44pt, cramped with 40pt artwork). Requested more breathing
    // room between rows.
    self.tableView.rowHeight = 68.0;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    // Permanently-editing table: gives a real system reorder handle plus the classic
    // red minus/swipe delete, both natively designed to coexist (unlike swipe actions).
    self.tableView.editing = YES;
    self.tableView.allowsSelectionDuringEditing = YES;
    [self.backdrop addSubview:self.tableView];

    [self reload];
}

- (void)dismiss {
    [[SQQueueWindowController shared] hide];
}

#pragma mark Data

- (void)reload {
    NSDictionary *snapshot = SQQueueSnapshot();
    if (![snapshot[kSQKeyActive] boolValue]) {
        SQLog("reload: inactive snapshot, showing empty state");
        self.currentTitleLabel.text = @"Nothing playing on Spotify";
        self.currentSubtitleLabel.text = @"";
        self.tracks = @[];
        [self.tableView reloadData];
        return;
    }
    self.currentTitleLabel.text = snapshot[kSQKeyCurrentTitle];
    self.currentSubtitleLabel.text = snapshot[kSQKeyCurrentSubtitle];
    self.currentURI = snapshot[kSQKeyCurrentURI];
    NSArray *tracks = snapshot[kSQKeyTracks];
    self.tracks = [tracks isKindOfClass:NSArray.class] ? tracks : @[];
    [self.tableView reloadData];
    [self applyCachedArtworkTo:self.currentArtworkView forURI:self.currentURI];
    [self requestArtworkForVisibleRows];
}

- (void)applyCachedArtworkTo:(UIImageView *)imageView forURI:(NSString *)uri {
    UIImage *img = uri.length ? self.artworkCache[uri] : nil;
    imageView.image = img;
    if (img || uri.length == 0) return;
    [self queueArtworkFetchForURIs:@[uri]];
}

// Coalesces one batch LM request per reload/scroll settle instead of one per cell -
// a full sheet can have dozens of rows and each LM round trip costs real time.
- (void)requestArtworkForVisibleRows {
    NSMutableArray<NSString *> *need = [NSMutableArray array];
    for (NSIndexPath *ip in self.tableView.indexPathsForVisibleRows) {
        if (ip.row >= (NSInteger)self.tracks.count) continue;
        NSString *uri = self.tracks[ip.row][kSQKeyURI];
        if (uri.length && !self.artworkCache[uri] && ![self.artworkPending containsObject:uri]) [need addObject:uri];
    }
    if (need.count) [self queueArtworkFetchForURIs:need];
}

- (void)queueArtworkFetchForURIs:(NSArray<NSString *> *)uris {
    NSArray<NSString *> *wanted = [uris filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSString *uri, NSDictionary *bindings) {
            return uri.length > 0 && !self.artworkCache[uri] && ![self.artworkPending containsObject:uri];
        }]];
    if (wanted.count == 0) return;
    [self.artworkPending addObjectsFromArray:wanted];
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.ioQueue, ^{
        NSDictionary<NSString *, NSData *> *result = SQArtworkBatch(wanted);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf; if (!self) return;
            [self.artworkPending minusSet:[NSSet setWithArray:wanted]];
            for (NSString *uri in result) {
                UIImage *img = [UIImage imageWithData:result[uri]];
                if (img) self.artworkCache[uri] = img;
            }
            if (result.count) {
                [self.tableView reloadData];
                [self applyCachedArtworkTo:self.currentArtworkView forURI:self.currentURI];
            }
        });
    });
}

#pragma mark UITableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.tracks.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // Manual dequeue, not registerClass:/dequeue(forIndexPath:) - that path always
    // hands back a Default-style cell, whose detailTextLabel is nil (no subtitle slot).
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kSQCellReuseID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kSQCellReuseID];
    cell.backgroundColor = UIColor.clearColor;
    NSDictionary *t = self.tracks[indexPath.row];
    cell.textLabel.text = t[kSQKeyTitle];
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.detailTextLabel.text = t[kSQKeySubtitle];
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    NSString *uri = t[kSQKeyURI];
    UIImage *art = uri.length ? self.artworkCache[uri] : nil;
    cell.imageView.image = art ?: [UIImage systemImageNamed:@"music.note"];
    cell.imageView.layer.cornerRadius = 4;
    cell.imageView.clipsToBounds = YES;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *t = self.tracks[indexPath.row];
    SQLog("row tapped: %{public}@", t[kSQKeyTitle]);
    SQSendOneWay(kSQMsgIDPlayNow, @{ kSQKeyUID: t[kSQKeyUID] ?: @"", kSQKeyURI: t[kSQKeyURI] ?: @"" });
    [self dismiss];
}

#pragma mark Reorder and delete (permanently-editing table, see viewDidLoad)

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath { return YES; }

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath
       toIndexPath:(NSIndexPath *)destIndexPath {
    if (sourceIndexPath.row == destIndexPath.row) return;
    NSMutableArray *m = [self.tracks mutableCopy];
    NSDictionary *t = m[sourceIndexPath.row];
    [m removeObjectAtIndex:sourceIndexPath.row];
    [m insertObject:t atIndex:destIndexPath.row];
    self.tracks = m; // optimistic; UIKit already moved the visual row itself

    SQLog("row moved: %{public}@ -> %ld", t[kSQKeyTitle], (long)destIndexPath.row);
    SQSendOneWay(kSQMsgIDReorder, @{ kSQKeyUID: t[kSQKeyUID] ?: @"", kSQKeyURI: t[kSQKeyURI] ?: @"",
                                     kSQKeyToIndex: @(destIndexPath.row) });
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath { return YES; }

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleDelete;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
    forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    NSDictionary *t = self.tracks[indexPath.row];
    SQLog("row removed: %{public}@", t[kSQKeyTitle]);
    SQSendOneWay(kSQMsgIDRemove, @{ kSQKeyUID: t[kSQKeyUID] ?: @"", kSQKeyURI: t[kSQKeyURI] ?: @"" });
    NSMutableArray *m = [self.tracks mutableCopy];
    [m removeObjectAtIndex:indexPath.row];
    self.tracks = m; // optimistic; a fresh snapshot lands on the next kSQChangedNotify
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate) [self requestArtworkForVisibleRows];
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView { [self requestArtworkForVisibleRows]; }

@end

#pragma mark - Suppress the lock screen's auto-dim/lock while the sheet is open

// The ordinary screen-lock timeout dims/locks out from under the sheet otherwise.
// Same fix as LyricationReborn: make the expiry handler a no-op while presenting.
static BOOL gSQPresenting = NO;
static BOOL SQIsQueuePresenting(void) { return gSQPresenting; }

@interface SBIdleTimerService : NSObject
- (BOOL)handleIdleTimerDidExpire;
@end

%hook SBIdleTimerService
- (BOOL)handleIdleTimerDidExpire {
    return SQIsQueuePresenting() ? YES : %orig;
}
%end

#pragma mark - Window controller

@implementation SQQueueWindowController {
    UIWindow *_window;
    SQQueueViewController *_vc;
    BOOL _reloadScheduled;
}

+ (instancetype)shared {
    static SQQueueWindowController *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SQQueueWindowController new]; });
    return s;
}

- (void)show:(BOOL)fromIsland {
    if (!_window) {
        // A plain -initWithFrame: UIWindow with no windowScene silently never becomes
        // key on iOS 13+. Reuse whatever scene is already active instead.
        UIWindowScene *scene = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:UIWindowScene.class] && s.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)s;
                break;
            }
        }
        if (!scene) {
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                if ([s isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene *)s; break; }
            }
        }
        SQLog("show: connectedScenes=%lu chosen scene=%p",
              (unsigned long)UIApplication.sharedApplication.connectedScenes.count, scene);

        _window = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                        : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        _window.frame = UIScreen.mainScreen.bounds;
        _window.windowLevel = UIWindowLevelAlert;
        _window.backgroundColor = UIColor.clearColor;
        _vc = [SQQueueViewController new];
        _window.rootViewController = _vc;
    }
    _vc.presentedFromIsland = fromIsland;
    gSQPresenting = YES;
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    _window.hidden = NO;
    [_window makeKeyAndVisible];
    SQLog("show: frame=%{public}@ level=%.0f isKeyWindow=%d",
          NSStringFromCGRect(_window.frame), _window.windowLevel, _window.isKeyWindow);
    [_vc reload];
}

- (void)hide {
    gSQPresenting = NO;
    UIApplication.sharedApplication.idleTimerDisabled = NO;
    _window.hidden = YES;
    SQLog("hide");
}

// kSQChangedNotify fires once per artwork image too, not just real queue changes -
// coalesce into at most one reload per 200ms instead of one per notification.
- (void)refreshIfVisible {
    if (!_window || _window.hidden || _reloadScheduled) return;
    _reloadScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf; if (!self) return;
        self->_reloadScheduled = NO;
        if (!self->_window || self->_window.hidden) return;
        [self->_vc reload];
    });
}

@end

#pragma mark - Ctor

%ctor {
    @autoreleasepool {
        SQApplySandbox();
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        SQLog("ctor: proc=%{public}@ bundle=%{public}@ os=%{public}@",
              NSProcessInfo.processInfo.processName, bundleID,
              NSProcessInfo.processInfo.operatingSystemVersionString);
        if (![bundleID isEqualToString:@"com.apple.springboard"]) return;

        int openToken;
        notify_register_dispatch(kSQOpenNotify, &openToken, dispatch_get_main_queue(), ^(int t) {
            SQLog("kSQOpenNotify received");
            // Presenting our key window instantly races Control Center's own dismiss
            // animation, leaving it visually stuck mid-transition; let it finish first.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[SQQueueWindowController shared] show:NO];
            });
        });
        int openIslandToken;
        notify_register_dispatch(kSQOpenFromIslandNotify, &openIslandToken, dispatch_get_main_queue(), ^(int t) {
            SQLog("kSQOpenFromIslandNotify received");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[SQQueueWindowController shared] show:YES];
            });
        });
        int changedToken;
        notify_register_dispatch(kSQChangedNotify, &changedToken, dispatch_get_main_queue(), ^(int t) {
            [[SQQueueWindowController shared] refreshIfVisible];
        });
        SQLog("loaded into SpringBoard");
    }
}
