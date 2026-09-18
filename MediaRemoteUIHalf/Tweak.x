// Covers iOS 16 lock screen + Control Center (both host MRUNowPlayingView, just in
// different processes). The button mirrors SpotiLoveReborn's heart button anchoring.
#import "../Shared.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - Now-playing app tracking (gates the button to Spotify only)

// MediaRemote.framework is already loaded in this process; resolve lazily via dlopen,
// same technique NextUp3's NUNextUpManager uses, so it's never force-loaded.
static void *SQMRHandle(void) {
    static void *h; static dispatch_once_t once;
    dispatch_once(&once, ^{
        h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        SQLog("MediaRemote handle=%p", h);
    });
    return h;
}

static BOOL gSQSpotifyIsNowPlaying = NO;

BOOL SQIsSpotifyNowPlaying(void) { return gSQSpotifyIsNowPlaying; }

static void SQRefreshNowPlayingApp(void) {
    void *h = SQMRHandle();
    void (*getClient)(dispatch_queue_t, void (^)(id)) = h ? dlsym(h, "MRMediaRemoteGetNowPlayingClient") : NULL;
    NSString *(*getBundle)(id) = h ? dlsym(h, "MRNowPlayingClientGetBundleIdentifier") : NULL;
    NSString *(*getParent)(id) = h ? dlsym(h, "MRNowPlayingClientGetParentAppBundleIdentifier") : NULL;
    if (!getClient || (!getBundle && !getParent)) return; // can't tell -> keep last value (fail open)
    getClient(dispatch_get_main_queue(), ^(id client) {
        NSString *bid = (client && getBundle) ? getBundle(client) : nil;
        if (!bid && client && getParent) bid = getParent(client);
        BOOL isSpotify = [bid isEqualToString:@"com.spotify.client"];
        if (isSpotify != gSQSpotifyIsNowPlaying) {
            gSQSpotifyIsNowPlaying = isSpotify;
            SQLog("now playing app changed: bundle=%{public}@ isSpotify=%d", bid, isSpotify);
        }
    });
}

static void SQStartNowPlayingTracking(void) {
    void *h = SQMRHandle();
    if (!h) return;
    void (*reg)(dispatch_queue_t) = dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (reg) reg(dispatch_get_main_queue());
    NSString * __unsafe_unretained *namePtr =
        (NSString * __unsafe_unretained *)dlsym(h, "kMRMediaRemoteNowPlayingApplicationDidChangeNotification");
    NSString *name = namePtr ? *namePtr : @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification";
    [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil
        usingBlock:^(NSNotification *note) { SQRefreshNowPlayingApp(); }];
    SQRefreshNowPlayingApp();
}

#pragma mark - Lock screen / Control Center button

@interface MRUNowPlayingView : UIView
@property (nonatomic, readonly) UIView *transportControlsView;
- (void)sq_buttonTappedFromView;
@end

@interface MRUNowPlayingViewController : UIViewController
@property (nonatomic, retain) MRUNowPlayingView *view;
@property (nonatomic) long long context; // 2 == lock screen
@end

static const long long kSQLockScreenContext = 2;

static MRUNowPlayingViewController *SQOwningNowPlayingVC(UIView *view) {
    Class vcClass = objc_getClass("MRUNowPlayingViewController");
    if (!vcClass) return nil;
    UIResponder *responder = view.nextResponder;
    while (responder && ![responder isKindOfClass:vcClass]) responder = responder.nextResponder;
    return (MRUNowPlayingViewController *)responder;
}

// Control Center's card doesn't report context==2 like the lock screen does, so fall
// back to an ancestor-chain walk (confirmed technique, via SpotiLoveReborn/NextUp3).
static BOOL SQIsSupportedNowPlayingContext(MRUNowPlayingViewController *vc) {
    if (!vc) return NO;
    if (vc.context == kSQLockScreenContext) return YES;
    Class controlCenterClass = objc_getClass("MRUControlCenterViewController");
    if (controlCenterClass) {
        for (UIViewController *ancestor = vc; ancestor; ancestor = ancestor.parentViewController) {
            if ([ancestor isKindOfClass:controlCenterClass]) return YES;
        }
    }
    return NO;
}

UIButton *gSQMRUButton;

