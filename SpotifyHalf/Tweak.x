// Runs inside com.spotify.client. Captures the live SPTPlayerService, reads the full
// up-next queue over the SPT* facade, and serves it over LightMessaging.
#import "../Shared.h"
#import "LightMessaging.h"
#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/runtime.h>

#pragma mark - Private Spotify interfaces

// How much lookahead to ask the core for. Confirmed on-device: real queues of 34-80
// tracks all came back whole, so 100 is generous headroom, not a hit ceiling.
static const unsigned long long kSQFutureCap = 100;
static const unsigned long long kSQReverseCap = 1; // we don't show history, just enough to not pass 0
static const double kSQArtworkPt = 120.0;

@interface SPTPlayerTrack : NSObject
@property (readonly, copy, nonatomic) NSURL *URI;
@property (copy, nonatomic) NSString *UID; // per-queue-slot identity - a URI can repeat
@property (readonly, nonatomic) NSString *trackTitle;
@property (readonly, nonatomic) NSString *artistName;
@property (readonly, nonatomic) NSURL *imageURL; // spotify:image:<hex>
@end

@interface SPTPlayerState : NSObject
@property (retain, nonatomic) SPTPlayerTrack *track;             // currently playing
@property (copy, nonatomic) NSArray<SPTPlayerTrack *> *future;   // upcoming, [0] = next
@property (copy, nonatomic) NSArray<SPTPlayerTrack *> *reverse;  // history, [0] = most recent
@property (copy, nonatomic) NSString *queueRevision;
@end

// `revision` is an optimistic-concurrency token the core validates on write, so
// every edit must be read-modify-write on a freshly fetched object (see -mutateQueue:).
@protocol SPTPlayerQueue <NSObject>
@property (copy, nonatomic) NSArray<SPTPlayerTrack *> *nextTracks;
@property (copy, nonatomic) NSString *revision;
@end

@protocol SPTPlayer <NSObject>
@property (readonly, copy, nonatomic) SPTPlayerState *state;
- (void)fetchQueue:(void (^)(id<SPTPlayerQueue> queue))block on:(dispatch_queue_t)on;
- (id)setQueue:(id)queue;
- (void)addPlayerObserver:(id)observer;
- (void)removePlayerObserver:(id)observer;
- (void)fetchState:(void (^)(SPTPlayerState *state))block
        reverseCap:(unsigned long long)reverseCap
         futureCap:(unsigned long long)futureCap
                on:(dispatch_queue_t)on;
@end

@protocol SPTPlayerObserver <NSObject>
@optional
- (void)player:(id)player stateDidChange:(id)state;
- (void)player:(id)player stateDidChange:(id)state fromState:(id)fromState;
@end

// Owns the dedicated *observation* player, guaranteed subscribed to the core.
// The three %hook-ed methods below are declared here too so %orig has real types.
@interface SPTPlayerServiceImplementation : NSObject
- (id)providePlayerWithViewURI:(id)uri featureIdentifier:(id)identifier;
- (void)addPlayerObserver:(id)observer;
- (void)removePlayerObserver:(id)observer;
- (void)fetchPlayerState:(void (^)(SPTPlayerState *state))block on:(dispatch_queue_t)on;
- (void)_injectDependenciesWithProvider:(id)provider;
- (void)loadLazily;
- (void)loadObservationPlayer;
@end

// Fallback capture target, in case the service shape changes under a Spotify update.
@interface SPTEsperantoPlayer : NSObject
- (id)initWithClient:(id)client interceptor:(id)interceptor viewURI:(id)uri
  referrerIdentifier:(id)referrerIdentifier featureIdentifier:(id)featureIdentifier
      featureVersion:(id)version timeGetter:(id)getter queue:(id)queue
  playerSubscription:(id)subscription;
@end

// NSURL (BetamaxSDK) - Spotify's own URI helpers. Declaration-only (no @implementation),
// so it never touches the ObjC runtime's category table.
@interface NSURL (SQSpotifyBetamax)
+ (id)spt_HTTPURLForImageWithSpotifyLink:(id)link size:(unsigned long long)size;
+ (unsigned long long)spt_optimalCDNImageSizeForSideInPoints:(double)points screenScale:(double)scale;
- (BOOL)spt_isDelimiter;
- (BOOL)spt_isMetaTrack;
@end

#pragma mark - Track helpers

