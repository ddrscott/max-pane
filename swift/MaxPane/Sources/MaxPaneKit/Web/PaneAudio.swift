import Foundation
import LanedCore

/// One web pane's sound: whether it is making any, whether it has been muted,
/// and how loud it is.
struct PaneAudio: Equatable {
    /// WebKit says an element with an audio track is playing, unmuted by the
    /// page, above zero volume. Still true while the pane is muted from here
    /// (ADR-0034), and held for `PaneAudioCenter.hold` after it stops.
    var playing = false
    var muted = false
    /// 1 to 100: the last level that was not silence, which is what unmuting
    /// returns to. A slider at zero is `muted`.
    var volume = 100

    /// Sound is coming out of this pane.
    var isAudible: Bool { playing && !muted }
    /// What a slider shows: zero while muted.
    var effectiveVolume: Int { muted ? 0 : volume }
}

/// The one glyph every surface draws, and when.
///
/// Audible wins over muted in a lane that has both: the pane making noise is
/// the one a click has to reach. Muted shows whether or not anything is
/// playing, because a muted lane that shows nothing is a lane you forget you
/// muted.
enum AudioMark: Equatable {
    case silent, audible, muted

    var icon: LucideIcon? {
        switch self {
        case .silent: return nil
        case .audible: return .volume2
        case .muted: return .volumeX
        }
    }

    /// What a click will do, for the tooltip.
    var verb: String { self == .muted ? "Unmute" : "Mute" }
}

/// Every web pane's sound, in one place every surface can read.
///
/// Not the ledger's: what is playing is a fact about this second. The mute
/// and the volume *are* remembered (`pane.muted`, `pane.volume`, migration
/// 0017), but the core publishes no snapshot for them, as with zoom, so this
/// is the live copy: seeded from the snapshot the first time a pane is asked
/// about, and the authority from then on.
///
/// A pane's controller registers a sink and reports what WebKit says; a
/// surface observes and asks for marks; a click, a command or the control
/// socket calls the setters. A pane with no controller yet (a lane never
/// scrolled to) can still be muted: the value is written, and its controller
/// reads it here when it is built.
@MainActor
final class PaneAudioCenter {
    /// How long the indicator outlives the sound, so a half-second
    /// notification blip is one appearance and not a flicker.
    var hold: TimeInterval = 2

    private var states: [String: PaneAudio] = [:]
    private var sinks: [String: (PaneAudio) -> Void] = [:]
    private var holds: [String: DispatchWorkItem] = [:]
    private var observers: [UUID: () -> Void] = [:]

    /// The ledger's copy of a pane, for seeding. Set by the store.
    var lookup: (String) -> Pane? = { _ in nil }
    /// Write a pane's mute and volume through. Set by the store.
    var persist: (_ paneId: String, _ muted: Bool, _ volume: Int) -> Void = { _, _, _ in }

    // MARK: - reading

    func state(of paneId: String) -> PaneAudio {
        if let known = states[paneId] { return known }
        guard let pane = lookup(paneId) else { return PaneAudio() }
        // Kept, so the ledger is asked once per pane and not once per redraw.
        let seeded = PaneAudio(playing: false, muted: pane.muted, volume: max(1, min(100, Int(pane.volume))))
        states[paneId] = seeded
        return seeded
    }

    func mark(of paneId: String) -> AudioMark { Self.mark([state(of: paneId)]) }

    func mark(of lane: Lane) -> AudioMark {
        Self.mark(lane.panes.filter { $0.kind == .web }.map { state(of: $0.id) })
    }

    static func mark(_ panes: [PaneAudio]) -> AudioMark {
        if panes.contains(where: \.isAudible) { return .audible }
        if panes.contains(where: \.muted) { return .muted }
        return .silent
    }

    /// The panes of these lanes that are making sound right now.
    func audiblePanes(in lanes: [Lane]) -> [String] {
        lanes.flatMap(\.panes).filter { $0.kind == .web && state(of: $0.id).isAudible }.map(\.id)
    }

    /// The pane a lane's volume slider speaks for: the one making sound, else
    /// the muted one, else its first page. Nil for a lane with no page.
    func volumePane(of lane: Lane) -> String? {
        let pages = lane.panes.filter { $0.kind == .web }
        return (pages.first { state(of: $0.id).isAudible } ?? pages.first { state(of: $0.id).muted } ?? pages.first)?.id
    }

