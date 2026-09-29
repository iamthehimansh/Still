import AppKit
import AVFoundation

@main
struct PowerImageTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard CommandLine.arguments.count == 3 else { fatalError("Pass video and image paths") }
        let root = CALayer()
        root.bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let renderer = try await VideoRenderer.create(rootLayer: root, videoURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        defer { renderer.stop() }
        renderer.start()
        try await Task.sleep(for: .seconds(2))
        let playing = await renderer.synchronizationSnapshot()
        precondition(playing.time.seconds > 0 && playing.rate == 1)
        renderer.applyPolicy(.paused)
        let paused = await renderer.synchronizationSnapshot()
        let baseCount = root.sublayers!.count
        let imageURL = URL(fileURLWithPath: CommandLine.arguments[2])
        renderer.setPowerImage(imageURL)
        try await Task.sleep(for: .seconds(1))
        precondition(root.sublayers!.count == baseCount + 1)
        let imageLayer = root.sublayers!.last as! AVSampleBufferDisplayLayer
        precondition(imageLayer.sampleBufferRenderer.status == .rendering)
        precondition(imageLayer.frame == root.bounds)
        renderer.setPowerImage(imageURL)
        precondition(root.sublayers!.count == baseCount + 1, "Same image must not create duplicate layers")
        let duringImage = await renderer.synchronizationSnapshot()
        precondition(duringImage.rate == 0 && abs(duringImage.time.seconds - paused.time.seconds) < 0.01)
        renderer.setPowerImage(nil)
        precondition(root.sublayers!.count == baseCount)
        renderer.applyPolicy(.full)
        try await Task.sleep(for: .seconds(1))
        let resumed = await renderer.synchronizationSnapshot()
        precondition(resumed.rate == 1 && resumed.time.seconds > paused.time.seconds + 0.5)
        renderer.setPowerImage(URL(fileURLWithPath: "/missing-still-test-image.png"))
        precondition(root.sublayers!.count == baseCount, "Bad image must fall back to video frame")
        print("PASS: real-media pause, selected image decoding and sizing, image deduplication, frozen shared clock, removal, resume and missing-image fallback.")
        print("LIMIT: Offscreen renderer test; remote compositor appearance still needs live visual verification.")
    }
}
