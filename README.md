# SpotiQueue

Shows your whole Spotify queue, not just the next track, in a sheet you can pull up
from the Lock Screen, Control Center or Dynamic Island. Tap any track to play it now,
drag to reorder the queue, or swipe to remove one.

## Features

- Full up-next queue
- Tap a track to play it immediately
- Drag to reorder the queue
- Option to remove a track from the queue
- Trigger button on the Lock Screen, Control Center (compact and expanded) and
  Dynamic Island
- The screen doesn't auto-lock out from under the sheet while it's open
- Uses the real Liquid Glass backdrop from [liquidass](https://github.com/winaviation-tweaks/liquidass) if it's installed and active, falls back to a plain blur otherwise

## Tested Environment

- iPhone 14 Pro Max (iPhone15,3) / iOS 16.6.1 / roothide Bootstrap
- Other devices and iOS versions are untested and not yet supported

## Installation

Add this repo to Sileo/Zebra: https://brkr1.github.io/repo/

Or grab the `.deb` manually from [Releases](../../releases) and install it with
Sileo, Zebra, or Filza. After install or update, force-quit Spotify from the app
switcher so the new dylib loads (installing this tweak doesn't restart Spotify for
you); a respring covers SpringBoardHalf and MediaRemoteUIHalf.

## Building from source

Needs [Theos](https://theos.dev). arm64e needs the real Xcode toolchain (the
`-fno-ptrauth-objc-class-ro` probe in each half's Makefile only gives a correct
answer from Apple's own clang), which this workspace only has in CI, not locally.

```sh
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
# or, for the DEBUG build with SQLog output for Console.app:
make package DEBUG=1 THEOS_PACKAGE_SCHEME=rootless
```

## Support

If this tweak saved you some time (or a few taps), consider buying me a coffee:

<a href="https://buymeacoffee.com/brkr1" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="41" width="174"></a>

## Credits

- [NextUp3](https://github.com/Yves000/NextUp3) (Yves) - the Spotify SPT* facade
  (queue reading, artwork CDN rewrite, the confirmed MediaRemote next-track mapping)
  was learned from its `NUSpotifyProvider`/`NUNextUpManager`.
- [SpotiLove Reborn](https://github.com/brkr1/SpotiLoveReborn) (brkr1) - the lock
  screen / Control Center / Dynamic Island trigger-button technique, and its heart
  button is used directly as a position reference on every surface.
- [LyricationReborn](https://github.com/thatmarcel/LyricationReborn) (Marcel Braun) -
  the `SBIdleTimerService` hook that keeps the screen from auto-locking out from
  under the sheet.
- [liquidass](https://github.com/winaviation-tweaks/liquidass) - the
  `CABackdropLayer` + `CAFilter` real glass backdrop, used opportunistically.
- [LightMessaging](https://github.com/rpetrich/lightmessaging) (Ryan Petrich) - the
  vendored mach IPC library.

## License

MIT, see [LICENSE](LICENSE).
