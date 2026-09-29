import AppKit
import AVFoundation
import CoreMedia

/// Integration test against the production renderer and an actual local movie.
/// Never enables sound while the shared transport is running; no windows are shown.
@main
struct MediaSyncTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor private static var assertions = 0
    @MainActor private static var maximumClockSkew = 0.0

    @MainActor private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !condition() { throw Failure(description: message) }
    }

    private static func delay(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let path = args.first(where: { !$0.hasPrefix("--") }) else {
                throw Failure(description: "Pass a local video path containing audio.")
            }
            try await run(videoURL: URL(fileURLWithPath: path).standardizedFileURL,
                          deepPauseMode: args.contains("--deep-resume"))
            print("PASS: \(assertions) real-media synchronization assertions.")
            print(String(format: "Maximum sampled renderer/shared-clock difference: %.6f ms.", maximumClockSkew * 1000))
            print("LIMIT: Muted, offscreen test; checks native renderer clocks and sample queues, not audible lip-sync, visible compositor output, or the live wallpaper extension host.")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor private static func run(videoURL: URL, deepPauseMode: Bool) async throws {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        try check(duration.isFinite && duration > 0, "The test movie must have a finite positive duration")
        try check(!audioTracks.isEmpty, "The integration movie must contain audio")
        print(String(format: "Real media: %@, %.3f seconds; all running playback remains muted.", videoURL.lastPathComponent, duration))
        fflush(stdout)

        let root = CALayer()
        root.bounds = CGRect(x: 0, y: 0, width: 640, height: 360)
        root.contentsScale = 1
        let renderer = try await VideoRenderer.create(rootLayer: root, videoURL: videoURL, audioAllowed: true)
        defer { renderer.stop() }
        let initial = await renderer.synchronizationSnapshot()
        try check(initial.audioCreated && initial.audioMuted, "Audio output must exist and be muted before playback")
        try check(initial.rate == 0, "The initial shared clock must be stopped")
        renderer.start()

        let startupDeadline = ProcessInfo.processInfo.systemUptime + 12
        var ready = await renderer.synchronizationSnapshot()
        while ready.time.seconds < 0.4 || ready.audioQueuedEnd.seconds <= 0 || ready.videoQueuedEnd.seconds <= 0 {
            try check(ProcessInfo.processInfo.systemUptime < startupDeadline, "Real audio/video failed to prime: \(renderer.syncDiagnostic())")
            try await delay(0.1)
            ready = await renderer.synchronizationSnapshot()
        }
        try check(ready.rate > 0.99 && ready.audioMuted, "Playback must advance using muted audio")
        try assertSharedClocks(ready, context: "initial playback")
        try check(ready.videoStatus != 2 && ready.audioStatus != 2, "A real-media renderer failed during startup")
        print(String(format: "PASS: Real video and audio samples queued at clock %.3f.", ready.time.seconds))
        fflush(stdout)

        renderer.pause()
        // Let the audio device's previously submitted buffers settle before the
        // flag-only unmute checks. The shared clock stays frozen throughout.
        try await delay(0.4)
        let paused = await renderer.synchronizationSnapshot()
        try await delay(0.35)
        let stillPaused = await renderer.synchronizationSnapshot()
        try check(paused.rate == 0 && stillPaused.rate == 0, "Pause must stop the shared transport")
        try check(abs(stillPaused.time.seconds - paused.time.seconds) < 0.015, "Shared clock advanced while paused")
        try assertSharedClocks(stillPaused, context: "paused")

        for index in 0..<6 {
            renderer.setAudioEnabled(true)
            let enabled = await renderer.synchronizationSnapshot()
            // Always restore mute before evaluating assertions or resuming transport.
            renderer.setAudioEnabled(false)
            let muted = await renderer.synchronizationSnapshot()
            try check(!enabled.audioMuted && muted.audioMuted, "Mute flag did not toggle on iteration \(index)")
            try check(enabled.rate == 0 && muted.rate == 0, "Changing mute restarted playback")
            try check(abs(enabled.time.seconds - paused.time.seconds) < 0.015, "Enabling audio changed the shared playhead")
            try check(abs(muted.time.seconds - paused.time.seconds) < 0.015, "Muting audio changed the shared playhead")
            try assertSharedClocks(muted, context: "mute toggle \(index)")
        }
        renderer.resume()
        try await delay(0.45)
        let resumed = await renderer.synchronizationSnapshot()
        try check(resumed.audioMuted, "Resume must preserve mute")
        try check(resumed.time.seconds > paused.time.seconds + 0.2, "Resume failed to continue from the paused position")
        try check(resumed.time.seconds < paused.time.seconds + 1.5, "Resume unexpectedly jumped the shared playhead")
        try assertSharedClocks(resumed, context: "resume")
        print("PASS: Pause/resume and six silent mute cycles preserve both playheads.")
        fflush(stdout)

        for index in 0..<4 {
            let beforeApply = await renderer.synchronizationSnapshot()
            renderer.switchVideo(to: videoURL)
            renderer.setAudioEnabled(false)
            let afterApply = await renderer.synchronizationSnapshot()
            try check(afterApply.time.seconds >= beforeApply.time.seconds - 0.015,
                      "Applying the same video restarted playback on iteration \(index)")
            try check(afterApply.time.seconds < beforeApply.time.seconds + 0.5,
                      "Applying the same video jumped playback on iteration \(index)")
            try check(afterApply.rate > 0.99 && afterApply.audioMuted,
                      "Applying the same video changed the playback or mute state")
            try assertSharedClocks(afterApply, context: "same-video Apply \(index)")
        }
        print("PASS: Four same-video Apply requests continue without resetting the shared clock.")
        fflush(stdout)

        // Observe two complete clip boundaries at normal speed. Each media feed
        // may buffer a different amount ahead; both must use the same clip period.
        let loopCount = deepPauseMode ? 1.0 : 2.0
        let targetTime = duration * loopCount + 0.6
        let loopDeadline = ProcessInfo.processInfo.systemUptime + targetTime + 15
        var previousTime = resumed.time.seconds
        var nextProgress = 10.0
        var last = resumed
        while last.time.seconds < targetTime {
            try check(ProcessInfo.processInfo.systemUptime < loopDeadline, "Shared playback stalled before completing two loops")
            try await delay(0.35)
            last = await renderer.synchronizationSnapshot()
            try check(last.audioMuted, "The integration test unexpectedly enabled sound")
            try check(last.rate > 0.99, "Playback rate changed during loop observation")
            try check(last.time.seconds >= previousTime - 0.015, "Clock reset or moved backward at a loop boundary")
            try check(last.videoStatus != 2 && last.audioStatus != 2, "A sample renderer failed while looping")
            try check(last.videoQueuedEnd.seconds + 0.75 >= last.time.seconds, "Video feed fell behind the shared clock")
            try check(last.audioQueuedEnd.seconds + 0.75 >= last.time.seconds, "Audio feed fell behind the shared clock")
            try assertSharedClocks(last, context: "loop playback")
            try assertWholeLoops(last.videoLoopOffset.seconds, duration: duration, kind: "video")
            try assertWholeLoops(last.audioLoopOffset.seconds, duration: duration, kind: "audio")
            previousTime = last.time.seconds
            if previousTime >= nextProgress {
                print(String(format: "Progress: shared clock %.2f s, video loop offset %.3f, audio loop offset %.3f.", previousTime, last.videoLoopOffset.seconds, last.audioLoopOffset.seconds))
                fflush(stdout)
                nextProgress += 10
            }
        }
        try check(last.videoLoopOffset.seconds >= duration * loopCount - 0.01, "Video did not enqueue the next loop iteration")
        try check(last.audioLoopOffset.seconds >= duration * loopCount - 0.01, "Audio did not enqueue the next loop iteration")
        print(String(format: "PASS: %.0f complete %.3f-second loop boundaries crossed without resetting or separating the media clocks.", loopCount, duration))
        fflush(stdout)

        if deepPauseMode {
            renderer.pause()
            try await delay(0.15)
            let beforeDeepPause = await renderer.synchronizationSnapshot()
            try check(beforeDeepPause.time.seconds > duration, "Deep-resume regression must start beyond the first loop")
            print("Deep pause: waiting 31.5 seconds for the production reader-release timer.")
            fflush(stdout)
            try await delay(31.5)
            let afterDeepPause = await renderer.synchronizationSnapshot()
            try check(afterDeepPause.rate == 0 && afterDeepPause.audioMuted, "Deep pause restarted or unmuted playback")
            try check(abs(afterDeepPause.time.seconds - beforeDeepPause.time.seconds) < 0.015,
                      "Deep pause moved the shared playhead")
            renderer.resume()
            try await delay(0.85)
            let afterWake = await renderer.synchronizationSnapshot()
            try check(afterWake.time.seconds > beforeDeepPause.time.seconds + 0.3,
                      "Deep resume failed to advance the previous absolute playhead")
            try check(afterWake.time.seconds < beforeDeepPause.time.seconds + 2,
                      "Deep resume jumped the shared playhead")
            try check(afterWake.audioMuted && afterWake.rate > 0.99,
                      "Deep resume must play while preserving mute")
            try check(afterWake.videoQueuedEnd.seconds >= afterWake.time.seconds && afterWake.audioQueuedEnd.seconds >= afterWake.time.seconds,
                      "Deep resume failed to refill audio and video at the continued position")
            try check(afterWake.videoStatus != 2 && afterWake.audioStatus != 2,
                      "A native renderer failed after deep resume")
            try assertSharedClocks(afterWake, context: "deep resume after a completed loop")
            print(String(format: "PASS: After 31.5s pause, clock continued from %.3f to %.3f with both feeds active.", beforeDeepPause.time.seconds, afterWake.time.seconds))
            fflush(stdout)
        }
        renderer.stop()

        let previewRoot = CALayer()
        previewRoot.bounds = root.bounds
        let preview = try await VideoRenderer.create(rootLayer: previewRoot, videoURL: videoURL, audioAllowed: false)
        defer { preview.stop() }
        preview.setAudioEnabled(true)
        preview.start()
        let previewDeadline = ProcessInfo.processInfo.systemUptime + 8
        var previewState = await preview.synchronizationSnapshot()
        while previewState.time.seconds < 0.3 {
            try check(ProcessInfo.processInfo.systemUptime < previewDeadline, "Video-only preview did not start")
            try await delay(0.1)
            previewState = await preview.synchronizationSnapshot()
        }
        try check(!previewState.audioCreated && previewState.audioTime == nil && previewState.audioStatus == nil,
                  "Preview created an audio renderer despite audioAllowed=false")
        try check(previewState.videoQueuedEnd.seconds > 0 && previewState.videoStatus != 2,
                  "Video-only preview failed to feed real video")
        preview.stop()
        let stoppedPreview = await preview.synchronizationSnapshot()
        try check(stoppedPreview.rate == 0, "Stopping a video-only preview did not freeze its clock")
        print("PASS: Preview decodes video without constructing an audio output, even after an enable request.")
    }

    @MainActor private static func assertSharedClocks(_ snapshot: VideoRenderer.SyncSnapshot, context: String) throws {
        try check(snapshot.time.isNumeric && snapshot.videoTime.isNumeric, "Invalid media clock during \(context)")
        let videoSkew = abs(snapshot.videoTime.seconds - snapshot.time.seconds)
        try check(videoSkew < 0.02, "Video clock separated from shared clock during \(context)")
        guard let audioTime = snapshot.audioTime else {
            throw Failure(description: "Audio clock missing during \(context)")
        }
        let audioSkew = abs(audioTime.seconds - snapshot.time.seconds)
        maximumClockSkew = max(maximumClockSkew, max(videoSkew, audioSkew))
        try check(audioTime.isNumeric && audioSkew < 0.02,
                  "Audio clock separated from shared clock during \(context)")
    }

    @MainActor private static func assertWholeLoops(_ offset: Double, duration: Double, kind: String) throws {
        let loops = offset / duration
        try check(offset.isFinite && abs(loops - loops.rounded()) < 0.0001,
                  "\(kind) loop offset \(offset) diverged from the common clip duration \(duration)")
    }
}
