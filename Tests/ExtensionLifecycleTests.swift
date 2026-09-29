import Foundation
import CoreGraphics
import QuartzCore

#if LIFECYCLE_STUBS
// Compile these lifecycle tests independently of the media pipeline.
final class VideoRenderer: @unchecked Sendable {
    let debugID = 0
    func stop() {}
}
func traceLog(_ message: String) {}
func extensionLog(_ message: String) {}
#endif

@main
struct ExtensionLifecycleTests {
    static func main() {
        let state = WallpaperState.shared
        let first = UUID(), second = UUID(), lockOwner = UUID()
        let key = DisplayKey(displayID: 1, surfaceUUID: UUID())
        let other = DisplayKey(displayID: 1, surfaceUUID: UUID())
        let lockKey = DisplayKey(displayID: 1, surfaceUUID: UUID())

        assert(!state.hasConfirmedLiveAcquisition, "Startup must be silent before a recognized presentation.")
        state.registerWallpaperID(key.surfaceUUID, key: key)
        state.acquireLiveSurface(key, owner: first)
        assert(!state.hasConfirmedLiveAcquisition, "Acquiring alone must not permit audio.")
        assert(!state.notePresentedSurface(key, owner: second, mode: "active", activity: "active"))
        assert(!state.notePresentedSurface(key, owner: first, mode: "unknown", activity: "active"))
        assert(!state.notePresentedSurface(key, owner: first, mode: "active", activity: "unknown"))
        assert(state.notePresentedSurface(key, owner: first, mode: "default", activity: "active"),
               "A recognized creation mode must register before the context is installed.")
        assert(state.hasConfirmedLiveAcquisition)
        assert(!state.canPlayAudio, "Audio additionally requires a non-preview renderer.")

        state.acquireLiveSurface(other, owner: second)
        assert(state.presentationKey(owner: first) == key)
        assert(state.hasConfirmedLiveAcquisition, "Prewarming a second Space must not revoke the current presentation.")
        assert(!state.notePresentedSurface(other, owner: second, mode: "idle", activity: "suspended"))
        assert(state.presentationMode == "active" && state.activityState == "active",
               "An inactive nonpreferred surface must not overwrite the live mode.")
        assert(state.notePresentedSurface(other, owner: second, mode: "active", activity: "active"))
        assert(state.notePresentedSurface(key, owner: first, mode: "active", activity: "active"),
               "Returning to a retained Space can report active without a new acquire or prior suspension.")
        assert(state.notePresentedSurface(other, owner: second, mode: "active", activity: "active"))
        assert(!state.notePresentedSurface(key, owner: first, mode: "active", activity: "suspended"))
        assert(state.activityState == "active")
        assert(state.notePresentedSurface(key, owner: first, mode: "active", activity: "active"),
               "A fresh suspended-to-active transition must support returning to a cached Space.")

        state.acquireLiveSurface(lockKey, owner: lockOwner)
        state.isScreenLocked = true
        assert(!state.notePresentedSurface(key, owner: first, mode: "active", activity: "active"))
        assert(state.notePresentedSurface(lockKey, owner: lockOwner, mode: "locked", activity: "active"))
        assert(!state.notePresentedSurface(lockKey, owner: lockOwner, mode: "active", activity: "active"))
        assert(!state.notePresentedSurface(lockKey, owner: lockOwner, mode: "active", activity: "suspended"))
        assert(state.hasConfirmedLiveAcquisition, "Rejected stale modes must not erase the same UUID's accepted lock presentation.")
        assert(!state.notePresentedSurface(key, owner: first, mode: "active", activity: "suspended"))
        assert(state.isScreenLocked && state.presentationMode == "locked" && state.activityState == "active",
               "A stale desktop callback must not undo the lock notification or suspend lock-screen sound.")
        state.isScreenLocked = false
        assert(!state.notePresentedSurface(lockKey, owner: lockOwner, mode: "locked", activity: "active"),
               "A stale lock callback must not undo the unlock notification.")
        assert(state.notePresentedSurface(key, owner: first, mode: "active", activity: "active"))

        let replacement = UUID()
        state.acquireLiveSurface(key, owner: replacement)
        assert(!state.notePresentedSurface(key, owner: first, mode: "idle", activity: "active"),
               "An older connection must not drive a surface reacquired by a newer owner.")
        assert(!state.invalidateSurface(key, owner: first), "The old owner's invalidate must not schedule teardown.")
        assert(state.resolveWallpaperKey(key.surfaceUUID) == key, "The newer owner's UUID mapping must survive.")
        assert(state.connectionHasLiveSurface(owner: replacement, key: key))
        assert(state.notePresentedSurface(key, owner: replacement, mode: "active", activity: "active"))
        assert(state.invalidateSurface(key, owner: replacement), "Only the final owner schedules teardown.")
        assert(state.resolveWallpaperKey(key.surfaceUUID) == nil)
        assert(!state.hasConfirmedLiveAcquisition)

        let preview = DisplayKey(displayID: 2, surfaceUUID: UUID())
        state.registerWallpaperID(preview.surfaceUUID, key: preview)
        state.acquireSurface(preview, owner: first, isPreview: true)
        state.acquireSurface(preview, owner: second, isPreview: true)
        assert(!state.notePresentedSurface(preview, owner: second, mode: "active", activity: "active"))
        assert(!state.invalidateSurface(preview, owner: first))
        assert(state.resolveWallpaperKey(preview.surfaceUUID) == preview)
        assert(state.invalidateSurface(preview, owner: second))
        assert(state.resolveWallpaperKey(preview.surfaceUUID) == nil)
        state.endConnection(owner: second)
        state.endConnection(owner: lockOwner)
        assert(!state.hasConfirmedLiveAcquisition)

        // The real host uses both orders, often reporting the next mode about
        // 10–20 ms before loginwindow. All transitions below reuse the same UUID.
        let transitionKey = DisplayKey(displayID: 5, surfaceUUID: UUID())
        let transitionOwner = UUID()
        state.acquireLiveSurface(transitionKey, owner: transitionOwner)
        assert(state.notePresentedSurface(transitionKey, owner: transitionOwner, mode: "default", activity: "active"))
        for _ in 0..<2 {
            // XPC first: preserve desktop until the actual lock notification.
            assert(!state.notePresentedSurface(transitionKey, owner: transitionOwner, mode: "locked", activity: "active"))
            assert(!state.isScreenLocked && state.presentationMode == "active" && state.hasConfirmedLiveAcquisition)
            state.isScreenLocked = true
            assert(state.isScreenLocked && state.presentationMode == "locked" && state.hasConfirmedLiveAcquisition,
                   "The notification must promote an earlier locked XPC report without requiring another update.")
            assert(!state.notePresentedSurface(transitionKey, owner: transitionOwner, mode: "default", activity: "active"))
            assert(state.isScreenLocked && state.presentationMode == "locked" && state.hasConfirmedLiveAcquisition)
            state.isScreenLocked = true // A duplicate must preserve the pending unlock report.
            state.isScreenLocked = false
            assert(!state.isScreenLocked && state.presentationMode == "active" && state.hasConfirmedLiveAcquisition,
                   "The notification must promote an earlier unlocked XPC report on the same UUID.")

            // Notification first: wait silently for a matching recognized report.
            state.isScreenLocked = true
            assert(!state.hasConfirmedLiveAcquisition)
            assert(state.notePresentedSurface(transitionKey, owner: transitionOwner, mode: "locked", activity: "active"))
            assert(state.hasConfirmedLiveAcquisition)
            state.isScreenLocked = false
            assert(!state.hasConfirmedLiveAcquisition)
            assert(state.notePresentedSurface(transitionKey, owner: transitionOwner, mode: "default", activity: "active"))
            assert(state.hasConfirmedLiveAcquisition)
        }
        // A newer accepted report supersedes a stale conflicting pending report.
        assert(!state.notePresentedSurface(transitionKey, owner: transitionOwner, mode: "locked", activity: "active"))
        assert(state.notePresentedSurface(transitionKey, owner: transitionOwner, mode: "default", activity: "active"))
        state.isScreenLocked = true
        assert(!state.hasConfirmedLiveAcquisition, "An obsolete pending lock report must not regain audio.")
        assert(state.notePresentedSurface(transitionKey, owner: transitionOwner, mode: "locked", activity: "active"))
        assert(!state.notePresentedSurface(transitionKey, owner: transitionOwner, mode: "default", activity: "suspended"))
        state.isScreenLocked = false
        assert(!state.hasConfirmedLiveAcquisition, "A pending suspended presentation must never become audible.")
        assert(state.notePresentedSurface(transitionKey, owner: transitionOwner, mode: "idle", activity: "active"))
        state.isScreenLocked = true
        assert(state.hasConfirmedLiveAcquisition && state.effectivePresentationMode == "idle",
               "Automatic password lock must preserve a visible idle screen saver and its sound choice.")
        assert(state.notePresentedSurface(transitionKey, owner: transitionOwner, mode: "locked", activity: "active"))
        assert(state.effectivePresentationMode == "locked", "An actual locked presentation selects lock-screen sound.")
        state.isScreenLocked = false
        assert(state.notePresentedSurface(transitionKey, owner: transitionOwner, mode: "active", activity: "active"))
        state.isScreenLocked = true
        assert(state.notePresentedSurface(transitionKey, owner: transitionOwner, mode: "idle", activity: "active"))
        assert(state.hasConfirmedLiveAcquisition && state.effectivePresentationMode == "idle",
               "An idle update after the protection notification must also remain a screen-saver presentation.")
        state.isScreenLocked = false
        assert(state.notePresentedSurface(transitionKey, owner: transitionOwner, mode: "active", activity: "active"))
        assert(!state.notePresentedSurface(transitionKey, owner: transitionOwner, mode: "locked", activity: "active"))
        let newTransitionOwner = UUID()
        state.acquireLiveSurface(transitionKey, owner: newTransitionOwner)
        state.isScreenLocked = true
        assert(!state.hasConfirmedLiveAcquisition, "Replacing an owner must discard its unaccepted pending report.")
        state.isScreenLocked = false
        state.endConnection(owner: transitionOwner)
        state.endConnection(owner: newTransitionOwner)

        #if LIFECYCLE_STUBS
        let initial = DisplayKey(displayID: 3, surfaceUUID: UUID())
        state.acquireLiveSurface(initial, owner: first)
        state.installContext(ActiveWallpaper(caContext: NSObject(), contextId: 1, rootLayer: CALayer(),
            renderer: VideoRenderer(), displayID: 3, videoID: nil, isPreview: false,
            destSize: CGSize(width: 1920, height: 1080), scaleFactor: 1), for: initial)
        assert(state.confirmInitialInteractiveDesktop(), "A never-confirmed live desktop supports the guarded console fallback.")
        assert(state.canPlayAudio && state.preferredAudioRenderer != nil)
        assert(state.notePresentedSurface(initial, owner: first, mode: "active", activity: "suspended"))
        assert(!state.confirmInitialInteractiveDesktop(), "The fallback must not undo a host suspension.")
        assert(!state.canPlayAudio && state.preferredAudioRenderer == nil)
        state.endConnection(owner: first)
        state.tearDownContext(for: initial)
        #endif

        let reacquired = DisplayKey(displayID: 4, surfaceUUID: UUID())
        state.acquireLiveSurface(reacquired, owner: first)
        state.acquireLiveSurface(reacquired, owner: second)
        assert(state.endConnection(owner: first).isEmpty)
        assert(state.connectionHasLiveSurface(owner: second, key: reacquired))
        assert(state.endConnection(owner: second) == [reacquired])
        assert(!state.hasNonPreviewContexts)
        assert(state.activeDisplayContexts().isEmpty)

        var console: [String: Any] = [kCGSessionOnConsoleKey as String: true, kCGSessionLoginDoneKey as String: true,
                                     kCGSessionUserIDKey as String: NSNumber(value: getuid())]
        assert(InitialPresentation.interactiveDesktopIsConfirmed(session: console, recentInput: 0.2, knownLocked: false))
        assert(!InitialPresentation.interactiveDesktopIsConfirmed(session: console, recentInput: 30, knownLocked: false))
        assert(!InitialPresentation.interactiveDesktopIsConfirmed(session: console, recentInput: 0.2, knownLocked: true))
        console["CGSSessionScreenIsLocked"] = true
        assert(!InitialPresentation.interactiveDesktopIsConfirmed(session: console, recentInput: 0.2, knownLocked: false))
        console["CGSSessionScreenIsLocked"] = false
        console[kCGSessionOnConsoleKey as String] = false
        assert(!InitialPresentation.interactiveDesktopIsConfirmed(session: console, recentInput: 0.2, knownLocked: false))

        let lowBattery = PlaybackPolicy.compute(presentationMode: "active", activityState: "active", userPaused: false,
            alwaysPauseDesktop: false, pauseWhenOccluded: false, desktopOccluded: false, screenSaverIsOurs: true,
            thermalState: .nominal, isOnBattery: true, batteryLevel: 7, isGameModeActive: false)
        assert(lowBattery == .minimal)
        print("PASS: per-surface presentation, stale callbacks, lock authority, preview silence, owner-scoped invalidation, initial desktop fallback, and power policy")
    }
}