static BOOL SQSameStr(NSString *a, NSString *b) { return a == b || [a isEqualToString:b]; }

// The core splices `spotify:delimiter` / `spotify:meta:*` pseudo-entries into the
// queue (context/queued boundaries); every read must filter them.
static BOOL SQIsRealTrack(SPTPlayerTrack *track) {
    if (!track) return NO;
    NSURL *uri = nil;
    @try { uri = track.URI; } @catch (__unused NSException *e) { return NO; }
    if (!uri) return NO;
    @try {
        if ([uri respondsToSelector:@selector(spt_isDelimiter)] && [uri spt_isDelimiter]) return NO;
        if ([uri respondsToSelector:@selector(spt_isMetaTrack)] && [uri spt_isMetaTrack]) return NO;
    } @catch (__unused NSException *e) {}
    NSString *s = uri.absoluteString;
    if ([s hasPrefix:@"spotify:delimiter"] || [s hasPrefix:@"spotify:meta:"]) return NO;
    return YES;
}

static NSString *SQTrackURI(SPTPlayerTrack *t) {
    @try { return t.URI.absoluteString; } @catch (__unused NSException *e) { return nil; }
}
static NSString *SQTrackUID(SPTPlayerTrack *t) {
    @try { return t.UID; } @catch (__unused NSException *e) { return nil; }
}

static NSURL *SQArtworkURL(SPTPlayerTrack *track) {
    NSURL *link = nil;
    @try { link = track.imageURL; } @catch (__unused NSException *e) {}
    if (!link) return nil;
    if ([link.scheme hasPrefix:@"http"]) return link;

    unsigned long long size = 0;
    @try {
        if ([NSURL respondsToSelector:@selector(spt_optimalCDNImageSizeForSideInPoints:screenScale:)]) {
            size = [NSURL spt_optimalCDNImageSizeForSideInPoints:kSQArtworkPt
                                                    screenScale:UIScreen.mainScreen.scale];
        }
    } @catch (__unused NSException *e) {}
    @try {
        if (size && [NSURL respondsToSelector:@selector(spt_HTTPURLForImageWithSpotifyLink:size:)]) {
            NSURL *u = [NSURL spt_HTTPURLForImageWithSpotifyLink:link size:size];
            if (u) return u;
        }
    } @catch (__unused NSException *e) {}

    NSString *s = link.absoluteString;
    NSString *prefix = @"spotify:image:";
    if ([s hasPrefix:prefix]) {
        NSString *hex = [s substringFromIndex:prefix.length];
        if (hex.length) return [NSURL URLWithString:[@"https://i.scdn.co/image/" stringByAppendingString:hex]];
    }
    return nil;
}

#pragma mark - MediaRemote (next-track command, sent right after our own setQueue: succeeds)

// Resolved lazily via dlopen, so it's never force-loaded (LC_LOAD_DYLIB) into
// every process this dylib injects into.
static Boolean (*SQSendMRCommand(void))(unsigned int, id) {
    static Boolean (*fn)(unsigned int, id) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (h) fn = (Boolean (*)(unsigned int, id))dlsym(h, "MRMediaRemoteSendCommand");
        SQLog("MRMediaRemoteSendCommand=%p (h=%p)", fn, h);
    });
    return fn;
}
// kMRMediaRemoteCommandNextTrack. Confirmed to map to a REAL advance-to-next-track
// for Spotify (LockScreenRemoteNextTrackCommand), unlike iOS 17+ Podcasts (30s skip).
static const unsigned int kSQMRCommandNextTrack = 4;

#pragma mark - Provider

@interface SQSpotifyProvider : NSObject <SPTPlayerObserver>
@property (nonatomic, weak) SPTPlayerServiceImplementation *service;
@property (nonatomic, weak) id<SPTPlayer> capturedPlayer;
@property (nonatomic, strong) id<SPTPlayer> ownPlayer;
@property (nonatomic, strong) SPTPlayerState *cachedState;
@property (nonatomic) BOOL observerAttached;
@property (nonatomic) BOOL serverStarted;
@property (nonatomic, copy) NSString *lastRevision;
@property (nonatomic, copy) NSString *lastTrackURI;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *artworkByURI;
@property (nonatomic, strong) NSMutableSet<NSString *> *artworkInFlight;
@property (nonatomic, strong) NSURLSession *urlSession;
@end

