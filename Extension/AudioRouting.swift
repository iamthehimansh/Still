import Foundation

protocol StillAudioSink: AnyObject {
    /// Synchronous mute change; it must never seek or restart the media clock.
    func setAudioEnabled(_ enabled: Bool)
}

/// There may be multiple native surfaces (Spaces, previews, lock screen, displays),
/// but only the currently selected live surface may send sound to the speakers.
@MainActor
final class AudioRouting {
    private weak var audible: (any StillAudioSink)?

    func route(to target: (any StillAudioSink)?) {
        if audible === target { return }
        audible?.setAudioEnabled(false)
        audible = target
        target?.setAudioEnabled(true)
    }
}