    // MARK: - observing

    func observe(_ body: @escaping () -> Void) -> UUID {
        let token = UUID()
        observers[token] = body
        return token
    }

    func stopObserving(_ token: UUID) { observers[token] = nil }

    // MARK: - the pane's side

    /// A controller is ready to be told. Called with the current state at once.
    func attach(_ paneId: String, sink: @escaping (PaneAudio) -> Void) {
        sinks[paneId] = sink
        sink(state(of: paneId))
    }

    func detach(_ paneId: String) {
        sinks[paneId] = nil
        holds.removeValue(forKey: paneId)?.cancel()
        guard var state = states[paneId], state.playing else { return }
        // Nothing is left to say it stopped.
        state.playing = false
        commit(paneId, state, persisting: false)
    }

    /// What WebKit says, from the pane's page and any popup it opened.
    func report(_ paneId: String, playing: Bool) {
        var state = self.state(of: paneId)
        if playing {
            holds.removeValue(forKey: paneId)?.cancel()
            guard !state.playing else { return }
            state.playing = true
            commit(paneId, state, persisting: false)
        } else {
            guard state.playing, holds[paneId] == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.holds[paneId] = nil
                var state = self.state(of: paneId)
                guard state.playing else { return }
                state.playing = false
                self.commit(paneId, state, persisting: false)
            }
            holds[paneId] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
        }
    }

    /// Panes the ledger no longer has.
    func prune(keeping live: Set<String>) {
        for id in states.keys where !live.contains(id) {
            states[id] = nil
            holds.removeValue(forKey: id)?.cancel()
        }
    }

    // MARK: - the person's side

    func setMuted(_ muted: Bool, pane paneId: String) {
        var state = self.state(of: paneId)
        guard state.muted != muted else { return }
        state.muted = muted
        commit(paneId, state, persisting: true)
    }

    /// 0 to 100. Zero is mute, and keeps the level to come back to; anything
    /// else is that level, unmuted. `restoring` is the level a drag started
    /// from, so a slider dragged down to zero unmutes to where it was and not
    /// to the 1 % it passed on the way.
    func setVolume(_ percent: Int, pane paneId: String, restoring: Int? = nil) {
        var state = self.state(of: paneId)
        let percent = min(max(percent, 0), 100)
        if percent == 0 {
            state.muted = true
            if let restoring, restoring > 0 { state.volume = min(restoring, 100) }
        } else {
            state.muted = false
            state.volume = percent
        }
        guard state != self.state(of: paneId) else { return }
        commit(paneId, state, persisting: true)
    }

    /// A click on a lane's speaker: silence what is audible; with nothing
    /// audible, unmute what is muted; with neither, mute the lane's pages, so
    /// the command does something on a lane that is about to make noise.
    func toggleMute(lane: Lane) {
        let pages = lane.panes.filter { $0.kind == .web }.map(\.id)
        let audible = pages.filter { state(of: $0).isAudible }
        let muted = pages.filter { state(of: $0).muted }
        if !audible.isEmpty {
            audible.forEach { setMuted(true, pane: $0) }
        } else if !muted.isEmpty {
            muted.forEach { setMuted(false, pane: $0) }
        } else {
            pages.forEach { setMuted(true, pane: $0) }
        }
    }

    func toggleMute(pane paneId: String) { setMuted(!state(of: paneId).muted, pane: paneId) }

    /// Mute whatever is making sound in these lanes. Returns how many.
    @discardableResult
    func muteAudible(in lanes: [Lane], except kept: String? = nil) -> Int {
        let targets = audiblePanes(in: lanes).filter { $0 != kept }
        targets.forEach { setMuted(true, pane: $0) }
        return targets.count
    }

    private func commit(_ paneId: String, _ next: PaneAudio, persisting: Bool) {
        let before = state(of: paneId)
        states[paneId] = next
        guard next != before else { return }
        if persisting { persist(paneId, next.muted, next.volume) }
        if next.muted != before.muted || next.volume != before.volume { sinks[paneId]?(next) }
        for body in observers.values { body() }
    }
}