// Must comfortably exceed kSQFutureCap: a limit close to a real queue's size caused
// a thrash loop on-device (80-track playlist against an 80 limit, endless evict/refetch).
static const NSUInteger kSQArtworkCacheLimit = 300;

@implementation SQSpotifyProvider

+ (instancetype)shared {
    static SQSpotifyProvider *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SQSpotifyProvider new]; });
    return s;
}

#pragma mark Capture / observation

- (void)captureService:(id)service {
    if (!service || self.service == service) return;
    if (self.service) {
        // A new service means Spotify rebuilt its player stack - detach from the
        // retired objects first so they can't overwrite cachedState afterward.
        SPTPlayerServiceImplementation *old = self.service;
        if ([old respondsToSelector:@selector(removePlayerObserver:)]) {
            @try { [old removePlayerObserver:self]; } @catch (__unused NSException *e) {}
        }
        if ([self.ownPlayer respondsToSelector:@selector(removePlayerObserver:)]) {
            @try { [self.ownPlayer removePlayerObserver:self]; } @catch (__unused NSException *e) {}
        }
        self.observerAttached = NO;
        self.ownPlayer = nil;
    }
    self.service = (SPTPlayerServiceImplementation *)service;
    SQLog("captured SPTPlayerService %p", service);
    dispatch_async(dispatch_get_main_queue(), ^{ [self attachObserver]; });
}

- (void)capturePlayer:(id)player {
    if (!player || self.capturedPlayer == player) return;
    // SPTPlayerServiceImplementation is missing on this build (see the %ctor probe),
    // so this fires for every throwaway feature player - never replace a working one.
    if (self.observerAttached && self.capturedPlayer) return;
    self.capturedPlayer = (id<SPTPlayer>)player;
    dispatch_async(dispatch_get_main_queue(), ^{ [self attachObserver]; });
}

- (id<SPTPlayer>)player {
    if (_ownPlayer) return _ownPlayer;
    SPTPlayerServiceImplementation *svc = self.service;
    if (svc && [svc respondsToSelector:@selector(providePlayerWithViewURI:featureIdentifier:)]) {
        @try {
            _ownPlayer = [svc providePlayerWithViewURI:[NSURL URLWithString:@"spotify:app:spotiqueue"]
                                     featureIdentifier:@"spotiqueue"];
            if (_ownPlayer) SQLog("minted player %p", _ownPlayer);
        } @catch (NSException *e) { SQLog("providePlayer threw %{public}@", e.name); }
    }
    return _ownPlayer ?: self.capturedPlayer;
}

- (void)attachObserver {
    if (self.observerAttached) return;
    SPTPlayerServiceImplementation *svc = self.service;
    if (svc && [svc respondsToSelector:@selector(addPlayerObserver:)]) {
        @try { [svc addPlayerObserver:self]; self.observerAttached = YES; }
        @catch (NSException *e) { SQLog("service addPlayerObserver threw %{public}@", e.name); }
    }
    if (!self.observerAttached) {
        id<SPTPlayer> p = [self player];
        if (p && [p respondsToSelector:@selector(addPlayerObserver:)]) {
            @try { [p addPlayerObserver:self]; self.observerAttached = YES; }
            @catch (NSException *e) { SQLog("player addPlayerObserver threw %{public}@", e.name); }
        }
    }
    if (self.observerAttached) {
        SQLog("observing player state");
        [self refreshState];
    } else {
        SQLog("attachObserver: no observer target yet (service=%p player=%p)", self.service, [self player]);
    }
}

#pragma mark SPTPlayerObserver

- (void)player:(id)player stateDidChange:(id)state { [self handleState:state]; }
- (void)player:(id)player stateDidChange:(id)state fromState:(id)fromState { [self handleState:state]; }

- (void)handleState:(SPTPlayerState *)state {
    if (!state) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *rev = nil, *uri = nil;
        @try { rev = state.queueRevision; } @catch (__unused NSException *e) {}
        @try { uri = SQTrackURI(state.track); } @catch (__unused NSException *e) {}
        BOOL comparable = (rev != nil || uri != nil);
        NSArray *fut = [self realFutureTracks];
        BOOL unfilled = fut.count > 0 && ![self infoForTrack:fut.firstObject];
        if (comparable && !unfilled
            && SQSameStr(rev, self.lastRevision) && SQSameStr(uri, self.lastTrackURI)) return;
        self.lastRevision = rev;
        self.lastTrackURI = uri;
        self.cachedState = state;
        SQLog("state changed: rev=%{public}@ current=%{public}@", rev, uri);
        [self changed];
        [self refreshState];
    });
}

