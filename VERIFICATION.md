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

- Native app builds; strict nested signature verification passes for the local ad-hoc build.
- Existing sound/animation preferences survive the new settings fields.
- Selecting Low Power Mode pause on a Mac with Low Power Mode active changes the live renderer to paused.
- Menu bar actions and selected image rendering are checked separately during release preparation.

## Distribution status

Development build only until a Developer ID signature, accepted notarization ticket, stapling, and Gatekeeper check all pass. No public signed release has been certified by these source-level checks.
