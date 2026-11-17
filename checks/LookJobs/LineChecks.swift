import Foundation
@testable import SrtFlow

// The router's lines (AICallLines) on their own: no project, no look, only who gets a turn when.

/// What the waiting calls did, in order (a class: the waiting tasks append to it on the main actor).
@MainActor final class LineEvents {
    var events: [String] = []
}

/// Let the main actor run whatever was just woken.
@MainActor func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor func runLineChecks() async {
    let lines = AICallLines()
    let seen = LineEvents()

    // 1. One line: turns in joining order; a call waits while the one ahead holds the line.
    let first = lines.join(["project:p1"], tool: "add_clips", session: "s1", client: "Check")
    let second = lines.join(["project:p1"], tool: "edit_clip", session: "s1", client: "Check")
    await lines.waitForTurn(first)
    let secondTurn = Task { @MainActor in
        await lines.waitForTurn(second)
        seen.events.append("second")
    }
    await settle()
    require(seen.events.isEmpty, "a call waits while the call ahead of it holds the line")
    let standing = lines.standing(of: second)
    require(standing?.position == 1 && standing?.holder === first, "the waiting call is next, held by add_clips (got \(String(describing: standing)))")
    first.letGo()
    await secondTurn.value
    require(seen.events == ["second"] && lines.standing(of: second) == nil, "its turn comes once the call ahead lets go")
    second.letGo()

    // 2. Several lines: closing a project waits for its session's switch line and the project's own line.
    let edit = lines.join(["project:p2"], tool: "edit_clips", session: "s1", client: "Check")
    let open = lines.join(["switch:s1"], tool: "open_project", session: "s1", client: "Check")
    let close = lines.join(["switch:s1", "project:p2"], tool: "close_project", session: "s1", client: "Check")
    await lines.waitForTurn(edit)
    await lines.waitForTurn(open)
    let closeTurn = Task { @MainActor in
        await lines.waitForTurn(close)
        seen.events.append("close")
    }
    open.letGo()
    await settle()
    require(!seen.events.contains("close"), "a call in two lines waits for both (the edit still holds the project's line)")
    require(lines.standing(of: close)?.holder === edit, "what holds it is the edit that is still running")
    edit.letGo()
    await closeTurn.value
    require(seen.events.last == "close", "its turn comes once both lines are free")
    close.letGo()

    // 3. A read lets go as soon as it has read the project: the edit behind it starts while the read is still running.
    let look = lines.join(["project:p3"], tool: "look", session: "s1", client: "Check")
    let after = lines.join(["project:p3"], tool: "set_text", session: "s1", client: "Check")
    await lines.waitForTurn(look)
    let afterTurn = Task { @MainActor in
        await lines.waitForTurn(after)
        seen.events.append("after-look")
    }
    await settle()
    require(!seen.events.contains("after-look"), "before the read lets go the edit behind it waits")
    AICallLines.$current.withValue(look) { AICallLines.letGo() }
    await afterTurn.value
    require(seen.events.last == "after-look" && look.startedAt != nil, "the read let go from inside its call (AICallLines.letGo) and the edit went")
    after.letGo()
    look.letGo()

    // 4. Positions: a running edit and two waiting calls behind it: 1 and 2, both held by the edit; a third line is not counted.
    let running = lines.join(["project:p4"], tool: "add_clips", session: "s1", client: "Check")
    await lines.waitForTurn(running)
    let one = lines.join(["project:p4"], tool: "look", session: "s1", client: "Check")
    let two = lines.join(["project:p4"], tool: "look", session: "s1", client: "Check")
    let elsewhere = lines.join(["project:p5"], tool: "look", session: "s2", client: "Check")
    require(lines.standing(of: one)?.position == 1 && lines.standing(of: two)?.position == 2,
            "positions count the waiting calls ahead (got \(String(describing: lines.standing(of: one)?.position)), "
                + "\(String(describing: lines.standing(of: two)?.position)))")
    require(lines.standing(of: two)?.holder === running, "the holder is the running edit, not the look waiting ahead")
    await lines.waitForTurn(elsewhere)
    require(lines.standing(of: elsewhere) == nil, "another session's project line does not wait for this one")
    require(AILookCall.describe(running, for: "s1").hasPrefix("add_clips from this AI session, running for "),
            "waiting_for names the tool and the session (got \(AILookCall.describe(running, for: "s1")))")
    require(AILookCall.describe(running, for: "s2").hasPrefix("add_clips from another AI session (Check)"),
            "another session's call is named as such (got \(AILookCall.describe(running, for: "s2")))")

    // 5. Letting go before the turn does nothing: the line is not the waiting call's to give.
    two.letGo()
    require(!two.hasLetGo && lines.standing(of: two)?.position == 2, "a waiting call cannot let its line go")
    running.letGo()
    await lines.waitForTurn(one)
    one.letGo()
    await lines.waitForTurn(two)
    two.letGo()
    elsewhere.letGo()

    // 6. waitForLast: a call without a project first waits for its session's opening / closing (the switch line).
    let opening = lines.join(["switch:s3"], tool: "new_project", session: "s3", client: "Check")
    await lines.waitForTurn(opening)
    let lastWait = Task { @MainActor in
        await lines.waitForLast(in: "switch:s3")
        seen.events.append("switched")
    }
    await settle()
    require(!seen.events.contains("switched"), "waitForLast waits while the last call in the line holds it")
    opening.letGo()
    await lastWait.value
    require(seen.events.last == "switched", "waitForLast returns once it lets go")
    await lines.waitForLast(in: "switch:nobody")
    print("lines: turns in order, several lines, a read letting go early, positions, waitForLast")
}
