# Still native wallpaper extension

This extension supplies the actual desktop, screen saver, and signed-in Lock Screen through the macOS wallpaper host. It does not draw a password prompt or change login security. It does not replace the pre-login or FileVault screen.

The remote wallpaper and lifecycle implementation is adapted from [Phosphene](https://github.com/kageroumado/phosphene), copyright 2026 kageroumado, MIT licensed. The full license is in `../ThirdParty/Phosphene-LICENSE` and is embedded in the built extension. Still adds a single-video bridge and separate playback and audio settings for each place. It uses Apple's **private** WallpaperExtensionKit protocol and CAContext APIs. This is not an Apple-supported public extension API; future macOS updates may require changes.

## Build

Run `Extension/build-extension.sh /absolute/path/Still.app/Contents/Extensions/StillWallpaper.appex`, then sign the containing application. The script works with the Command Line Tools, compiles for the current machine's architecture and macOS 26+, and signs locally with an ad-hoc identity. It uses the native `NSExtensionMain` linker entry so macOS starts the extension service run loop; an ordinary Swift executable entry exits after registering its type. A paid signing identity is not required to build. Distribution to other Macs would need signing and notarization for normal Gatekeeper handling.

## Main app contract

The main app mirrors its settings into:

`~/Library/Containers/local.still.wallpaper.extension/Data/Documents/settings.json`

Copy the chosen video directly into that Documents directory under a managed filename. The mirrored `videoPath` must be the absolute path to that copied movie, not the original. This allows the sandboxed extension to read it after the source is moved, and after Still quits. A `videoName` string is optional and sets the system tile label.

Settings are optional JSON values:

- `wallpaperEnabled`, `screenSaverEnabled`, `lockScreenEnabled`: default true.
- `wallpaperAudio`, `screenSaverAudio`, `lockScreenAudio`: default false.
- `nativeDesktopEnabled`, `nativeScreenSaverEnabled`: default true; set false only when a separate desktop renderer or legacy saver owns that place.

The video choice's stable identifier is `44F94E52-0D9E-44C1-9939-B9EE5968E993`. The extension bundle ID is `local.still.wallpaper.extension`.

Post Darwin notification `local.still.wallpaper.prefsChanged` after writing settings. Post `local.still.wallpaper.libraryChanged` after replacing the video. The latter rescans, replaces active video renderers, clears audio, and pushes new thumbnails to System Settings. Write the new movie and settings completely before posting.

## Playback behavior

Remote context root layers use zero `anchorPoint` and `position`, with zero-origin destination bounds in points. Child video layers fill those bounds; `contentsScale` is the requested backing scale. Setting the remote root's frame with its default center anchor caused the quarter-screen clipping seen on this Retina Mac. Use `RemoteSurfaceGeometry` on creation and re-acquisition so the desktop, screen saver, and lock screen keep the same origin convention.

The wallpaper host reports a presentation mode. `locked` uses Lock Screen settings; `idle` uses Screen Saver settings; active/default uses Wallpaper settings. Turning a video toggle off freezes that place at the current frame. Turning sound off mutes its synchronized audio output without moving the media clock. The visible place determines the sound setting. Display sleep pauses both video and audio. Preview-only contexts never create an audio renderer. Audio requires a currently owned live surface and a recognized presentation, with a guarded interactive-desktop fallback when the host omits its initial update. Invalidation or connection loss revokes sound while the renderer may retain its visual surface briefly to avoid flashes. Critical thermal state pauses sound and video; low battery reduces rendering quality without overriding enabled places.

Each live VideoRenderer uses an AVSampleBufferRenderSynchronizer for its video display layer and optional AVSampleBufferAudioRenderer. Both tracks retain their original timestamps and use the same asset-duration loop offset. Pause, resume, rate changes, and video replacement update their common clock. AudioRouting unmutes exactly one confirmed live surface and mutes the previous one first; it never seeks or restarts playback. Apply with the same movie preserves its position. A movie without an audio track stays silent. Deep-pause resume maps the common clock back to the correct position within the current loop.

## Verification scope

The adapted extension compiles and ad-hoc signs on the installed Swift 6.4 Command Line Tools and macOS 26.6.2. The upstream renderer gives concurrency warnings against the installed macOS 27 SDK; there are no compiler errors. The extension is registered and selected in System Settings, with Automatic screen saver selected. Native live rendering contexts and wallpaper audio start/mute/resume were confirmed in runtime diagnostics. The screen saver and lock/unlock transitions, sound heard through speakers, and multiple physical displays remain unverified. See `../VERIFICATION.md` for the exact scope.

The extension writes a bounded diagnostic log to its Documents directory as `extension.log` and updates `still-state.json` with acquired non-preview contexts that have renderers. Retained invalidated surfaces and picker previews are excluded. A `VERBOSE_LOG` marker in that directory enables detailed lifecycle logging on the next extension launch.
