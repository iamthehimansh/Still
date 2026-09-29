import Foundation
import Darwin

enum NativeWallpaperBridge {
    static let identifier = "local.still.wallpaper.extension"
    static let subtitle = "Plays behind the sign-in prompt"
    static let container = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/\(identifier)/Data/Documents", isDirectory: true)

    static var isBundled: Bool {
        FileManager.default.fileExists(atPath: extensionURL.path)
    }

    static var extensionURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Extensions/StillWallpaper.appex")
    }

    static func prepare(settings: StillSettings, videoURL: URL) async throws {
        guard isBundled else { throw BridgeError.extensionMissing }
        let targetContainer = container
        let bundledExtension = extensionURL
        let localSettingsURL = StillPaths.settings
        let destination = targetContainer.appendingPathComponent(videoURL.lastPathComponent)
        var mirrored = try mirrorControls(settings)
        mirrored.videoName = "Still · " + settings.videoName
        mirrored.videoPath = destination.path
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let localData = try encoder.encode(settings)
        let mirroredData = try encoder.encode(mirrored)

        // Importing a large movie and registering its extension must not block the UI.
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try fm.createDirectory(at: targetContainer, withIntermediateDirectories: true)
            var importedMirror = false
            do {
                if !fm.fileExists(atPath: destination.path) {
                    let temp = targetContainer.appendingPathComponent("import-\(UUID().uuidString).tmp")
                    do {
                        try fm.copyItem(at: videoURL, to: temp)
                        try fm.moveItem(at: temp, to: destination)
                        importedMirror = true
                    } catch {
                        try? fm.removeItem(at: temp)
                        throw error
                    }
                }
                try registerExtension(at: bundledExtension)
                try commitSettings(
                    localData: localData, localURL: localSettingsURL,
                    mirroredData: mirroredData,
                    mirroredURL: targetContainer.appendingPathComponent("settings.json")
                )
            } catch {
                if importedMirror { try? fm.removeItem(at: destination) }
                throw error
            }
            for name in ["local.still.wallpaper.prefsChanged", "local.still.wallpaper.libraryChanged"] {
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName(name as CFString), nil, nil, true)
            }
        }.value
    }

    private static func mirrorControls(_ settings: StillSettings) throws -> StillSettings {
        var mirrored = settings
        if let path = settings.lowPowerImagePath {
            let source = URL(fileURLWithPath: path)
            let destination = container.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: source, to: destination)
            }
            mirrored.lowPowerImagePath = destination.path
        }
        return mirrored
    }

    /// Transport changes never reimport the movie or reset its shared media clock.
    static func updateControls(_ settings: StillSettings) throws {
        var mirrored = try mirrorControls(settings)
        if let path = settings.videoPath {
            mirrored.videoPath = container.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent).path
        }
        mirrored.videoName = "Still · " + settings.videoName
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try commitSettings(localData: encoder.encode(settings), localURL: StillPaths.settings,
                           mirroredData: encoder.encode(mirrored), mirroredURL: container.appendingPathComponent("settings.json"))
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("local.still.wallpaper.prefsChanged" as CFString), nil, nil, true)
    }

    private static func registerExtension(at url: URL) throws {
        let register = Process()
        register.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        register.arguments = ["-a", url.path]
        // A pipe which is never drained can deadlock a verbose child process.
        register.standardError = FileHandle.nullDevice
        register.standardOutput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        register.terminationHandler = { _ in finished.signal() }
        try register.run()
        guard finished.wait(timeout: .now() + 15) == .success else {
            if register.isRunning { register.terminate() }
            if finished.wait(timeout: .now() + 1) == .timedOut, register.isRunning {
                kill(register.processIdentifier, SIGKILL)
            }
            throw BridgeError.registrationTimedOut
        }
        guard register.terminationStatus == 0 else { throw BridgeError.registrationFailed }
    }

    private static func commitSettings(
        localData: Data, localURL: URL, mirroredData: Data, mirroredURL: URL
    ) throws {
        let fm = FileManager.default
        let previousLocal = fm.fileExists(atPath: localURL.path) ? try Data(contentsOf: localURL) : nil
        try fm.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Both writes are atomic. Publish the extension's settings only after the
        // app's settings are durable; restore the app copy if publishing fails.
        try localData.write(to: localURL, options: .atomic)
        do {
            try mirroredData.write(to: mirroredURL, options: .atomic)
        } catch {
            let commitError = error
            do {
                if let previousLocal {
                    try previousLocal.write(to: localURL, options: .atomic)
                } else {
                    try fm.removeItem(at: localURL)
                }
            } catch {
                throw BridgeError.settingsRecoveryFailed
            }
            throw commitError
        }
    }

    static func applyMessage(for settings: StillSettings) -> String {
        if isSelectedEverywhere {
            return "Applied. Still is selected for wallpaper and screen saver, with your lock-screen and sound choices saved."
        }
        return "Saved. In Wallpaper settings, choose Still. For the screen saver, click Screen Saver… and select Automatic."
    }

    static var isSelectedEverywhere: Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let spaces = root["Spaces"] as? [String: Any], spaces.isEmpty,
              let displays = root["Displays"] as? [String: Any], displays.isEmpty,
              let all = root["AllSpacesAndDisplays"] as? [String: Any],
              all["Type"] as? String == "linked",
              let linked = all["Linked"] as? [String: Any],
              let content = linked["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]], !choices.isEmpty else { return false }
        return choices.allSatisfy { $0["Provider"] as? String == identifier }
    }

    enum BridgeError: LocalizedError {
        case extensionMissing, registrationFailed, registrationTimedOut, settingsRecoveryFailed
        var errorDescription: String? {
            switch self {
            case .extensionMissing: return "The wallpaper extension is missing from this build."
            case .registrationFailed: return "macOS could not register Still. Keep Still.app in Applications, reopen it, and try again."
            case .registrationTimedOut: return "macOS took too long to register Still. Your saved choices were not changed. Try applying again."
            case .settingsRecoveryFailed: return "Still could not finish saving both copies of your choices. Apply again to bring them back into sync."
            }
        }
    }
}