- (void)refreshState {
    __weak typeof(self) weakSelf = self;
    void (^store)(SPTPlayerState *) = ^(SPTPlayerState *st) {
        typeof(self) self = weakSelf;
        if (!self || !st) return;
        self.cachedState = st;
        [self changed];
    };
    id<SPTPlayer> p = [self player];
    if (p && [p respondsToSelector:@selector(fetchState:reverseCap:futureCap:on:)]) {
        @try {
            [p fetchState:store reverseCap:kSQReverseCap futureCap:kSQFutureCap
                       on:dispatch_get_main_queue()];
            return;
        } @catch (NSException *e) { SQLog("fetchState threw %{public}@", e.name); }
    }
    SPTPlayerServiceImplementation *svc = self.service;
    if (svc && [svc respondsToSelector:@selector(fetchPlayerState:on:)]) {
        @try { [svc fetchPlayerState:store on:dispatch_get_main_queue()]; }
        @catch (NSException *e) { SQLog("fetchPlayerState threw %{public}@", e.name); }
    }
}

#pragma mark Queue reading

- (NSArray<SPTPlayerTrack *> *)realFutureTracks {
    NSArray *future = nil;
    @try { future = self.cachedState.future; } @catch (__unused NSException *e) { return @[]; }
    NSMutableArray *out = [NSMutableArray array];
    for (SPTPlayerTrack *t in future) if (SQIsRealTrack(t)) [out addObject:t];
    return out;
}

- (NSDictionary *)infoForTrack:(SPTPlayerTrack *)track {
    if (!track) return nil;
    NSString *title = nil, *artist = nil;
    @try { title = track.trackTitle; artist = track.artistName; } @catch (__unused NSException *e) {}
    NSString *uri = SQTrackURI(track);
    if (title.length == 0 || uri.length == 0) return nil;
    NSString *uid = SQTrackUID(track) ?: uri;
    return @{ kSQKeyTitle: title, kSQKeySubtitle: artist ?: @"", kSQKeyURI: uri, kSQKeyUID: uid };
}

- (NSDictionary *)queueSnapshotDictionary {
    NSArray<SPTPlayerTrack *> *future = [self realFutureTracks];
    NSString *curTitle = nil, *curArtist = nil, *curURI = nil;
    SPTPlayerTrack *current = nil;
    @try { current = self.cachedState.track; } @catch (__unused NSException *e) {}
    if (current) {
        @try { curTitle = current.trackTitle; curArtist = current.artistName; } @catch (__unused NSException *e) {}
        curURI = SQTrackURI(current);
    }
    if (curTitle.length == 0 && future.count == 0) return @{ kSQKeyActive: @NO };

    NSMutableArray<NSDictionary *> *tracks = [NSMutableArray arrayWithCapacity:future.count];
    for (SPTPlayerTrack *t in future) {
        NSDictionary *info = [self infoForTrack:t];
        if (info) {
            [tracks addObject:info];
            [self prefetchArtworkForURI:info[kSQKeyURI] track:t];
        }
    }
    if (current) [self prefetchArtworkForURI:curURI track:current];

    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[kSQKeyActive] = @YES;
    dict[kSQKeyCurrentTitle] = curTitle ?: @"";
    dict[kSQKeyCurrentSubtitle] = curArtist ?: @"";
    dict[kSQKeyCurrentURI] = curURI ?: @"";
    dict[kSQKeyTracks] = tracks;
    return dict;
}

#pragma mark Artwork (async CDN fetch, cached by track URI)

- (NSURLSession *)session {
    if (!_urlSession) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.requestCachePolicy = NSURLRequestReturnCacheDataElseLoad;
        _urlSession = [NSURLSession sessionWithConfiguration:cfg];
    }
    return _urlSession;
}

