# Verification

## Automated checks

Run `./scripts/test.sh` on macOS. These checks cover:

- Legacy settings migration, all destination/audio combinations, native overrides.
- Global mute preserving independent sound choices, manual pause, Low Power Mode policy and image selection, restore behavior.
- Audio routing and one audible surface.
- Remote surface geometry and lock/presentation lifecycle (where built through their dedicated harness).

The actual video renderer was previously tested with real media across two loops, shared audio/video clocks, mute, repeated Apply, pause/resume, and deep pause. Sampled shared-clock difference stayed below a millisecond; this does not measure acoustic output latency.

`Tests/MediaSyncTests.swift` accepts a path to a user-supplied video containing audio. The movie itself is not included in the repository. These integration tests are muted and offscreen; live compositor behavior and audible lip-sync require checking on a Mac.

## Live checks for this update

- Native app builds; strict nested signature verification passes for both the development build and the Developer ID signed preview.
- The signed app was launched locally, and macOS successfully launched its signed native wallpaper extension after refreshing the wallpaper host. The live extension restored the existing selected video and screen geometry.
- Existing sound/animation preferences survive the new settings fields.
- Selecting Low Power Mode pause on a Mac with Low Power Mode active changes the live renderer to paused.
- Live image selection reaches the native renderer; switching back restores video playback.
- Offscreen real-media tests passed for image decoding/sizing, deduplication, pause, frozen audio/video clock, restore/resume, and missing-image fallback. Run `./scripts/test-power-image.sh /path/video.mov /path/image.png`.
- Menu actions are implemented and their settings behavior is covered; audible output and remote compositor appearance still require visual/listening checks.

## Distribution status

The preview has a valid Developer ID Application signature, hardened runtime, and a secure timestamp. Strict nested signature verification passed. It contains no starter movie. Notarization is pending on Apple account credentials; no accepted ticket, stapling, or Gatekeeper acceptance is claimed. The downloadable preview is labelled as a prerelease.
