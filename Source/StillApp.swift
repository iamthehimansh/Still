import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers
import ImageIO

@main
struct StillApp: App {
    @NSApplicationDelegateAdaptor(StillDelegate.self) private var delegate
    @StateObject private var model = StillModel()

    var body: some Scene {
        Window("Still", id: "main") {
            MainView(model: model)
                .frame(width: 620)
                .fixedSize(horizontal: true, vertical: true)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
                .onDisappear { model.preview?.pause(); model.previewPlaying = false }
        }
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
        MenuBarExtra("Still", systemImage: "play.rectangle") {
            MenuContent(model: model)
        }
    }
}

final class StillDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuContent: View {
    @ObservedObject var model: StillModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.settings.videoName)
        Button(model.settings.playbackPaused == true ? "Play" : "Pause") { model.togglePlayback() }
            .disabled(model.busy || model.settings.videoPath == nil)
        Button(model.settings.globallyMuted == true ? "Unmute" : "Mute") { model.toggleMute() }
            .disabled(model.busy || model.settings.videoPath == nil)
        if model.lowPowerActive && model.settings.lowPowerBehavior != nil && model.settings.lowPowerBehavior != "continue" {
            Text(model.settings.lowPowerBehavior == "image" ? "Low Power Mode: showing image" : "Low Power Mode: paused")
        }
        Divider()
        Button("Open Still") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button("Quit Still") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

@MainActor
final class StillModel: ObservableObject {
    @Published var settings: StillSettings
    @Published var selectedURL: URL?
    @Published var preview: AVPlayer?
    @Published var previewPlaying = false
    @Published var busy = false
    @Published var message = "Choose where your video plays, then apply."
    @Published var isError = false
    @Published var details = ""
    @Published var lowPowerActive = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var powerObserver: NSObjectProtocol?
    private var previewLooper: AVPlayerLooper?
    private var applied: StillSettings?

