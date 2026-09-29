import Foundation

final class RecordingSink: StillAudioSink {
    let name: String
    var changes: [Bool] = []
    var onChange: ((Bool) -> Void)?
    init(_ name: String) { self.name = name }
    func setAudioEnabled(_ enabled: Bool) {
        changes.append(enabled)
        onChange?(enabled)
    }
}

@main
struct AudioRoutingTests {
    @MainActor static func main() {
        let route = AudioRouting()
        let desktop = RecordingSink("desktop"), locked = RecordingSink("lock")
        var events: [String] = []
        desktop.onChange = { events.append("desktop:\($0)") }
        locked.onChange = { events.append("lock:\($0)") }
        route.route(to: nil)
        route.route(to: desktop)
        route.route(to: desktop) // Apply/settings updates must not restart audio.
        assert(desktop.changes == [true])
        route.route(to: locked)
        assert(events == ["desktop:true", "desktop:false", "lock:true"], "Mute the old surface before enabling another.")
        route.route(to: nil) // Sound disabled, display sleep, invalidation.
        assert(locked.changes == [true, false])
        route.route(to: locked) // Unmute uses the renderer's existing shared clock.
        assert(locked.changes == [true, false, true])
        route.route(to: desktop)
        assert(locked.changes.last == false && desktop.changes.last == true)
        route.route(to: nil)
        assert(desktop.changes.last == false)
        print("PASS: one audible surface, mute-before-unmute handoff, idempotent Apply, disable/resume, and desktop/lock transitions")
    }
}
