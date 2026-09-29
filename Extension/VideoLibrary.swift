import AVFoundation
import Foundation
import ImageIO
import os

struct VideoEntry: Codable {
    let id: String
    var name: String
    var filename: String
    var duration: Double
    var fps: Double
    var resolution: CGSize
    var dateAdded: Date
    var variants: [VideoVariant]?
}

/// One imported movie, shared from Still into this extension's own container.
final class VideoLibrary: Sendable {
    static let shared = VideoLibrary()
    static let choiceID = "44F94E52-0D9E-44C1-9939-B9EE5968E993"
    private let lock = OSAllocatedUnfairLock(initialState: [VideoEntry]())
    private var docs: URL { StillConfiguration.documents }
    var entries: [VideoEntry] { lock.withLock { $0 } }
    func entry(for id: String) -> VideoEntry? { entries.first { $0.id == id } }
    func videoURL(for entry: VideoEntry) -> URL { docs.appendingPathComponent(entry.filename) }
    func videoURL(for id: String) -> URL? { entry(for: id).map(videoURL(for:)) }
    func bestVariantURL(for id: String, policy: PlaybackPolicy) -> URL? { videoURL(for: id) }
    func removeVideo(id: String) { /* The app owns its imported movie. */ }

    func scan() {
        let config = StillConfiguration.load()
        guard let source = config.videoURL,
              source.deletingLastPathComponent().standardizedFileURL == docs.standardizedFileURL,
              FileManager.default.fileExists(atPath: source.path) else {
            lock.withLock { $0 = [] }
            return
        }
        let entry = VideoEntry(id: Self.choiceID, name: config.videoName ?? "Still", filename: source.lastPathComponent, duration: 0, fps: 0, resolution: .zero, dateAdded: Date())
        lock.withLock { $0 = [entry] }
    }

    func generateThumbnail(for entry: VideoEntry) async -> URL? {
        let videoURL = videoURL(for: entry)
        let thumbnailURL = docs.appendingPathComponent("thumbnail.jpg")
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        guard let frame = try? await generator.image(at: .zero).image,
              let destination = CGImageDestinationCreateWithURL(thumbnailURL as CFURL, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, frame, nil)
        return CGImageDestinationFinalize(destination) ? thumbnailURL : nil
    }
}
