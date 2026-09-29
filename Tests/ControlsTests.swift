import Foundation

@main
struct ControlsTests {
    static func main() throws {
        let old = Data(#"{"videoName":"Movie","wallpaperEnabled":true,"wallpaperAudio":true,"screenSaverEnabled":true,"screenSaverAudio":false,"lockScreenEnabled":true,"lockScreenAudio":true}"#.utf8)
        let saved = try JSONDecoder().decode(StillSettings.self, from: old)
        precondition(saved.wallpaperAudio && saved.lockScreenAudio && !saved.screenSaverAudio)
        precondition(saved.playbackPaused != true && saved.globallyMuted != true)
        for behavior in [nil, "continue", "pause", "image", "unknown"] as [String?] {
            for lowPower in [false, true] {
                for paused in [false, true] {
                    var next = saved
                    next.lowPowerBehavior = behavior
                    next.playbackPaused = paused
                    next.lowPowerImagePath = "/tmp/chosen.png"
                    let config = try JSONDecoder().decode(StillConfiguration.self, from: JSONEncoder().encode(next))
                    precondition(config.shouldPause(lowPower: lowPower) == (paused || (lowPower && (behavior == "pause" || behavior == "image"))))
                    precondition((config.powerImageURL(lowPower: lowPower) != nil) == (lowPower && behavior == "image"))
                    next.globallyMuted = true
                    let muted = try JSONDecoder().decode(StillConfiguration.self, from: JSONEncoder().encode(next))
                    for mode in ["active", "idle", "locked"] { precondition(!muted.audio(in: mode)) }
                    next.globallyMuted = false
                    let restored = try JSONDecoder().decode(StillConfiguration.self, from: JSONEncoder().encode(next))
                    precondition(restored.audio(in: "active") && restored.audio(in: "locked") && !restored.audio(in: "idle"))
                }
            }
        }
        print("PASS: Legacy migration, mute preserves per-surface preferences, pause, all Low Power Mode policies, image selection and restore.")
    }
}
