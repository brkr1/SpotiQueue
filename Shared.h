// Shared constants for the SpotiQueue Spotify-provider <-> SpringBoard-display IPC.
// One LightMessaging service carries both queries and actions, discriminated by msgh_id.
#import <Foundation/Foundation.h>
#import <os/log.h>
#import <dlfcn.h>
#import <notify.h>

// DEBUG-only os_log; compiled to a no-op in FINALPACKAGE builds.
// Build with `make package DEBUG=1` to get these in Console.app.
#ifdef DEBUG
#define SQLog(fmt, ...) os_log(OS_LOG_DEFAULT, "[SpotiQueue] " fmt, ##__VA_ARGS__)
#else
#define SQLog(fmt, ...) do { if (0) os_log(OS_LOG_DEFAULT, "[SpotiQueue] " fmt, ##__VA_ARGS__); } while (0)
#endif

// ---- LightMessaging ----
// One service (Spotify runs the server); SpringBoard is the only client.
#define kSQServiceNameSpotify "com.brkr1.tweaks.spotiqueue.svc.spotify"

// Message IDs (LMMessage.head.msgh_id), the discriminator on the one connection.
// Two-way (SpringBoard blocks for a property-list reply):
#define kSQMsgIDQueueSnapshot 1  // no payload in -> {active, current*, tracks:[...]}
// Serves whatever's already cached; a miss kicks off an async fetch, result follows via kSQChangedNotify.
#define kSQMsgIDArtworkBatch  2  // in: NSArray<NSString*> of URIs -> out: NSDictionary<uri, NSData PNG/JPEG>
// One-way (fire-and-forget; SpringBoard does not wait on these):
#define kSQMsgIDPlayNow 3  // in: {uid, uri} -> reorder nextTracks to the front + MediaRemote next-track
#define kSQMsgIDRemove  4  // in: {uid, uri} -> remove that slot from nextTracks
#define kSQMsgIDReorder 5  // in: {uid, uri, toIndex} -> move that slot to real-track rank toIndex

// ---- Darwin notifications (no payload; just signals) ----
#define kSQChangedNotify "com.brkr1.tweaks.spotiqueue.changed" // provider -> display: re-query if the sheet is open
#define kSQOpenNotify    "com.brkr1.tweaks.spotiqueue.open"    // MediaRemoteUI trigger button -> SpringBoard: show the sheet
#define kSQOpenFromIslandNotify "com.brkr1.tweaks.spotiqueue.open_island" // same, but from the Dynamic Island button: sheet is positioned lower to clear it

// libSandy profile granting mach-register (Spotify) / mach-lookup (SpringBoard).
// Applied in each process's %ctor before any LM call.
#define kSQSandyProfile "com.brkr1.tweaks.spotiqueue"

// Caches the RESULT, not the attempt: SpringBoard starts before libSandy's own
// service is up, so a failed %ctor-time apply must stay retryable, not "done".
static inline BOOL SQApplySandbox(void) {
    static BOOL applied = NO;
    if (applied) return YES;

    void *h = dlopen("libsandy.dylib", RTLD_LAZY);
    if (!h) {
        // roothide's jbroot is randomised; resolve libsandy relative to our own
        // dylib path instead (…/<jbroot>/usr/lib/TweakInject/<half>.dylib).
        Dl_info info; memset(&info, 0, sizeof(info));
        if (dladdr((const void *)&SQApplySandbox, &info) && info.dli_fname) {
            NSString *self = @(info.dli_fname);
            NSRange r = [self rangeOfString:@"/usr/lib/" options:NSBackwardsSearch];
            if (r.location != NSNotFound) {
                NSString *lib = [[self substringToIndex:NSMaxRange(r)] stringByAppendingString:@"libsandy.dylib"];
                h = dlopen(lib.fileSystemRepresentation, RTLD_LAZY);
                SQLog("libSandy dlopen(%{public}@) = %p", lib, h);
            }
        }
    }
    int (*applyProfile)(const char *) = h ? (int (*)(const char *))dlsym(h, "libSandy_applyProfile") : NULL;
    if (applyProfile) {
        int r = applyProfile(kSQSandyProfile);
        SQLog("libSandy applyProfile(%s) = %d (0=ok)", kSQSandyProfile, r);
        applied = (r == 0);
    } else {
        SQLog("libSandy not available (h=%p)", h);
    }
    return applied;
}

// ---- Keys in the queue-snapshot dictionary (kSQMsgIDQueueSnapshot reply) ----
static NSString *const kSQKeyActive         = @"active";         // NSNumber(BOOL)
static NSString *const kSQKeyCurrentTitle   = @"currentTitle";   // NSString
static NSString *const kSQKeyCurrentSubtitle = @"currentSubtitle"; // NSString
static NSString *const kSQKeyCurrentURI     = @"currentURI";     // NSString
static NSString *const kSQKeyTracks         = @"tracks";         // NSArray<NSDictionary> (see below)

// One entry in kSQKeyTracks.
static NSString *const kSQKeyTitle    = @"title";    // NSString
static NSString *const kSQKeySubtitle = @"subtitle"; // NSString (artist)
static NSString *const kSQKeyURI      = @"uri";       // NSString
static NSString *const kSQKeyUID      = @"uid";       // NSString, per-queue-slot identity (a URI can repeat)

// kSQMsgIDPlayNow / kSQMsgIDRemove payload keys (same shape as one track entry above,
// only uid/uri are read).
static NSString *const kSQKeyToIndex = @"toIndex"; // NSNumber(NSUInteger), kSQMsgIDReorder only - target rank among real tracks