void SQButtonTapped(BOOL fromIsland) {
    UISelectionFeedbackGenerator *feedback = [[UISelectionFeedbackGenerator alloc] init];
    [feedback selectionChanged];
    SQLog("queue button tapped, fromIsland=%d", fromIsland);
    notify_post(fromIsland ? kSQOpenFromIslandNotify : kSQOpenNotify);
}

// X on lock screen / CC-expanded, measured off a real screenshot (no reliable
// sibling view to anchor off there). Compact CC overrides with the row's own midX.
static const CGFloat kSQButtonRightOffset = 64.0;

void SQLayoutMRUButton(MRUNowPlayingView *playerView) {
    if (!gSQMRUButton) return;
    CGSize fitSize = [gSQMRUButton sizeThatFits:CGSizeMake(100, 100)];
    CGFloat width = fitSize.width > 0 ? fitSize.width : 40;
    CGFloat height = fitSize.height > 0 ? fitSize.height : 40;

    UIView *transport = nil;
    @try {
        if ([playerView respondsToSelector:@selector(transportControlsView)]) transport = playerView.transportControlsView;
    } @catch (NSException *e) {}

    CGPoint center = CGPointMake(playerView.bounds.size.width - kSQButtonRightOffset - width / 2.0,
                                 playerView.bounds.size.height - height / 2.0 - 15);

    BOOL isCompactCC = transport != nil && !CGRectIsEmpty(transport.frame) && transport.frame.origin.x <= 0.5;
    if (isCompactCC) {
        // Compact Control Center: the row's own midX is pause's position.
        center.x = CGRectGetMidX(transport.frame);
    }

    // Derived straight from transportControlsView every call, same as SpotiLoveReborn's
    // heart button - reading another tweak's already-rendered frame instead raced its own
    // layoutSubviews hook during the lock screen's compact/full-screen transition.
    if (transport != nil && !CGRectIsEmpty(transport.frame)) {
        center.y = isCompactCC ? CGRectGetMinY(transport.frame) - 2 : CGRectGetMidY(transport.frame);
    }

    gSQMRUButton.frame = CGRectMake(center.x - width / 2.0, center.y - height / 2.0, width, height);
    [playerView bringSubviewToFront:gSQMRUButton];
}

void SQEnsureMRUButton(MRUNowPlayingView *playerView) {
    MRUNowPlayingViewController *owningVC = SQOwningNowPlayingVC(playerView);
    BOOL supported = SQIsSupportedNowPlayingContext(owningVC) && SQIsSpotifyNowPlaying();

    if (!supported) {
        if (gSQMRUButton && gSQMRUButton.superview == playerView) {
            [gSQMRUButton removeFromSuperview];
            gSQMRUButton = nil;
        }
        return;
    }
    if (gSQMRUButton && gSQMRUButton.superview == playerView) {
        SQLayoutMRUButton(playerView);
        return;
    }
    @try {
        if (gSQMRUButton && gSQMRUButton.superview) [gSQMRUButton removeFromSuperview];
    } @catch (id ignored) {}

    gSQMRUButton = [[UIButton alloc] init];
    gSQMRUButton.translatesAutoresizingMaskIntoConstraints = YES;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:22
                                                                                          weight:UIImageSymbolWeightMedium];
    UIImage *icon = [UIImage systemImageNamed:@"music.note.list" withConfiguration:config];
    [gSQMRUButton setImage:icon forState:UIControlStateNormal];
    gSQMRUButton.tintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.85];
    [gSQMRUButton addTarget:playerView action:@selector(sq_buttonTappedFromView)
            forControlEvents:UIControlEventTouchUpInside];
    [playerView addSubview:gSQMRUButton];
    SQLayoutMRUButton(playerView);
}

%hook MRUNowPlayingView

- (void)layoutSubviews {
    %orig;
    if (@available(iOS 16, *)) SQEnsureMRUButton((MRUNowPlayingView *)self);
}

%new
- (void)sq_buttonTappedFromView { SQButtonTapped(NO); }

%end

%ctor {
    if (@available(iOS 16, *)) {
        // No SQApplySandbox() here: this half only posts an unsandboxed Darwin notification.
        SQLog("ctor: proc=%{public}@ os=%{public}@", NSProcessInfo.processInfo.processName,
              NSProcessInfo.processInfo.operatingSystemVersionString);
        SQStartNowPlayingTracking();
    }
}
