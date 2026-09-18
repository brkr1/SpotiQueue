// Dynamic Island expanded now-playing player. Covers both class generations -
// MRUActivityNowPlayingView (iOS 17+) and MRUSessionNowPlayingView (iOS 16).
#import "../Shared.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>

extern BOOL SQIsSpotifyNowPlaying(void);
extern void SQButtonTapped(BOOL fromIsland);

@interface MRUActivityNowPlayingViewController : UIViewController
@property (nonatomic, readonly) long long activeLayoutMode;
@end

@interface MRUSessionNowPlayingViewController : UIViewController
@property (nonatomic, readonly) long long activeLayoutMode;
- (BOOL)isExpanded;
@end

static const long long kSQDIExpandedMode = 4; // activeLayoutMode when fully expanded
static const CGFloat kSQDIExpandedMinHeight = 120.0; // view is reused for the compact pill

// Which generation applies, decided by which %init ran - same trick SpotiLoveReborn
// (and originally Crescendo/NextUp3) uses for this exact split.
static BOOL (*gSQDIExpanded)(UIViewController *) = NULL;

static BOOL SQDIActivityExpanded(UIViewController *vc) {
    return ((MRUActivityNowPlayingViewController *)vc).activeLayoutMode >= kSQDIExpandedMode;
}

static BOOL SQDISessionExpanded(UIViewController *vc) {
    MRUSessionNowPlayingViewController *sessionVC = (MRUSessionNowPlayingViewController *)vc;
    @try {
        if ([sessionVC respondsToSelector:@selector(isExpanded)]) return [sessionVC isExpanded];
    } @catch (__unused NSException *e) {}
    return sessionVC.activeLayoutMode >= kSQDIExpandedMode;
}

static UIView *SQDIFindTransportControls(UIView *host) {
    static Class transportClass;
    if (!transportClass) transportClass = objc_getClass("MRUNowPlayingTransportControlsView");
    if (!transportClass) return nil;
    for (UIView *sub in host.subviews) if ([sub isKindOfClass:transportClass] && !sub.isHidden) return sub;
    return nil;
}

// Same technique that fixed the lock screen/CC button: borrow the heart button's Y.
static UIButton *SQFindSpotiLoveDIHeartButton(UIView *host) {
    for (UIView *sub in [host.subviews copy]) {
        if (![sub isKindOfClass:UIButton.class]) continue;
        NSString *title = [(UIButton *)sub currentTitle];
        if ([title isEqualToString:@"♥"] || [title isEqualToString:@"♡"]) return (UIButton *)sub;
    }
    return nil;
}

UIButton *gSQDIButton;

// Measured off a real screenshot to clear AirPlay (proportionally closer to the
// transport row here than on lock screen/CC, since DI's card is narrower).
static const CGFloat kSQDIButtonRightOffset = 70.0;

void SQLayoutDIButton(UIView *host) {
    if (!gSQDIButton) return;
    CGSize fitSize = [gSQDIButton sizeThatFits:CGSizeMake(100, 100)];
    CGFloat width = fitSize.width > 0 ? fitSize.width : 32;
    CGFloat height = fitSize.height > 0 ? fitSize.height : 32;
    CGFloat y = host.bounds.size.height - height - 15;
    UIView *transport = SQDIFindTransportControls(host);
    if (transport != nil && !CGRectIsEmpty(transport.frame)) {
        // Heart-button lookup found a stale/second one on DI specifically; transport
        // is the instance we're already laying out inside, so it takes priority here.
        y = CGRectGetMidY(transport.frame) - (height / 2.0);
    } else {
        UIButton *heart = SQFindSpotiLoveDIHeartButton(host);
        if (heart != nil && !CGRectIsEmpty(heart.frame)) y = heart.center.y - height / 2.0;
    }
    CGFloat x = host.bounds.size.width - width - kSQDIButtonRightOffset;
    gSQDIButton.frame = CGRectMake(x, y, width, height);
    [host bringSubviewToFront:gSQDIButton];
}

static BOOL SQDIShouldShow(UIView *host, UIViewController *vc) {
    return vc != nil && host.bounds.size.height >= kSQDIExpandedMinHeight
        && gSQDIExpanded != NULL && gSQDIExpanded(vc) && SQIsSpotifyNowPlaying();
}

