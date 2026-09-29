import AppKit
import AVFoundation
import Darwin
import ScreenSaver

/// The native screen saver uses the same local video as the Still app.
@objc(StillScreenSaverView)
final class StillScreenSaverView: ScreenSaverView {
    private struct Settings: Decodable {
        let videoPath: String?
        let screenSaverEnabled: Bool
        let screenSaverAudio: Bool

        private enum CodingKeys: String, CodingKey {
            case videoPath, screenSaverEnabled, screenSaverAudio
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            videoPath = try values.decodeIfPresent(String.self, forKey: .videoPath)
            screenSaverEnabled = try values.decodeIfPresent(Bool.self, forKey: .screenSaverEnabled) ?? false
            screenSaverAudio = try values.decodeIfPresent(Bool.self, forKey: .screenSaverAudio) ?? false
        }
    }

    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var settings: Settings?
    private var settingsURL: URL?
    private var lastSettingsData: Data?
    private var stoppedByHost = false

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        prepareView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        prepareView()
    }

    private func prepareView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
        // AVFoundation supplies video frames. The saver timer only checks settings.
        animationTimeInterval = 1

        // Some recent hosts fail to send stopAnimation. Release video resources when
        // the host broadcasts that it is stopping, without terminating its process.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(hostWillStop),
            name: NSNotification.Name("com.apple.screensaver.willstop"), object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(hostWillStop),
            name: NSNotification.Name("com.apple.screensaver.didstop"), object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(hostWillStop),
            name: NSWorkspace.willSleepNotification, object: nil
        )
    }

    deinit {
        player?.pause()
        looper?.disableLooping()
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
        updateAudio()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            tearDownPlayback()
        } else if isAnimating && !stoppedByHost {
            reloadSettings(force: true)
        }
    }

    override func startAnimation() {
        super.startAnimation()
        stoppedByHost = false
        reloadSettings(force: true)
    }

    override func stopAnimation() {
        stoppedByHost = true
        tearDownPlayback()
        super.stopAnimation()
    }

    override func animateOneFrame() {
        guard !stoppedByHost else { return }
        reloadSettings(force: false)
        updateAudio()
    }

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
    }

    @objc private func hostWillStop(_ notification: Notification) {
        stopAnimation()
    }

    private func settingsLocations() -> [URL] {
        var homes: [URL] = []
        // ScreenSaver's sandbox changes NSHomeDirectory. The passwd entry gives
        // the real home containing the app's managed, non-TCC media directory.
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            homes.append(URL(fileURLWithPath: String(cString: home), isDirectory: true))
        }
        homes.append(FileManager.default.homeDirectoryForCurrentUser)
        var locations = homes.map {
            $0.appendingPathComponent("Library/Application Support/Still/settings.json")
        }
        if let bundledSettings = Bundle(for: StillScreenSaverView.self).url(
            forResource: "settings", withExtension: "json"
        ) {
            locations.append(bundledSettings)
        }
        return locations
    }

    private func reloadSettings(force: Bool) {
        var found: (Settings, URL, Data)?
        for url in settingsLocations() {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(Settings.self, from: data) else { continue }
            found = (decoded, url, data)
            break
        }

        guard let (newSettings, newURL, newData) = found else {
            if force || settings != nil {
                settings = nil
                settingsURL = nil
                lastSettingsData = nil
                tearDownPlayback()
            }
            return
        }

        guard force || newData != lastSettingsData || newURL != settingsURL else { return }
        let sameVideo = newSettings.videoPath == settings?.videoPath && newURL == settingsURL
        settings = newSettings
        settingsURL = newURL
        lastSettingsData = newData

        guard newSettings.screenSaverEnabled,
              let path = newSettings.videoPath, !path.isEmpty else {
            tearDownPlayback()
            return
        }

        if !force && sameVideo && player != nil {
            updateAudio()
            return
        }

        tearDownPlayback()
        let videoURL = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : newURL.deletingLastPathComponent().appendingPathComponent(path)
        guard FileManager.default.isReadableFile(atPath: videoURL.path) else { return }

        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.preventsDisplaySleepDuringVideoPlayback = false
        queue.automaticallyWaitsToMinimizeStalling = true
        let item = AVPlayerItem(url: videoURL)
        player = queue
        looper = AVPlayerLooper(player: queue, templateItem: item)
        playerLayer.player = queue
        updateAudio()
        queue.play()
    }

    private func updateAudio() {
        // Always silence settings previews, including hosts that give an incorrect
        // preview flag for their small embedded thumbnail.
        let isSmallPreview = bounds.width < 700 && bounds.height < 500
        let displayID = (window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let primaryDisplay = displayID == CGMainDisplayID()
        player?.isMuted = isPreview || isSmallPreview || !primaryDisplay || settings?.screenSaverAudio != true
    }

    private func tearDownPlayback() {
        player?.pause()
        playerLayer.player = nil
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()
        player = nil
    }
}
