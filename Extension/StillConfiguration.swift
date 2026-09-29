import Foundation

struct StillConfiguration: Codable, Sendable {
    var videoPath: String?
    var videoName: String?
    var wallpaperEnabled: Bool?
    var wallpaperAudio: Bool?
    var screenSaverEnabled: Bool?
    var screenSaverAudio: Bool?
    var lockScreenEnabled: Bool?
    var lockScreenAudio: Bool?
    var playbackPaused: Bool?
    var globallyMuted: Bool?
    var lowPowerBehavior: String?
    var lowPowerImagePath: String?
    var nativeDesktopEnabled: Bool?
    var nativeScreenSaverEnabled: Bool?

    static var documents: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
    }
    static func load() -> Self {
        guard let data = try? Data(contentsOf: documents.appendingPathComponent("settings.json")),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    var videoURL: URL? { videoPath.map { URL(fileURLWithPath: $0) } }
    func enabled(in mode: String) -> Bool {
        switch mode {
        case "locked": lockScreenEnabled ?? true
        case "idle": (screenSaverEnabled ?? true) && (nativeScreenSaverEnabled ?? true)
        default: (wallpaperEnabled ?? true) && (nativeDesktopEnabled ?? true)
        }
    }
    func pausesForPower(_ lowPower: Bool) -> Bool {
        lowPower && (lowPowerBehavior == "pause" || lowPowerBehavior == "image")
    }
    func shouldPause(lowPower: Bool) -> Bool { playbackPaused == true || pausesForPower(lowPower) }
    func powerImageURL(lowPower: Bool) -> URL? {
        guard lowPower, lowPowerBehavior == "image", let lowPowerImagePath else { return nil }
        return URL(fileURLWithPath: lowPowerImagePath)
    }
    func audio(in mode: String) -> Bool {
        if globallyMuted == true { return false }
        return audioChoice(in: mode)
    }
    private func audioChoice(in mode: String) -> Bool {
        switch mode {
        case "locked": lockScreenAudio ?? false
        case "idle": screenSaverAudio ?? false
        default: wallpaperAudio ?? false
        }
    }
}