- (void)prefetchArtworkForURI:(NSString *)uri track:(SPTPlayerTrack *)track {
    if (uri.length == 0 || !track) return;
    if (self.artworkByURI[uri]) return;
    if ([self.artworkInFlight containsObject:uri]) return;
    NSURL *url = SQArtworkURL(track);
    if (!url) { SQLog("prefetchArtwork: no CDN URL for '%{public}@'", uri); return; }
    if (!self.artworkByURI) self.artworkByURI = [NSMutableDictionary dictionary];
    if (!self.artworkInFlight) self.artworkInFlight = [NSMutableSet set];
    [self.artworkInFlight addObject:uri];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithURL:url
                                            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        UIImage *img = data.length ? [UIImage imageWithData:data] : nil;
        NSData *store = img ? data : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf; if (!self) return;
            [self.artworkInFlight removeObject:uri];
            if (!store) { SQLog("artwork fetch failed for '%{public}@' err=%{public}@", uri, err); return; }
            self.artworkByURI[uri] = store;
            if (self.artworkByURI.count > kSQArtworkCacheLimit) {
                // Unordered eviction is fine: our whole cache IS the on-screen window
                // while the sheet is open, so there's no fixed small set to protect.
                NSString *victim = self.artworkByURI.allKeys.firstObject;
                if (victim) [self.artworkByURI removeObjectForKey:victim];
            }
            [self changed];
        });
    }];
    [task resume];
}

// kSQMsgIDArtworkBatch reply: whatever's already cached; anything missing is
// kicked off here (or was already, via -queueSnapshotDictionary's prefetch).
- (NSDictionary<NSString *, NSData *> *)artworkReplyForURIs:(NSArray<NSString *> *)uris {
    NSMutableDictionary<NSString *, NSData *> *out = [NSMutableDictionary dictionary];
    NSArray<SPTPlayerTrack *> *future = [self realFutureTracks];
    for (NSString *uri in uris) {
        if (![uri isKindOfClass:NSString.class] || uri.length == 0) continue;
        NSData *cached = self.artworkByURI[uri];
        if (cached) { out[uri] = cached; continue; }
        for (SPTPlayerTrack *t in future) {
            if (SQSameStr(SQTrackURI(t), uri)) { [self prefetchArtworkForURI:uri track:t]; break; }
        }
    }
    return out;
}

#pragma mark Actions

// Every queue edit is read-modify-write on a freshly fetched queue: `revision` is a
// concurrency token the core validates, so the written object must be the one just read.
- (void)mutateQueue:(NSString *)what using:(BOOL (^)(id<SPTPlayerQueue> queue))mutate
         completion:(void (^)(BOOL success))completion {
    id<SPTPlayer> p = [self player];
    if (!p || ![p respondsToSelector:@selector(fetchQueue:on:)] || ![p respondsToSelector:@selector(setQueue:)]) {
        SQLog("%{public}@: no usable player", what);
        if (completion) completion(NO);
        return;
    }
    __weak typeof(self) weakSelf = self;
    @try {
        [p fetchQueue:^(id<SPTPlayerQueue> q) {
            typeof(self) self = weakSelf;
            if (!self || !q) { SQLog("%{public}@: no queue", what); if (completion) completion(NO); return; }
            BOOL ok = NO;
            @try {
                if (mutate(q)) {
                    [p setQueue:q];
                    SQLog("%{public}@: queue written (revision %{public}@)", what, q.revision);
                    ok = YES;
                }
            } @catch (NSException *e) { SQLog("%{public}@ threw %{public}@", what, e.name); }
            [self changedSoon];
            if (completion) completion(ok);
        } on:dispatch_get_main_queue()];
    } @catch (NSException *e) {
        SQLog("%{public}@ fetchQueue threw %{public}@", what, e.name);
        if (completion) completion(NO);
    }
}

// Locates the queue slot by UID first (per-slot identity; a URI can repeat), falling
// back to URI. Returns NSNotFound if it's no longer there (queue moved under us).
static NSUInteger SQFindSlot(NSArray<SPTPlayerTrack *> *tracks, NSString *uid, NSString *uri) {
    if (uid.length) {
        for (NSUInteger i = 0; i < tracks.count; i++) if (SQSameStr(SQTrackUID(tracks[i]), uid)) return i;
    }
    if (uri.length) {
        for (NSUInteger i = 0; i < tracks.count; i++) if (SQSameStr(SQTrackURI(tracks[i]), uri)) return i;
    }
    return NSNotFound;
}

