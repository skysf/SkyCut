import Foundation

// MARK: - The router's lines: which AI call waits for which, and which call holds a line
//
// What it does: every queued AI call joins one or more lines (AIToolRouter.queueKeys picks them: "project:p2" for a call that
// touches a project, "session:<id>" for the rest of a session's calls, "switch:<id>" for opening / creating / closing projects).
// A call starts once every call that joined one of its lines before it has let go. A call lets go when it is done, or earlier when it
// says it no longer needs the line: a look lets go as soon as it has read what it needs from the project (`AICallLines.letGo()`), so
// the edits and looks behind it do not wait for its frames to render (docs/bugfixes/2026-11-17-look-hangs-and-dropped-calls.md).
// The lines also say, for a call still waiting, how many waiting calls are ahead of it and which call holds the line
// (get_job's queue_position / waiting_for for a look that became a job, AILookCall).
// What it does not do: which lines a call joins (AIToolRouter.queueKeys), running a call (AIToolRouter.execute), jobs (AIJobs, AILookCall).
//
// Everything is on the main actor and joining is synchronous, so calls hold their lines in the order they joined them.
// A place lets go only after its turn came, and its turn comes only after everything ahead of it let go: so waiting for the last
// place of each line is waiting for the whole line.

@MainActor
final class AICallLines {
    /// One call's place in its lines.
    @MainActor
    final class Place {
        /// Order of joining (any line); earlier places have smaller numbers.
        let number: Int
        let tool: String
        let session: String
        let client: String
        let keys: [String]
        /// The last place of each of its lines when it joined: its turn comes once all of them have let go. Emptied when the turn
        /// comes, so finished calls are not kept alive through the places behind them.
        fileprivate var after: [Place]
        fileprivate weak var lines: AICallLines?
        /// When its turn came; nil while it waits.
        fileprivate(set) var startedAt: Date?
        fileprivate(set) var hasLetGo = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        fileprivate init(number: Int, tool: String, session: String, client: String, keys: [String], after: [Place], lines: AICallLines) {
            self.number = number
            self.tool = tool
            self.session = session
            self.client = client
            self.keys = keys
            self.after = after
            self.lines = lines
        }

        /// The calls behind this one may go. Only after its turn came (before that the line is not its to give); again does nothing.
        func letGo() {
            guard startedAt != nil, !hasLetGo else { return }
            hasLetGo = true
            lines?.forget(self)
            let woken = waiters
            waiters = []
            woken.forEach { $0.resume() }
        }

        fileprivate func waitUntilLetGo() async {
            guard !hasLetGo else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// The place of the queued call running in this task (the router sets it around the call).
    @TaskLocal static var current: Place?

    /// From inside a call: it no longer needs its lines (a look that has read what it needs from the project). Outside a queued
    /// call (a check calling a tool directly) it does nothing.
    static func letGo() {
        current?.letGo()
    }

    /// The last place of each line (it may have let go already).
    private var last: [String: Place] = [:]
    /// Places that have not let go yet, per line, in the order they joined.
    private var holding: [String: [Place]] = [:]
    private var joined = 0

    /// Join these lines (synchronously: the order of joining is the order of turns).
    func join(_ keys: [String], tool: String, session: String, client: String) -> Place {
        joined += 1
        var after: [Place] = []
        for key in keys {
            guard let previous = last[key], !previous.hasLetGo, !after.contains(where: { $0 === previous }) else { continue }
            after.append(previous)
        }
        let place = Place(number: joined, tool: tool, session: session, client: client, keys: keys, after: after, lines: self)
        for key in keys {
            last[key] = place
            holding[key, default: []].append(place)
        }
        return place
    }

    /// Wait until every call ahead of it in its lines has let go; then its turn has come.
    func waitForTurn(_ place: Place) async {
        for earlier in place.after { await earlier.waitUntilLetGo() }
        place.after = []
        place.startedAt = Date()
    }

    /// Wait until the last call in this line has let go (a call without `project` waits for its session's opening / closing first).
    func waitForLast(in key: String) async {
        await last[key]?.waitUntilLetGo()
    }

    /// For a place still waiting: its position (waiting places ahead of it + 1, so 1 = next) and the earliest place ahead that holds
    /// the line (running; if none is running yet, the earliest waiting one). nil once its turn has come.
    func standing(of place: Place) -> (position: Int, holder: Place?)? {
        guard place.startedAt == nil else { return nil }
        var ahead: [Place] = []
        for key in place.keys {
            for other in holding[key] ?? [] where other.number < place.number && !ahead.contains(where: { $0 === other }) {
                ahead.append(other)
            }
        }
        ahead.sort { $0.number < $1.number }
        let holder = ahead.first { $0.startedAt != nil } ?? ahead.first
        return (ahead.filter { $0.startedAt == nil }.count + 1, holder)
    }

    fileprivate func forget(_ place: Place) {
        for key in place.keys {
            holding[key]?.removeAll { $0 === place }
            if holding[key]?.isEmpty == true { holding[key] = nil }
        }
    }
}