    init() {
        let saved = StillPaths.load()
        settings = saved ?? StillSettings()
        if let path = saved?.videoPath, FileManager.default.fileExists(atPath: path) {
            selectedURL = URL(fileURLWithPath: path)
            applied = saved
        } else if let starter = Bundle.main.url(forResource: "Starter", withExtension: "mov") {
            selectedURL = starter
            settings.videoName = "Starter video"
        }
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lowPowerActive = ProcessInfo.processInfo.isLowPowerModeEnabled }
        }
        if let url = selectedURL {
            makePreview(url)
            Task { await inspect(url) }
        }
        if applied != nil {
            message = NativeWallpaperBridge.isSelectedEverywhere
                ? "Still is selected in macOS. Apply after making changes."
                : "Your choices are saved. Apply after making changes."
        }
    }

    func togglePlayback() { changeControls { $0.playbackPaused = $0.playbackPaused != true } }
    func toggleMute() { changeControls { $0.globallyMuted = $0.globallyMuted != true } }

    func changeControls(_ change: (inout StillSettings) -> Void) {
        guard !busy else { return }
        var next = applied ?? settings
        change(&next)
        do {
            if applied != nil { try NativeWallpaperBridge.updateControls(next); applied = next }
            settings.playbackPaused = next.playbackPaused
            settings.globallyMuted = next.globallyMuted
            settings.lowPowerBehavior = next.lowPowerBehavior
            settings.lowPowerImagePath = next.lowPowerImagePath
            message = applied == nil ? "Apply your video to start using these choices." : "Playback and power choices saved."
            isError = false
        } catch { report(error) }
    }

    func setLowPowerBehavior(_ value: String) {
        if value == "image" && settings.lowPowerImagePath == nil {
            DispatchQueue.main.async { self.chooseLowPowerImage() }; return
        }
        changeControls { $0.lowPowerBehavior = value }
    }

    func chooseLowPowerImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose the wallpaper to show in Low Power Mode."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
        do {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096
                  ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
            try FileManager.default.createDirectory(at: StillPaths.support, withIntermediateDirectories: true)
            let destination = StillPaths.support.appendingPathComponent("LowPower-" + UUID().uuidString + ".png")
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileReadCorruptFile) }
            try data.write(to: destination, options: .atomic)
            self.changeControls { $0.lowPowerImagePath = destination.path; $0.lowPowerBehavior = "image" }
        } catch { self.report(error) }
    }
    }

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a local video. Still keeps its own copy."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            busy = true
            defer { busy = false }
            do {
                let asset = AVURLAsset(url: url)
                let playable = try await asset.load(.isPlayable)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard playable, !tracks.isEmpty else { throw StillError.invalidVideo }
                selectedURL = url
                settings.videoName = url.deletingPathExtension().lastPathComponent
                makePreview(url)
                await inspect(url)
                message = "Video ready. Apply to save your choices."
                isError = false
            } catch { report(error) }
        }
    }

    func makePreview(_ url: URL) {
        preview?.pause()
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.preventsDisplaySleepDuringVideoPlayback = false
        previewLooper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        preview = queue
        previewPlaying = false
    }

    func togglePreview() {
        previewPlaying.toggle()
        if previewPlaying { preview?.play() } else { preview?.pause() }
    }

    func inspect(_ url: URL) async {
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            var size = ""
            if let track = tracks.first {
                let s = try await track.load(.naturalSize)
                size = "\(Int(abs(s.width))) × \(Int(abs(s.height)))  ·  "
            }
            guard selectedURL == url else { return }
            let length = duration.seconds.isFinite ? "\(Int(duration.seconds.rounded())) sec" : "Video"
            details = size + length + "  ·  " + (audio.isEmpty ? "No audio track" : "Audio available")
        } catch { details = "Preview unavailable" }
    }

    func reveal() {
        guard let url = selectedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func apply() {
        guard !busy, let source = selectedURL else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let asset = AVURLAsset(url: source)
                guard try await asset.load(.isPlayable), !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
                    throw StillError.invalidVideo
                }
                try FileManager.default.createDirectory(at: StillPaths.support, withIntermediateDirectories: true)
                var next = settings
                let managed: URL
                if source.deletingLastPathComponent().standardizedFileURL == StillPaths.support.standardizedFileURL {
                    managed = source
                } else {
                    managed = StillPaths.support.appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension)
                    try await Task.detached {
                        try FileManager.default.copyItem(at: source, to: managed)
                    }.value
                }
                next.videoPath = managed.path
                try await NativeWallpaperBridge.prepare(settings: next, videoURL: managed)
                settings = next
                applied = next
                selectedURL = managed
                message = NativeWallpaperBridge.applyMessage(for: next)
                isError = false
                preview?.pause()
                previewPlaying = false
            } catch { report(error) }
        }
    }

    private func installSaver() throws {
        guard let source = Bundle.main.url(forResource: "Still", withExtension: "saver") else { throw StillError.missingSaver }
        let fm = FileManager.default
        try fm.createDirectory(at: StillPaths.installedSaver.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: StillPaths.installedSaver.path) {
            let existing = Bundle(url: StillPaths.installedSaver)?.bundleIdentifier
            guard existing == "local.still.screensaver" else { throw StillError.existingSaver }
            let incoming = StillPaths.installedSaver.deletingLastPathComponent().appendingPathComponent("Still-\(UUID().uuidString).saver")
            try fm.copyItem(at: source, to: incoming)
            _ = try fm.replaceItemAt(StillPaths.installedSaver, withItemAt: incoming)
        } else { try fm.copyItem(at: source, to: StillPaths.installedSaver) }
    }

    func openSaverSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension")!)
    }

    func openWallpaperSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
    }


    func report(_ error: Error) { message = error.localizedDescription; isError = true }
}

enum StillError: LocalizedError {
    case invalidVideo, missingSaver, existingSaver
    var errorDescription: String? {
        switch self {
        case .invalidVideo: return "This file has no playable video. Choose an MP4 or MOV that plays in QuickTime."
        case .missingSaver: return "The screen saver is missing from this build. Rebuild Still with build.sh."
        case .existingSaver: return "A different screen saver named Still already exists. Rename it before installing this one."
        }
    }
}