- (void)playTrackWithUID:(NSString *)uid uri:(NSString *)uri {
    SQLog("playTrackWithUID: uid=%{public}@ uri=%{public}@", uid, uri);
    [self mutateQueue:@"playNow" using:^BOOL(id<SPTPlayerQueue> q) {
        NSMutableArray *next = [q.nextTracks mutableCopy] ?: [NSMutableArray array];
        NSUInteger idx = SQFindSlot(next, uid, uri);
        if (idx == NSNotFound) {
            SQLog("playNow: '%{public}@' not found in nextTracks anymore", uri);
            return NO;
        }
        SPTPlayerTrack *target = next[idx];
        [next removeObjectAtIndex:idx];
        [next insertObject:target atIndex:0];
        q.nextTracks = next;
        return YES;
    } completion:^(BOOL success) {
        if (!success) return;
        // Same call site / same process as the confirmed-working setQueue: above -
        // no cross-process race between the reorder landing and the transport command.
        Boolean (*send)(unsigned int, id) = SQSendMRCommand();
        if (send) {
            Boolean sent = send(kSQMRCommandNextTrack, nil);
            SQLog("playNow: MediaRemote next-track sent=%d", sent);
        } else {
            SQLog("playNow: reorder ok but MRMediaRemoteSendCommand unavailable - track is queued next but won't auto-advance");
        }
    }];
}

- (void)removeTrackWithUID:(NSString *)uid uri:(NSString *)uri {
    SQLog("removeTrackWithUID: uid=%{public}@ uri=%{public}@", uid, uri);
    [self mutateQueue:@"remove" using:^BOOL(id<SPTPlayerQueue> q) {
        NSMutableArray *next = [q.nextTracks mutableCopy];
        NSUInteger idx = SQFindSlot(next, uid, uri);
        if (idx == NSNotFound) {
            SQLog("remove: '%{public}@' not found in nextTracks anymore", uri);
            return NO;
        }
        [next removeObjectAtIndex:idx];
        q.nextTracks = next;
        return YES;
    } completion:nil];
}

// q.nextTracks has pseudo-entries interleaved with real ones, so "the Nth real
// track" and "raw index N" differ; walks counting only real entries to realRank.
static NSUInteger SQRawIndexForRealRank(NSArray<SPTPlayerTrack *> *tracks, NSUInteger realRank) {
    NSUInteger seenReal = 0;
    for (NSUInteger i = 0; i < tracks.count; i++) {
        if (SQIsRealTrack(tracks[i])) {
            if (seenReal == realRank) return i;
            seenReal++;
        }
    }
    return tracks.count;
}

- (void)reorderTrackWithUID:(NSString *)uid uri:(NSString *)uri toRealIndex:(NSUInteger)toRealIndex {
    SQLog("reorderTrackWithUID: uid=%{public}@ uri=%{public}@ toRealIndex=%lu", uid, uri, (unsigned long)toRealIndex);
    [self mutateQueue:@"reorder" using:^BOOL(id<SPTPlayerQueue> q) {
        NSMutableArray *next = [q.nextTracks mutableCopy];
        NSUInteger fromIdx = SQFindSlot(next, uid, uri);
        if (fromIdx == NSNotFound) {
            SQLog("reorder: '%{public}@' not found in nextTracks anymore", uri);
            return NO;
        }
        SPTPlayerTrack *target = next[fromIdx];
        [next removeObjectAtIndex:fromIdx];
        // Rank computed AFTER removing the source slot, so "move track to rank 3"
        // means the same thing whether it started before or after rank 3.
        NSUInteger rawTarget = MIN(SQRawIndexForRealRank(next, toRealIndex), next.count);
        [next insertObject:target atIndex:rawTarget];
        q.nextTracks = next;
        return YES;
    } completion:nil];
}

- (void)changed { notify_post(kSQChangedNotify); }
- (void)changedSoon {
    dispatch_async(dispatch_get_main_queue(), ^{ [self changed]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self changed]; });
}

#pragma mark LightMessaging server

