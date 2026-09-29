import Foundation

struct StillSettings: Codable, Equatable {
    var videoPath: String? = nil
    var videoName = "No video selected"
    var wallpaperEnabled = true
    var wallpaperAudio = false
    var screenSaverEnabled = true
    var screenSaverAudio = false
    var lockScreenEnabled = true
    var lockScreenAudio = false
    // Optional additions keep settings saved by earlier builds readable.
    var playbackPaused: Bool? = nil
    var globallyMuted: Bool? = nil
    var lowPowerBehavior: String? = nil
    var lowPowerImagePath: String? = nil
}

enum StillPaths {
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Still", isDirectory: true)
    static let settings = support.appendingPathComponent("settings.json")
    static let installedSaver = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Screen Savers/Still.saver", isDirectory: true)

    static func load() -> StillSettings? {
        guard let data = try? Data(contentsOf: settings) else { return nil }
        return try? JSONDecoder().decode(StillSettings.self, from: data)
    }

    static func save(_ settings: StillSettings) throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: self.settings, options: .atomic)
    }
}
