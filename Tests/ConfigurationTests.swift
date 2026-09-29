import Foundation

@main
@MainActor
struct ConfigurationTests {
    private static var assertions = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() throws {
        let nativeOverrides: [Bool?] = [nil, false, true]
        var combinations = 0
        for bits in 0..<64 {
            let choices = (0..<6).map { bits & (1 << $0) != 0 }
            for desktop in nativeOverrides {
                for saver in nativeOverrides {
                    let config = StillConfiguration(
                        wallpaperEnabled: choices[0], wallpaperAudio: choices[1],
                        screenSaverEnabled: choices[2], screenSaverAudio: choices[3],
                        lockScreenEnabled: choices[4], lockScreenAudio: choices[5],
                        nativeDesktopEnabled: desktop, nativeScreenSaverEnabled: saver
                    )
                    let expected: [(mode: String, enabled: Bool, audio: Bool)] = [
                        ("active", choices[0] && desktop != false, choices[1]),
                        ("idle", choices[2] && saver != false, choices[3]),
                        ("locked", choices[4], choices[5])
                    ]
                    for row in expected {
                        let context = "bits=\(bits), desktop=\(String(describing: desktop)), saver=\(String(describing: saver)), mode=\(row.mode)"
                        check(config.enabled(in: row.mode) == row.enabled, "Enable mismatch: \(context)")
                        check(config.audio(in: row.mode) == row.audio, "Audio choice mismatch: \(context)")
                        let shouldPlayAudio = config.enabled(in: row.mode) && config.audio(in: row.mode)
                        check(shouldPlayAudio == (row.enabled && row.audio), "Effective audio mismatch: \(context)")
                    }
                    combinations += 1
                }
            }
        }

        // Switching off a destination must leave the other two choices untouched.
        let fullyOn = StillConfiguration(
            wallpaperEnabled: true, wallpaperAudio: true,
            screenSaverEnabled: true, screenSaverAudio: true,
            lockScreenEnabled: true, lockScreenAudio: true,
            nativeDesktopEnabled: true, nativeScreenSaverEnabled: true
        )
        let destinations: [(String, WritableKeyPath<StillConfiguration, Bool?>)] = [
            ("active", \.wallpaperEnabled), ("idle", \.screenSaverEnabled), ("locked", \.lockScreenEnabled)
        ]
        for (disabledMode, keyPath) in destinations {
            var config = fullyOn
            config[keyPath: keyPath] = false
            for (mode, _) in destinations {
                check(config.enabled(in: mode) == (mode != disabledMode), "Disabling \(disabledMode) affected \(mode)")
                check(config.audio(in: mode), "Disabling \(disabledMode) erased the saved audio choice for \(mode)")
            }
        }

        let missing = try JSONDecoder().decode(StillConfiguration.self, from: Data("{}".utf8))
        for (mode, _) in destinations {
            check(missing.enabled(in: mode), "Missing enabled flag must default on for \(mode)")
            check(!missing.audio(in: mode), "Missing audio flag must default muted for \(mode)")
        }
        check(missing.videoURL == nil, "Missing video must not resolve to a file")

        var original = fullyOn
        original.videoPath = "/Users/example/Library/Application Support/Still/媒体 clip.mov"
        original.videoName = "A video · 夜"
        original.nativeDesktopEnabled = false
        original.nativeScreenSaverEnabled = false
        original.screenSaverAudio = false
        original.lockScreenEnabled = false
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StillConfiguration.self, from: encoded)
        check(decoded.videoPath == original.videoPath, "Video path must survive Codable, including spaces and Unicode")
        check(decoded.videoName == original.videoName, "Video name must survive Codable")
        check(decoded.videoURL?.path == original.videoPath, "Video URL must preserve the decoded local path")
        check(decoded.videoURL?.isFileURL == true, "Video URL must remain a local file URL")
        for (mode, _) in destinations {
            check(decoded.enabled(in: mode) == original.enabled(in: mode), "Enabled choice lost during Codable for \(mode)")
            check(decoded.audio(in: mode) == original.audio(in: mode), "Audio choice lost during Codable for \(mode)")
        }
        check(decoded.nativeDesktopEnabled == false, "Explicit desktop override false was lost")
        check(decoded.nativeScreenSaverEnabled == false, "Explicit saver override false was lost")

        let legacy = try JSONDecoder().decode(StillConfiguration.self, from: Data("{\"videoPath\":\"/tmp/local.mov\",\"wallpaperEnabled\":false,\"lockScreenAudio\":true}".utf8))
        check(!legacy.enabled(in: "active"), "Legacy explicit false must remain false")
        check(legacy.enabled(in: "idle"), "Absent native override must leave saver enabled")
        check(legacy.audio(in: "locked") && !legacy.audio(in: "idle"), "Legacy audio must not bleed between modes")
        check(legacy.enabled(in: "unknown-future-mode") == legacy.enabled(in: "active"), "Unknown mode must use desktop enable policy")
        check(legacy.audio(in: "unknown-future-mode") == legacy.audio(in: "active"), "Unknown mode must use desktop audio policy")

        do {
            _ = try JSONDecoder().decode(StillConfiguration.self, from: Data("{\"wallpaperEnabled\":\"false\"}".utf8))
            check(false, "Malformed flag type must be rejected")
        } catch {
            check(true, "Malformed flag type rejected")
        }
        print("PASS: \(assertions) assertions; all 64 destination/audio combinations × 9 native-override combinations × 3 modes, isolation, defaults, and Codable.")
        print("No settings files or system preferences were read or changed.")
    }
}
