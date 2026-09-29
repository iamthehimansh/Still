import Foundation
import os
import QuartzCore

/// One persistent per-display rendering slot. Reused across acquires (Apple's
/// model): the `caContext`/`contextId`/`rootLayer` live for the display's lifetime
/// and only the `renderer`/`videoID` swap when the wallpaper changes — so the Agent
/// never drops the context on switch (no gray gap) and contexts never accumulate.
struct ActiveWallpaper: @unchecked Sendable {
    let caContext: AnyObject // CAContext (private class, hold as AnyObject)
    let contextId: UInt32
    let rootLayer: CALayer
    var renderer: VideoRenderer?
    let displayID: UInt32?
    var videoID: String?
    /// Whether this context serves a preview surface (Settings picker / lock-screen
    /// prewarm) or the live desktop. Set from the acquire's `isPreview` flag and
    /// used by `hasLiveRenderer(onDisplay:isPreview:)` so a preview-first / desktop-
    /// second boot doesn't misclassify the desktop acquire as a switch (which would
    /// defer its reply and leave the desktop CALayerHost black).
    let isPreview: Bool
    /// The destination geometry (in points) and backing scale this surface's layer
    /// tree was last laid out for. Tracked so a re-`acquire` for the SAME surface can
    /// detect a resolution/scale change (disconnect→reconnect a display, or a plain
    /// mode change) and re-frame the root + renderer layers — the REUSE path otherwise
    /// keeps the original size and the wallpaper renders into a sub-region of the panel.
    var destSize: CGSize
    var scaleFactor: CGFloat
    /// True while a `VideoRenderer.create` is in flight for this slot. Prevents a
    /// second (e.g. preview) acquire from spinning up a *duplicate* renderer on the
    /// same rootLayer while the first acquire's async create hasn't populated
    /// `renderer` yet. Cleared when the renderer is set or the create fails.
    var rendererPending: Bool = false
}

/// Identifies one hosted wallpaper SURFACE — a distinct `CAContext`/layer tree that
/// WallpaperAgent hosts in one `CALayerHost`. There is one per **WallpaperID UUID**,
/// i.e. one per Space, per lock-screen surface, and per Settings preview.
///
/// This used to be keyed by `displayID` alone (one shared context per display), on the
/// assumption that every consumer of a display hosts the same surface. That's wrong:
/// macOS keeps multiple Spaces' wallpaper surfaces (plus the lock screen) *live at once*,
/// each a separate WallpaperID with its own `acquire`, and a `CAContext` can only be
/// hosted in ONE `CALayerHost` at a time. Handing the same `contextId` to two Spaces made
/// the second steal the surface and the first go black (permanent on a space switch, a
/// transient flash during the desktop↔lock reveal). Keying by the WallpaperID UUID gives
/// each surface its own context, so none can steal another's. `displayID` is retained for
/// display-level fan-out (policy, per-display switch).
struct DisplayKey: Hashable {
    let displayID: UInt32
    let surfaceUUID: UUID
}

final class WallpaperState: Sendable {
    static let shared = WallpaperState()

    private static let selectedVideoKey = "selectedVideoID"

    private struct PresentationReport {
        let owner: UUID
        let mode: String
        let activity: String
        let sequence: UInt64
    }

    private struct SurfacePresentation {
        var owner: UUID
        var acquisition: UInt64
        var mode: String?
        var activity: String?
        var isPresented = false
        var confirmation: UInt64 = 0
        var pending: PresentationReport?
    }