static void SQServerCallback(CFMachPortRef port, void *msg, CFIndex size, void *info) {
    LMMessage *message = (LMMessage *)msg;
    if (!message) return;
    mach_port_t replyPort = message->head.msgh_remote_port;
    SInt32 msgID = message->head.msgh_id;
    SQSpotifyProvider *provider = (__bridge SQSpotifyProvider *)info;

    id payload = nil;
    uint32_t len = LMMessageGetDataLength(message);
    void *bytes = LMMessageGetData(message);
    if (len && bytes) payload = LMPropertyListForData([NSData dataWithBytes:bytes length:len]);

    switch (msgID) {
        case kSQMsgIDQueueSnapshot: {
            LMSendPropertyListReply(replyPort, [provider queueSnapshotDictionary]);
            break;
        }
        case kSQMsgIDArtworkBatch: {
            NSArray *uris = [payload isKindOfClass:NSArray.class] ? payload : @[];
            LMSendPropertyListReply(replyPort, [provider artworkReplyForURIs:uris]);
            break;
        }
        case kSQMsgIDPlayNow: {
            NSDictionary *d = [payload isKindOfClass:NSDictionary.class] ? payload : nil;
            SQLog("LM: play-now request payload=%{public}@", d);
            [provider playTrackWithUID:d[kSQKeyUID] uri:d[kSQKeyURI]];
            break; // one-way: replyPort is MACH_PORT_NULL, nothing to send back
        }
        case kSQMsgIDRemove: {
            NSDictionary *d = [payload isKindOfClass:NSDictionary.class] ? payload : nil;
            SQLog("LM: remove request payload=%{public}@", d);
            [provider removeTrackWithUID:d[kSQKeyUID] uri:d[kSQKeyURI]];
            break;
        }
        case kSQMsgIDReorder: {
            NSDictionary *d = [payload isKindOfClass:NSDictionary.class] ? payload : nil;
            SQLog("LM: reorder request payload=%{public}@", d);
            NSNumber *toIndex = [d[kSQKeyToIndex] isKindOfClass:NSNumber.class] ? d[kSQKeyToIndex] : nil;
            if (toIndex) [provider reorderTrackWithUID:d[kSQKeyUID] uri:d[kSQKeyURI] toRealIndex:toIndex.unsignedIntegerValue];
            break;
        }
        default:
            SQLog("LM: unknown msgh_id=%d", (int)msgID);
    }
}

- (void)startServer {
    if (self.serverStarted) return;
    self.serverStarted = YES;
    kern_return_t kr = LMStartServiceWithUserInfo((char *)kSQServiceNameSpotify, CFRunLoopGetMain(),
                                                  SQServerCallback, (__bridge void *)self);
    SQLog("LMStartService '%s' kr=%d (0=ok)", kSQServiceNameSpotify, kr);
}

@end

#pragma mark - Hooks

%group SpotifyProvider

%hook SPTPlayerServiceImplementation

- (void)_injectDependenciesWithProvider:(id)provider {
    %orig;
    [[SQSpotifyProvider shared] captureService:self];
}

- (void)loadLazily {
    %orig;
    [[SQSpotifyProvider shared] captureService:self];
}

- (void)loadObservationPlayer {
    %orig;
    [[SQSpotifyProvider shared] captureService:self];
}

%end

%hook SPTEsperantoPlayer

- (id)initWithClient:(id)client interceptor:(id)interceptor viewURI:(id)uri
  referrerIdentifier:(id)referrerIdentifier featureIdentifier:(id)featureIdentifier
      featureVersion:(id)version timeGetter:(id)getter queue:(id)queue
  playerSubscription:(id)subscription {
    id r = %orig;
    if (r) [[SQSpotifyProvider shared] capturePlayer:r];
    return r;
}

%end

%end // SpotifyProvider

%ctor {
    @autoreleasepool {
        SQApplySandbox();
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        SQLog("ctor: proc=%{public}@ bundle=%{public}@ os=%{public}@",
              NSProcessInfo.processInfo.processName, bundleID,
              NSProcessInfo.processInfo.operatingSystemVersionString);
        if (![bundleID isEqualToString:@"com.spotify.client"]) return;
        %init(SpotifyProvider);
        [[SQSpotifyProvider shared] startServer];
        SQLog("loaded into Spotify");
#ifdef DEBUG
        // Interface-drift probe: after a Spotify update, a missing class/selector
        // here is the first thing to check when the sheet comes up empty.
        Class svc = objc_getClass("SPTPlayerServiceImplementation");
        if (!svc) SQLog("probe: SPTPlayerServiceImplementation MISSING");
        else if (![svc instancesRespondToSelector:@selector(addPlayerObserver:)])
            SQLog("probe: -addPlayerObserver: MISSING");
#endif
    }
}
