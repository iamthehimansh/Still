import Foundation
import CoreMedia

extension VideoRenderer: StillAudioSink {}

/// Selects one native surface's synchronized audio. The renderer owns both tracks
/// and their common media clock; this coordinator changes only their audibility.
@MainActor
final class StillAudio {
    static let shared = StillAudio()
    private let routing = AudioRouting()
    private var reportedState: String?

    func update(config: StillConfiguration, mode: String, shouldPlay: Bool) {
        let enabled = shouldPlay && !config.shouldPause(lowPower: PowerMonitor.shared.currentState.isLowPowerModeEnabled) && config.enabled(in: mode) && config.audio(in: mode)
        let renderer = enabled ? WallpaperState.shared.preferredAudioRenderer : nil
        routing.route(to: renderer)
        let report = "\(mode):\(renderer.map { "renderer #\($0.debugID)" } ?? "muted")"
        if report != reportedState {
            reportedState = report
            extensionLog("[Audio] \(report); synchronized with native video, sound=\(config.audio(in: mode))")
            if let renderer {
                Task { [weak renderer] in
                    try? await Task.sleep(for: .seconds(1))
                    guard let renderer else { return }
                    let sample = await renderer.synchronizationSnapshot()
                    let skew = sample.audioTime.map { abs($0.seconds - sample.videoTime.seconds) }
                    extensionLog("[Audio sync] \(renderer.syncDiagnostic()); clockDifference=\(skew.map { String(format: "%.6f s", $0) } ?? "no audio"), videoStatus=\(sample.videoStatus), audioStatus=\(sample.audioStatus.map(String.init) ?? "none")")
                }
            }
        }
    }

    func stop() { routing.route(to: nil) }
}