    private struct State: @unchecked Sendable {
        /// Persistent contexts keyed by display slot. Reused across acquires.
        var contexts: [DisplayKey: ActiveWallpaper] = [:]
        /// WallpaperID UUID → its surface key, learned at acquire. Lets `invalidate(UUID)`
        /// resolve which surface context to tear down. Each surface owns its context, so an
        /// invalidate tears down only that surface — no cross-surface interference.
        var keyForWallpaperUUID: [UUID: DisplayKey] = [:]
        // Rendering contexts survive host invalidation briefly, but audio permission
        // belongs only to currently acquired, non-preview host connections.
        var liveOwners: [DisplayKey: Set<UUID>] = [:]
        var surfaceOwners: [DisplayKey: Set<UUID>] = [:]
        var presentations: [DisplayKey: SurfacePresentation] = [:]
        var sequence: UInt64 = 0
        var preferredAudioSurface: DisplayKey?
        var presentationConfirmed = false
        var cachedThumbnailURL: URL?
        var cacheDirectoryURL: URL?
        var currentVideoID: String? = UserDefaults.standard.string(forKey: WallpaperState.selectedVideoKey)
        var presentationMode: String = "active"
        var activityState: String = "active"
        var isDisplayAsleep: Bool = false
        // nil until loginwindow supplies a lock/unlock notification. Once known,
        // an older XPC surface update cannot override the loginwindow state.
        var authoritativeLockState: Bool?
        var lockNotificationSequence: UInt64 = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    private init() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let state = Unmanaged<WallpaperState>.fromOpaque(observer).takeUnretainedValue()
                state.clearCaches()
            },
            "local.still.wallpaper.libraryChanged" as CFString,
            nil,
            .deliverImmediately,
        )
    }

    /// Clear cached URLs so the next lookup re-evaluates against the current library.
    private func clearCaches() {
        lock.withLock { state in
            state.cachedThumbnailURL = nil
        }
    }

    // MARK: - Context Management (persistent, reused per display)

    /// The existing persistent context for a display slot, if any.
    func context(for key: DisplayKey) -> ActiveWallpaper? {
        lock.withLock { $0.contexts[key] }
    }

    /// Install a freshly-created context for a display slot (first acquire).
    func installContext(_ context: ActiveWallpaper, for key: DisplayKey) {
        lock.withLock { $0.contexts[key] = context }
    }

    /// Atomically claim the right to create the renderer for a slot. Returns true
    /// only if the slot has no renderer AND no create is already in flight — in
    /// which case it marks a create pending. A concurrent (preview) acquire gets
    /// false and must NOT create a duplicate renderer. This is what guarantees
    /// exactly one renderer per display despite racing desktop+preview acquires.
    func claimRendererCreate(for key: DisplayKey) -> Bool {
        let claimed = lock.withLock { state -> Bool in
            guard var context = state.contexts[key] else { return false }
            if context.renderer != nil || context.rendererPending { return false }
            context.rendererPending = true
            state.contexts[key] = context
            return true
        }
        traceLog("  [claimRendererCreate] display=\(key.displayID) → \(claimed ? "CLAIMED (will create)" : "denied (renderer exists or create pending)")")
        return claimed
    }

    /// Release a create claim without installing a renderer (create threw).
    func clearRendererPending(for key: DisplayKey) {
        lock.withLock { state in
            guard var context = state.contexts[key] else { return }
            context.rendererPending = false
            state.contexts[key] = context
        }
    }

    /// Swap the renderer for an existing display slot (the wallpaper changed),
    /// keeping the same `caContext`/`contextId`/`rootLayer`. Returns the previous
    /// renderer for the caller to stop.
    func setRenderer(_ renderer: VideoRenderer?, videoID: String?, for key: DisplayKey) -> VideoRenderer? {
        let previous = lock.withLock { state -> VideoRenderer? in
            guard var context = state.contexts[key] else { return nil }
            let previous = context.renderer
            context.renderer = renderer
            context.videoID = videoID
            context.rendererPending = false
            state.contexts[key] = context
            return previous
        }
        traceLog("  [setRenderer] display=\(key.displayID) new=\(renderer.map { "#\($0.debugID)" } ?? "nil") replacing=\(previous.map { "#\($0.debugID)" } ?? "nil") videoID=\(videoID ?? "nil")")
        return previous
    }

    /// Record the destination geometry for a slot, returning the slot (with its live
    /// `rootLayer`/`renderer`) only if the geometry actually changed since it was last
    /// laid out. The common re-acquire (display wake, quick Space revisit, a switch that
    /// reuses the id) carries the same size and returns nil — no relayout. A
    /// disconnect→reconnect at a different resolution, or a bare mode change, returns the
    /// slot so the caller can re-frame the layer tree.
    func updateGeometryIfChanged(destSize: CGSize, scaleFactor: CGFloat, for key: DisplayKey) -> ActiveWallpaper? {
        lock.withLock { state -> ActiveWallpaper? in
            guard var context = state.contexts[key] else { return nil }
            if context.destSize == destSize, context.scaleFactor == scaleFactor { return nil }
            context.destSize = destSize
            context.scaleFactor = scaleFactor
            state.contexts[key] = context
            return context
        }
    }

    /// Update the videoID a slot is tracking after an in-place `switchVideo`
    /// (the renderer object is unchanged — only its content switched).
    func updateVideoID(_ videoID: String?, for key: DisplayKey) {
        lock.withLock { state in
            guard var context = state.contexts[key] else { return }
            context.videoID = videoID
            state.contexts[key] = context
        }
    }

    /// Execute a closure for each active renderer (snapshot copy under lock, iteration outside).
    func forEachRenderer(_ body: (VideoRenderer) -> Void) {
        let renderers = lock.withLock { state in
            state.contexts.values.compactMap(\.renderer)
        }
        for renderer in renderers {
            body(renderer)
        }
    }

    /// Whether ANY acquired context tracks the given choice id. Scans every context —
    /// `activeDisplayContexts()` samples one arbitrary context per display, which
    /// misreports when desktop, lock-screen, and preview surfaces coexist on one
    /// display.
    func hasContext(forVideoID videoID: String) -> Bool {
        lock.withLock { state in
            state.contexts.values.contains { $0.videoID == videoID }
        }
    }

    /// Live renderers whose context tracks the given choice id (e.g. the shuffle
    /// sentinel). Snapshot copy under lock, safe to use outside.
    func renderers(forVideoID videoID: String) -> [VideoRenderer] {
        lock.withLock { state in
            state.contexts.values
                .filter { $0.videoID == videoID }
                .compactMap(\.renderer)
        }
    }

    /// Execute a closure for renderers on a specific display.
    func forRenderers(displayID: UInt32, _ body: (VideoRenderer) -> Void) {
        let renderers = lock.withLock { state in
            state.contexts.values
                .filter { $0.displayID == displayID }
                .compactMap(\.renderer)
        }
        for renderer in renderers {
            body(renderer)
        }
    }

    /// Tear down (stop renderer + invalidate context) every display slot using the
    /// given videoID — the video was removed from the library, so its slots are
    /// genuinely gone (not a reuse). Returns affected displayIDs.
    @discardableResult
    func removeContexts(forVideoID videoID: String) -> [UInt32?] {
        let removed = lock.withLock { state -> [ActiveWallpaper] in
            let matches = state.contexts.filter { $0.value.videoID == videoID }
            for (key, _) in matches {
                state.contexts.removeValue(forKey: key)
                state.liveOwners.removeValue(forKey: key)
                state.surfaceOwners.removeValue(forKey: key)
                state.presentations.removeValue(forKey: key)
                state.keyForWallpaperUUID = state.keyForWallpaperUUID.filter { $0.value != key }
            }
            Self.refreshPreferredPresentation(&state)
            return Array(matches.values)
        }
        for context in removed {
            context.renderer?.stop()
            invalidateRemoteContext(context.caContext)
        }
        return removed.map(\.displayID)
    }

    // MARK: - WallpaperID ↔ display bridge (for per-display invalidate/teardown)

    /// Learned at acquire: this WallpaperID UUID maps to this surface `key`, so a later
    /// `invalidate(UUID)` can resolve which surface context to tear down.
    func registerWallpaperID(_ uuid: UUID, key: DisplayKey) {
        lock.withLock { $0.keyForWallpaperUUID[uuid] = key }
    }

    /// The surface key an invalidate's WallpaperID targets, if we know it.
    func resolveWallpaperKey(_ uuid: UUID) -> DisplayKey? {
        lock.withLock { $0.keyForWallpaperUUID[uuid] }
    }

    /// Drop a WallpaperID mapping once its instance is invalidated.
    func forgetWallpaperID(_ uuid: UUID) {
        lock.withLock { _ = $0.keyForWallpaperUUID.removeValue(forKey: uuid) }
    }

    /// Per-surface teardown (the invalidate grace timer fired with no re-acquire — the Space
    /// closed, the preview dismissed, or the display slept): stop ONLY this surface's renderer
    /// and `-[CAContext invalidate]` its context, leaving other surfaces playing. Returns
    /// whether it tore down.
    @discardableResult
    func tearDownContext(for key: DisplayKey) -> Bool {
        let removed = lock.withLock { state -> ActiveWallpaper? in
            state.liveOwners.removeValue(forKey: key)
            state.surfaceOwners.removeValue(forKey: key)
            state.presentations.removeValue(forKey: key)
            state.keyForWallpaperUUID = state.keyForWallpaperUUID.filter { $0.value != key }
            Self.refreshPreferredPresentation(&state)
            return state.contexts.removeValue(forKey: key)
        }
        guard let removed else { return false }
        removed.renderer?.stop()
        invalidateRemoteContext(removed.caContext)
        return true
    }

    /// All unique display IDs from active contexts.
    func uniqueDisplayIDs() -> Set<UInt32> {
        lock.withLock { state in
            Set(state.contexts.values.compactMap(\.displayID))
        }
    }

    /// Get active context info for each unique display.
    func activeDisplayContexts() -> [(displayID: UInt32, videoID: String?)] {
        lock.withLock { state in
            var seen = Set<UInt32>()
            var result: [(displayID: UInt32, videoID: String?)] = []
            for (key, context) in state.contexts {
                guard !context.isPreview, context.renderer != nil,
                      !(state.liveOwners[key] ?? []).isEmpty,
                      let did = context.displayID, seen.insert(did).inserted else { continue }
                result.append((displayID: did, videoID: context.videoID))
            }
            return result
        }
    }

    /// Track all owners, including previews, so a stale connection cannot invalidate
    /// a surface that a newer connection still hosts. Acquiring never grants audio.
    func acquireSurface(_ key: DisplayKey, owner: UUID, isPreview: Bool) {
        lock.withLock { state in
            state.surfaceOwners[key, default: []].insert(owner)
            guard !isPreview else { return }
            state.liveOwners[key, default: []].insert(owner)
            state.sequence &+= 1
            if var presentation = state.presentations[key] {
                if presentation.owner != owner { presentation.pending = nil }
                presentation.owner = owner
                presentation.acquisition = state.sequence
                state.presentations[key] = presentation
            } else {
                state.presentations[key] = SurfacePresentation(owner: owner, acquisition: state.sequence)
            }
        }
    }

    func acquireLiveSurface(_ key: DisplayKey, owner: UUID) {
        acquireSurface(key, owner: owner, isPreview: false)
    }

    /// A recognized active presentation, not acquire order, chooses the sound
    /// source. A creation request may confirm this before its context is installed.
    @discardableResult
    func notePresentedSurface(_ key: DisplayKey, owner: UUID, mode: String, activity: String) -> Bool {
        lock.withLock { state in
            guard let mode = Self.recognizedMode(mode),
                  ["active", "suspended"].contains(activity),
                  state.liveOwners[key]?.contains(owner) == true,
                  var presentation = state.presentations[key], presentation.owner == owner,
                  state.contexts[key]?.isPreview != true else { return false }
            state.sequence &+= 1
            // WallpaperAgent can report the next mode just before loginwindow's
            // notification. Keep it pending without changing accepted playback.
            if let locked = state.authoritativeLockState, !Self.modeIsCompatible(mode, withLock: locked) {
                state.presentations[key]?.pending = PresentationReport(
                    owner: owner, mode: mode, activity: activity, sequence: state.sequence)
                return false
            }
            presentation.pending = nil
            presentation.mode = mode
            presentation.activity = activity
            state.presentations[key] = presentation

            if activity == "suspended" {
                state.presentations[key]?.isPresented = false
                guard state.preferredAudioSurface == key else { return false }
                state.preferredAudioSurface = nil
                Self.refreshPreferredPresentation(&state)
                if !state.presentationConfirmed { state.activityState = "suspended" }
                return true
            }

            // A retained Space can return with UPDATE alone. A recognized active
            // update from its latest owner is authoritative without a new acquire.
            // Only one Space/lock surface is presented on any one physical display.
            for other in Array(state.presentations.keys) where other.displayID == key.displayID && other != key {
                state.presentations[other]?.isPresented = false
            }
            state.sequence &+= 1
            state.presentations[key]?.isPresented = true
            state.presentations[key]?.confirmation = state.sequence
            state.preferredAudioSurface = key
            state.presentationMode = mode
            state.activityState = "active"
            state.presentationConfirmed = true
            return true
        }
    }

    private static func recognizedMode(_ mode: String) -> String? {
        switch mode {
        case "active", "default": return "active"
        case "locked", "idle": return mode
        default: return nil
        }
    }

    private static func effectiveMode(_ state: State) -> String {
        if state.authoritativeLockState == true && state.presentationMode != "idle" { return "locked" }
        if state.authoritativeLockState == false && state.presentationMode == "locked" { return "active" }
        return state.presentationMode
    }

    private static func modeIsCompatible(_ mode: String, withLock locked: Bool) -> Bool {
        // An idle screen saver can remain visible after automatic password lock.
        mode == "idle" || locked == (mode == "locked")
    }

    var effectivePresentationMode: String {
        lock.withLock { Self.effectiveMode($0) }
    }

    private static func presentationIsEligible(_ key: DisplayKey, state: State) -> Bool {
        guard let presentation = state.presentations[key] else { return false }
        return presentation.isPresented && presentation.activity == "active"
            && presentation.mode == effectiveMode(state)
            && state.liveOwners[key]?.contains(presentation.owner) == true
            && state.contexts[key]?.isPreview != true
    }

    private static func refreshPreferredPresentation(_ state: inout State) {
        if let preferred = state.preferredAudioSurface, presentationIsEligible(preferred, state: state) {
            state.presentationConfirmed = true
            return
        }
        state.preferredAudioSurface = state.presentations
            .filter { presentationIsEligible($0.key, state: state) }
            .max { $0.value.confirmation < $1.value.confirmation }?.key
        state.presentationConfirmed = state.preferredAudioSurface != nil
        if let key = state.preferredAudioSurface, let presentation = state.presentations[key] {
            state.presentationMode = presentation.mode ?? state.presentationMode
            state.activityState = presentation.activity ?? state.activityState
        }
    }

    var preferredAudioRenderer: VideoRenderer? {
        lock.withLock { state in
            guard state.presentationConfirmed, !state.isDisplayAsleep,
                  let key = state.preferredAudioSurface,
                  Self.presentationIsEligible(key, state: state),
                  let context = state.contexts[key], !context.isPreview else { return nil }
            return context.renderer
        }
    }

    /// Return true only when this owner released the final acquisition. The caller
    /// may then schedule teardown; a delayed old-owner invalidate leaves newer owners.
    @discardableResult
    func invalidateSurface(_ key: DisplayKey, owner: UUID) -> Bool {
        lock.withLock { state in Self.releaseSurface(key, owner: owner, state: &state) }
    }

    private static func releaseSurface(_ key: DisplayKey, owner: UUID, state: inout State) -> Bool {
        guard state.surfaceOwners[key]?.remove(owner) != nil else { return false }
        state.liveOwners[key]?.remove(owner)
        if state.liveOwners[key]?.isEmpty == true { state.liveOwners.removeValue(forKey: key) }
        if state.presentations[key]?.owner == owner {
            state.presentations.removeValue(forKey: key)
        }
        let lastOwner = state.surfaceOwners[key]?.isEmpty == true
        if lastOwner {
            state.surfaceOwners.removeValue(forKey: key)
            state.presentations.removeValue(forKey: key)
            state.keyForWallpaperUUID = state.keyForWallpaperUUID.filter { $0.value != key }
        }
        Self.refreshPreferredPresentation(&state)
        return lastOwner
    }

    @discardableResult
    func endConnection(owner: UUID) -> [DisplayKey] {
        lock.withLock { state in
            var orphaned: [DisplayKey] = []
            for key in Array(state.surfaceOwners.keys) {
                if Self.releaseSurface(key, owner: owner, state: &state) { orphaned.append(key) }
            }
            return orphaned
        }
    }

    func connectionHasLiveSurface(owner: UUID, key: DisplayKey?) -> Bool {
        lock.withLock { state in
            if let key { return state.liveOwners[key]?.contains(owner) == true }
            return state.liveOwners.values.contains { $0.contains(owner) }
        }
    }

    /// Updates without an ID are safe only when a connection has one unambiguous
    /// live surface, or already owns the currently presented surface.
    func presentationKey(owner: UUID) -> DisplayKey? {
        lock.withLock { state in
            if let key = state.preferredAudioSurface, state.presentations[key]?.owner == owner { return key }
            let keys = state.presentations.filter { $0.value.owner == owner && state.liveOwners[$0.key]?.contains(owner) == true }.map(\.key)
            return keys.count == 1 ? keys[0] : nil
        }
    }

    /// The console-session fallback is restricted to an unknown initial surface;
    /// it must never turn a host-suspended surface back into an active desktop.
    @discardableResult
    func confirmInitialInteractiveDesktop() -> Bool {
        lock.withLock { state in
            guard !state.presentationConfirmed, state.authoritativeLockState != true,
                  let (key, _) = state.presentations.filter({ key, presentation in
                      presentation.mode == nil && presentation.activity == nil
                          && state.liveOwners[key]?.contains(presentation.owner) == true
                          && state.contexts[key]?.isPreview == false && state.contexts[key]?.renderer != nil
                  }).max(by: { $0.value.acquisition < $1.value.acquisition }) else { return false }
            state.sequence &+= 1
            state.presentations[key]?.mode = "active"
            state.presentations[key]?.activity = "active"
            state.presentations[key]?.isPresented = true
            state.presentations[key]?.confirmation = state.sequence
            state.preferredAudioSurface = key
            state.presentationMode = "active"
            state.activityState = "active"
            state.presentationConfirmed = true
            return true
        }
    }

    var hasNonPreviewContexts: Bool {
        lock.withLock { state in
            state.contexts.contains { key, context in
                !context.isPreview && context.renderer != nil && !(state.liveOwners[key] ?? []).isEmpty
            }
        }
    }

    var hasConfirmedLiveAcquisition: Bool {
        lock.withLock { state in
            guard let key = state.preferredAudioSurface else { return false }
            return state.presentationConfirmed && Self.presentationIsEligible(key, state: state)
        }
    }

    var canPlayAudio: Bool {
        lock.withLock { state in
            guard state.presentationConfirmed, !state.isDisplayAsleep,
                  let key = state.preferredAudioSurface, Self.presentationIsEligible(key, state: state),
                  let context = state.contexts[key] else { return false }
            return !context.isPreview && context.renderer != nil
        }
    }

    var activeContextCount: Int {
        lock.withLock { $0.contexts.count }
    }

    /// Count of display slots with a running renderer.
    var liveContextCount: Int {
        lock.withLock { state in
            state.contexts.values.lazy.count(where: { $0.renderer != nil })
        }
    }

    /// Whether this display already has a live renderer for the same surface *role*
    /// (preview vs. live desktop) — i.e. an existing Still surface WallpaperAgent
    /// is already hosting in the SAME CALayerHost this new acquire targets. Only such a
    /// same-role renderer is something the agent can keep compositing while the new
    /// context comes up: a live-desktop CALayerHost isn't held by a preview renderer, and
    /// vice versa. The acquire path uses this to decide reply timing: on a cold start
    /// (nothing to hold for THIS role) it replies as soon as the poster still is up; on
    /// a real same-role switch it defers the reply until the new context is rendering
    /// video, so the host swap lands directly on video with no still-flash.
    ///
    /// Splitting by role fixes the preview-first / desktop-second boot ordering: without
    /// this filter, the preview renderer would trip `hasLiveRenderer` for the incoming
    /// desktop acquire, the desktop reply would defer with nothing held in the desktop
    /// CALayerHost, and the desktop would show black until we finally replied.
    func hasLiveRenderer(onDisplay displayID: UInt32, isPreview: Bool) -> Bool {
        lock.withLock { state in
            state.contexts.values.contains { $0.displayID == displayID && $0.renderer != nil && $0.isPreview == isPreview }
        }
    }

    // MARK: - Properties

    var cachedThumbnailURL: URL? {
        get { lock.withLock { $0.cachedThumbnailURL } }
        set { lock.withLock { $0.cachedThumbnailURL = newValue } }
    }

    var cacheDirectoryURL: URL? {
        get { lock.withLock { $0.cacheDirectoryURL } }
        set { lock.withLock { $0.cacheDirectoryURL = newValue } }
    }

    /// Currently selected video ID, persisted to UserDefaults.
    var currentVideoID: String? {
        get { lock.withLock { $0.currentVideoID } }
        set {
            lock.withLock { $0.currentVideoID = newValue }
            UserDefaults.standard.set(newValue, forKey: WallpaperState.selectedVideoKey)
        }
    }

    // MARK: - Display & Presentation State

    /// Last known presentation mode from the framework's `update()` call.
    var presentationMode: String {
        get { lock.withLock { $0.presentationMode } }
        set { lock.withLock { $0.presentationMode = newValue } }
    }

    /// Last known activity state from the framework's `update()` call.
    var activityState: String {
        get { lock.withLock { $0.activityState } }
        set { lock.withLock { $0.activityState = newValue } }
    }

    /// Whether all displays are currently asleep.
    var isDisplayAsleep: Bool {
        get { lock.withLock { $0.isDisplayAsleep } }
        set { lock.withLock { $0.isDisplayAsleep = newValue } }
    }

    /// Whether the screen is currently locked (lock screen showing).
    /// Tracked via `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`
    /// distributed notifications.
    var isScreenLocked: Bool {
        get { lock.withLock { $0.authoritativeLockState ?? ($0.presentationMode == "locked") } }
        set {
            lock.withLock { state in
                // A duplicate notification is not a new boundary and must not
                // discard an early report for the next actual transition.
                guard state.authoritativeLockState != newValue else { return }
                let retainIdle = state.preferredAudioSurface.flatMap { state.presentations[$0] }
                    .map { $0.mode == "idle" && $0.activity == "active" && $0.isPresented } ?? false
                state.authoritativeLockState = newValue
                state.presentationMode = retainIdle ? "idle" : (newValue ? "locked" : "active")
                state.activityState = "active"
                var pending: [(DisplayKey, PresentationReport)] = []
                for key in Array(state.presentations.keys) {
                    if let presentation = state.presentations[key], let report = presentation.pending,
                       report.sequence > state.lockNotificationSequence,
                       report.owner == presentation.owner,
                       state.liveOwners[key]?.contains(report.owner) == true,
                       state.contexts[key]?.isPreview != true,
                       Self.modeIsCompatible(report.mode, withLock: newValue) {
                        pending.append((key, report))
                    }
                    state.presentations[key]?.pending = nil
                    if let mode = state.presentations[key]?.mode, !Self.modeIsCompatible(mode, withLock: newValue) {
                        state.presentations[key]?.isPresented = false
                    }
                }
                // Apply reports in arrival order so the latest active surface on
                // each display wins. Suspended reports never become audio owners.
                for (key, report) in pending.sorted(by: { $0.1.sequence < $1.1.sequence }) {
                    state.presentations[key]?.mode = report.mode
                    state.presentations[key]?.activity = report.activity
                    state.presentations[key]?.isPresented = report.activity == "active"
                    guard report.activity == "active" else { continue }
                    for other in Array(state.presentations.keys) where other.displayID == key.displayID && other != key {
                        state.presentations[other]?.isPresented = false
                    }
                    state.presentations[key]?.confirmation = report.sequence
                    state.preferredAudioSurface = key
                    state.presentationMode = report.mode
                    state.activityState = "active"
                }
                state.sequence &+= 1
                state.lockNotificationSequence = state.sequence
                Self.refreshPreferredPresentation(&state)
            }
        }
    }
}

/// Force the WindowServer to reclaim a remote `CAContext`. Dropping our Swift
/// reference (ARC) is NOT enough: the context is refcounted across processes, and
/// WallpaperAgent's `CALayerHost` keeps the context's layer tree resident in the
/// render server until it's explicitly invalidated. Without this, every wallpaper
/// switch leaves a pinned tree behind → escalating composite cost / gray, reset
/// only by `killall WallpaperAgent`. `-[CAContext invalidate]` reclaims it even
/// while a consumer host is still attached.
func invalidateRemoteContext(_ caContext: AnyObject) {
    let sel = NSSelectorFromString("invalidate")
    guard let object = caContext as? NSObject, object.responds(to: sel) else { return }
    object.perform(sel)
}