struct MainView: View {
    @ObservedObject var model: StillModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Still").font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text("One video. Your whole Mac.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose video…", action: model.chooseVideo)
                    .keyboardShortcut("o", modifiers: .command)
            }
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    VideoPreview(player: model.preview)
                        .frame(height: 264)
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Button(action: model.togglePreview) {
                        Image(systemName: model.previewPlaying ? "pause.fill" : "play.fill")
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .tint(.black.opacity(0.65))
                    .padding(14)
                    .accessibilityLabel(model.previewPlaying ? "Pause preview" : "Play preview")
                    .disabled(model.selectedURL == nil)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.settings.videoName).fontWeight(.medium).lineLimit(1)
                        Text(model.details).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: model.reveal) { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help("Show video in Finder")
                        .accessibilityLabel("Show video in Finder")
                }
            }
            VStack(spacing: 0) {
                DestinationRow(title: "Wallpaper", subtitle: "Loops behind your desktop icons", symbol: "desktopcomputer",
                               enabled: $model.settings.wallpaperEnabled, audio: $model.settings.wallpaperAudio)
                Divider().padding(.leading, 43)
                DestinationRow(title: "Screen saver", subtitle: "Plays when your Mac is idle", symbol: "sparkles.rectangle.stack",
                               enabled: $model.settings.screenSaverEnabled, audio: $model.settings.screenSaverAudio)
                Divider().padding(.leading, 43)
                DestinationRow(title: "Lock screen", subtitle: NativeWallpaperBridge.subtitle, symbol: "lock.rectangle",
                               enabled: $model.settings.lockScreenEnabled, audio: $model.settings.lockScreenAudio)
            }
            Text("Switch off to keep a still frame. Sound follows the active screen.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Picker("Low Power Mode", selection: Binding(
                    get: { model.settings.lowPowerBehavior ?? "continue" },
                    set: { model.setLowPowerBehavior($0) }
                )) {
                    Text("Keep playing").tag("continue")
                    Text("Pause video").tag("pause")
                    Text("Show an image").tag("image")
                }
                if model.settings.lowPowerBehavior == "image" {
                    HStack {
                        if let path = model.settings.lowPowerImagePath, let image = NSImage(contentsOfFile: path) {
                            Image(nsImage: image).resizable().scaledToFill().frame(width: 52, height: 32).clipped().cornerRadius(4)
                        }
                        Button("Choose image…", action: model.chooseLowPowerImage)
                    }
                }
                Text("Restores your playback when Low Power Mode ends. Changes save automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(model.message)
                .font(.callout)
                .foregroundStyle(model.isError ? Color.red : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(model.message)
            HStack(spacing: 12) {
                Button("Wallpaper settings…", action: model.openWallpaperSettings).fixedSize()
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Apply video", action: model.apply)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.selectedURL == nil || model.busy)
            }
        }
        .padding(28)
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(model.busy)
    }
}

struct DestinationRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    @Binding var enabled: Bool
    @Binding var audio: Bool
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 21)).frame(width: 29)
                .foregroundStyle(enabled ? .primary : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Toggle(isOn: $audio) {
                Image(systemName: audio ? "speaker.wave.2" : "speaker.slash")
            }
            .toggleStyle(.button)
            .disabled(!enabled)
            .help("\(title) audio: \(audio ? "on" : "off")")
            .accessibilityLabel("\(title) audio")
            Toggle(title, isOn: $enabled).labelsHidden().toggleStyle(.switch)
                .accessibilityLabel("Enable \(title.lowercased())")
        }
        .padding(.vertical, 14)
    }
}

struct VideoPreview: NSViewRepresentable {
    let player: AVPlayer?
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspectFill
        view.player = player
        return view
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) { nsView.player = player }
}
