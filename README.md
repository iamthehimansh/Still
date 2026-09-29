# Still

**One video. Your whole Mac.**

A minimal native macOS app for video wallpaper, screen saver, and the signed-in lock screen. Choose a local video, set your sound preferences, and let it play.

[Website](https://iamthehimansh.github.io/Still/) · [Issues](https://github.com/iamthehimansh/Still/issues)

## Features

- Independent animation and audio controls for wallpaper, screen saver, and lock screen.
- Menu bar **Play/Pause** and **Mute/Unmute**, without changing each destination’s sound preference.
- Low Power Mode: keep playing, pause, or show an image you choose. Normal playback returns when Low Power Mode ends; a manual pause remains paused.
- Audio and video use a shared playback clock. One active surface produces sound, even across multiple displays.
- Locally managed video and image copies. No account, analytics, or network service.

## Availability

Source is available now. A Developer ID signed and notarized public download is **pending**; no release is claimed until Apple’s signing and notarization checks complete. No movie clips are included in this repository.

Targets macOS 26+. Tested on Apple Silicon. Still uses private macOS wallpaper interfaces and may need updates after macOS changes. It is not an App Store app. The lock-screen feature applies to a signed-in session, not FileVault or the login screen before signing in.

## Build

Install Apple’s Command Line Tools, then run:

```sh
./build.sh
```

This produces `Still.app` using local ad-hoc signing. It is a development build, not a notarized release. Build output and private media are ignored by Git. The app starts without a video until you import your own.

## Set up

1. Open Still, choose a local QuickTime-playable video, and set each destination’s animation and sound switches.
2. Click **Apply video**.
3. Open **Wallpaper settings**, select Still, then select **Automatic** for your screen saver.
4. Use Still’s menu bar icon to pause or mute immediately. The Low Power Mode setting saves immediately; choose **Show an image** to import a still wallpaper.

Quitting the controls app does not stop the native wallpaper extension. To stop using Still, select a different wallpaper in System Settings. A disabled animation holds its current frame.

The app keeps files in `~/Library/Application Support/Still`; its extension keeps a separate local copy under `~/Library/Containers/local.still.wallpaper.extension/Data/Documents`. Original imported files are not changed.

## Development

- `Source/`: SwiftUI app, local settings, native wallpaper bridge.
- `Extension/`: native wallpaper rendering, synchronized audio, lifecycle and power policy.
- `Tests/`: configuration, transport, power, geometry, lifecycle, and real-media checks.
- `site/`: responsive static landing page; no dependencies or analytics.
- `scripts/`: repeatable test and release commands.

Run `./scripts/test.sh`. For rendering integration, supply a local video with audio to the optional media test described in [VERIFICATION.md](VERIFICATION.md).

For public distribution, see [RELEASING.md](RELEASING.md). Never commit signing certificates, keys, credentials, or imported media.

## Credits and license

MIT licensed. The native extension includes code adapted from [Phosphene](https://github.com/kageroumado/phosphene), under its MIT license. See [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES) and [ThirdParty/Phosphene-LICENSE](ThirdParty/Phosphene-LICENSE). The website’s landscape illustration is original project artwork.
