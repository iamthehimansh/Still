import CoreGraphics
import Foundation

/// On first selection macOS may only send acquire(), without an update().
/// Prefer the creation request's presentation. A narrowly-scoped fallback can
/// confirm the interactive desktop from the current logged-in WindowServer session.
enum InitialPresentation {
    static func interactiveDesktopIsConfirmed(session: [String: Any], recentInput: TimeInterval, knownLocked: Bool) -> Bool {
        guard !knownLocked,
              (session[kCGSessionOnConsoleKey as String] as? Bool) == true,
              (session[kCGSessionLoginDoneKey as String] as? Bool) == true,
              (session[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value == getuid(),
              (session["CGSSessionScreenIsLocked"] as? Bool) != true,
              recentInput.isFinite, recentInput >= 0, recentInput < 5 else { return false }
        return true
    }

    @discardableResult
    static func confirmInteractiveDesktopIfNeeded() -> Bool {
        let state = WallpaperState.shared
        if state.hasConfirmedLiveAcquisition { return true }
        guard state.hasNonPreviewContexts,
              let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        let recentInput = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        guard interactiveDesktopIsConfirmed(session: session, recentInput: recentInput, knownLocked: state.isScreenLocked) else { return false }
        guard state.confirmInitialInteractiveDesktop() else { return false }
        extensionLog("[Presentation] Initial active desktop confirmed by logged-in console session and recent input")
        return true
    }
}