void SQEnsureDIButton(UIView *host, UIViewController *vc) {
    if (!SQDIShouldShow(host, vc)) {
        if (gSQDIButton && gSQDIButton.superview == host) {
            [gSQDIButton removeFromSuperview];
            gSQDIButton = nil;
        }
        return;
    }
    if (gSQDIButton && gSQDIButton.superview == host) { SQLayoutDIButton(host); return; }
    @try { if (gSQDIButton && gSQDIButton.superview) [gSQDIButton removeFromSuperview]; } @catch (id ignored) {}

    gSQDIButton = [[UIButton alloc] init];
    gSQDIButton.translatesAutoresizingMaskIntoConstraints = YES;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:22
                                                                                          weight:UIImageSymbolWeightMedium];
    UIImage *icon = [UIImage systemImageNamed:@"music.note.list" withConfiguration:config];
    [gSQDIButton setImage:icon forState:UIControlStateNormal];
    gSQDIButton.tintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.85];
    [gSQDIButton addTarget:host action:@selector(sq_diButtonTappedFromView) forControlEvents:UIControlEventTouchUpInside];
    [host addSubview:gSQDIButton];
    SQLayoutDIButton(host);
}

#pragma mark - iOS 17+: MRUActivityNowPlaying*

@interface MRUActivityNowPlayingView : UIView
@end

%group SQDIActivity

%hook MRUActivityNowPlayingView

- (void)layoutSubviews {
    %orig;
    UIResponder *r = self.nextResponder;
    while (r && ![r isKindOfClass:objc_getClass("MRUActivityNowPlayingViewController")]) r = r.nextResponder;
    SQEnsureDIButton(self, (UIViewController *)r);
}

%new
- (void)sq_diButtonTappedFromView { SQButtonTapped(YES); }

%end

%end // SQDIActivity

#pragma mark - iOS 16: MRUSessionNowPlaying* (pre-Activity family)

@interface MRUSessionNowPlayingView : UIView
@end

%group SQDISession

%hook MRUSessionNowPlayingView

- (void)layoutSubviews {
    %orig;
    UIResponder *r = self.nextResponder;
    while (r && ![r isKindOfClass:objc_getClass("MRUSessionNowPlayingViewController")]) r = r.nextResponder;
    SQEnsureDIButton(self, (UIViewController *)r);
}

%new
- (void)sq_diButtonTappedFromView { SQButtonTapped(YES); }

%end

%end // SQDISession

// MediaControls.framework loads on demand; install once it shows up. Activity is
// checked first, Session as fallback, so either generation gets picked up.
static void SQDIInitIfLoaded(void) {
    static BOOL done = NO;
    if (done) return;
    if (objc_getClass("MRUActivityNowPlayingViewController")) {
        done = YES;
        gSQDIExpanded = SQDIActivityExpanded;
        SQLog("DI: MRUActivityNowPlayingViewController loaded, %%init(SQDIActivity)");
        %init(SQDIActivity);
    } else if (objc_getClass("MRUSessionNowPlayingViewController")) {
        done = YES;
        gSQDIExpanded = SQDISessionExpanded;
        SQLog("DI: MRUSessionNowPlayingViewController loaded, %%init(SQDISession)");
        %init(SQDISession);
    }
}

static void SQDIImageAdded(const struct mach_header *mh, intptr_t slide) { SQDIInitIfLoaded(); }

%ctor {
    SQLog("DI ctor: proc=%{public}@ os=%{public}@", NSProcessInfo.processInfo.processName,
          NSProcessInfo.processInfo.operatingSystemVersionString);
    if (@available(iOS 16, *)) {
        _dyld_register_func_for_add_image(SQDIImageAdded);
        SQLog("DI ctor: registered dyld image callback, Activity loaded=%d Session loaded=%d",
              objc_getClass("MRUActivityNowPlayingViewController") != nil,
              objc_getClass("MRUSessionNowPlayingViewController") != nil);
    } else {
        SQLog("DI ctor: skipped, iOS < 16");
    }
}
