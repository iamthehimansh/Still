import AppKit
import AVFoundation
import QuartzCore

/// Owns video windows behind the desktop icons without changing wallpaper preferences.
@MainActor
final class DesktopPlayer {
    /// Whether a wallpaper has been started. Playback can be temporarily suspended.
    var isRunning: Bool { videoURL != nil }

    private var videoURL: URL?
    private var muted = true
    private var surfaces: [DesktopSurface] = []
    private var pauseReasons: Set<PauseReason> = []
    private let observers = DesktopObserverBag()

    private enum PauseReason: Hashable {
        case computerAsleep, displaysAsleep, sessionInactive, screenSaver, locked
    }

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.suspend(.computerAsleep) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.resume(.computerAsleep) }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.suspend(.displaysAsleep) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.resume(.displaysAsleep) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.suspend(.sessionInactive) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.resume(.sessionInactive) }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.rebuildSurfaces() }

        // These system broadcasts are best effort: Apple does not provide a public
        // NSWorkspace screen-saver/lock transition API. Sleep/session handling above
        // remains independent, so one event cannot override another pause reason.
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screensaver.didstart")) { $0.suspend(.screenSaver) }
        observe(distributed, Notification.Name("com.apple.screensaver.didstop")) { $0.resume(.screenSaver) }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.suspend(.locked) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) {
            $0.pauseReasons.remove(.screenSaver)
            $0.resume(.locked)
        }
    }

    func start(url: URL, muted: Bool) {
        self.muted = muted
        guard videoURL != url || surfaces.isEmpty else {
            updatePlayback()
            return
        }
        videoURL = url
        rebuildSurfaces()
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        updatePlayback()
    }

    func stop() {
        videoURL = nil
        tearDownSurfaces()
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        action: @escaping @MainActor (DesktopPlayer) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                action(self)
            }
        }
        observers.entries.append((center, token))
    }

    private func suspend(_ reason: PauseReason) {
        pauseReasons.insert(reason)
        updatePlayback()
    }

    private func resume(_ reason: PauseReason) {
        pauseReasons.remove(reason)
        updatePlayback()
    }

    private func rebuildSurfaces() {
        guard let videoURL else { return }
        tearDownSurfaces()
        // Each display needs its own player. Only the first one may emit audio.
        for screen in NSScreen.screens {
            surfaces.append(DesktopSurface(screen: screen, url: videoURL))
        }
        updatePlayback()
    }

    private func updatePlayback() {
        let shouldPlay = videoURL != nil && pauseReasons.isEmpty
        for (index, surface) in surfaces.enumerated() {
            surface.player.isMuted = muted || index != 0 || !shouldPlay
            if shouldPlay {
                surface.window.orderBack(nil)
                surface.player.play()
            } else {
                surface.player.pause()
            }
        }
    }

    private func tearDownSurfaces() {
        for surface in surfaces { surface.stop() }
        surfaces.removeAll()
    }
}

/// Notification tokens release independently of the main-actor owner's lifetime.
private final class DesktopObserverBag {
    var entries: [(NotificationCenter, NSObjectProtocol)] = []

    deinit {
        for (center, token) in entries { center.removeObserver(token) }
    }
}

@MainActor
private final class DesktopSurface {
    let window: DesktopVideoWindow
    let player: AVQueuePlayer
    private let looper: AVPlayerLooper
    private let videoView: DesktopVideoView

    init(screen: NSScreen, url: URL) {
        player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        videoView = DesktopVideoView(frame: NSRect(origin: .zero, size: screen.frame.size))
        videoView.playerLayer.player = player

        window = DesktopVideoWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.setFrame(screen.frame, display: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = false
        window.hidesOnDeactivate = false
        window.canHide = false
        window.isExcludedFromWindowsMenu = true
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.animationBehavior = .none
        window.contentView = videoView
    }

    func stop() {
        player.isMuted = true
        player.pause()
        looper.disableLooping()
        videoView.playerLayer.player = nil
        player.removeAllItems()
        window.orderOut(nil)
        window.close()
    }
}

@MainActor
private final class DesktopVideoWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class DesktopVideoView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = bounds
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
