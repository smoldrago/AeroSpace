@testable import AppBundle
import Common
import Foundation
import XCTest

@MainActor
final class AgentSessionCommandTest: XCTestCase {
    func testParseActionsAndRejectMalformedClaims() {
        testParseSingleCommandSucc(
            "agent-session bind session-1 abc",
            AgentSessionCmdArgs(rawArgs: []).copy(\.action, .initialized(.bind(sessionId: "session-1", workspace: WorkspaceName.parse("abc").getOrDie()))),
        )
        testParseSingleCommandSucc(
            "agent-session claim session-1 123",
            AgentSessionCmdArgs(rawArgs: []).copy(\.action, .initialized(.claim(sessionId: "session-1", pid: 123))),
        )
        testParseSingleCommandSucc(
            "agent-session unbind session-1",
            AgentSessionCmdArgs(rawArgs: []).copy(\.action, .initialized(.unbind(sessionId: "session-1"))),
        )
        testParseCommandFail("agent-session claim session-1 0", msg: "ERROR: Invalid process ID '0'", exitCode: 2)
        testParseCommandFail("agent-session claim session-1 2147483648", msg: "ERROR: Invalid process ID '2147483648'", exitCode: 2)
        testParseCommandFail("agent-session bind session-1", msg: "ERROR: bind requires <workspace>", exitCode: 2)
        testParseCommandFail("agent-session bind session-1 prev", msg: "ERROR: 'prev' is a reserved workspace name", exitCode: 2)
        testParseCommandFail("agent-session unbind session-1 extra", msg: "ERROR: Unknown argument 'extra'", exitCode: 2)
    }

    func testOnlyProcessesLaunchedAfterBindingCanBeClaimed() {
        var routing = AgentSessionRouting()
        let boundAt = Date(timeIntervalSince1970: 1_000)
        let oldLaunch = boundAt.addingTimeInterval(-1)
        let newLaunch = boundAt.addingTimeInterval(1)

        assertTrue(routing.claim("missing", pid: 42, launchDate: newLaunch)?.contains("not bound") == true)
        assertEquals(routing.bind("agent", to: "agent-ws", at: boundAt), nil)
        assertTrue(routing.claim("agent", pid: 42, launchDate: oldLaunch)?.contains("already running") == true)
        assertEquals(routing.workspaceName(for: 42, launchDate: oldLaunch), nil)

        assertEquals(routing.claim("agent", pid: 42, launchDate: newLaunch), nil)
        assertEquals(routing.bind("agent", to: "agent-ws", at: newLaunch), nil)
        assertEquals(routing.workspaceName(for: 42, launchDate: newLaunch), "agent-ws")
        // Recycled PID or stale MacApp must not inherit the session's workspace.
        assertEquals(routing.bind("other", to: "other-ws", at: newLaunch), nil)
        let reusedPidLaunch = newLaunch.addingTimeInterval(1)
        assertEquals(routing.claim("other", pid: 42, launchDate: reusedPidLaunch), nil)
        assertEquals(routing.workspaceName(for: 42, launchDate: newLaunch), nil)
        assertEquals(routing.workspaceName(for: 42, launchDate: reusedPidLaunch), "other-ws")
        assertEquals(routing.workspaceName(for: 42, launchDate: newLaunch.addingTimeInterval(2)), nil)
    }

    func testClaimsHaveExclusiveOwnershipUntilUnbound() {
        var routing = AgentSessionRouting()
        let boundAt = Date(timeIntervalSince1970: 1_000)
        let launch = boundAt.addingTimeInterval(1)
        assertEquals(routing.bind("first", to: "one", at: boundAt), nil)
        assertEquals(routing.bind("second", to: "two", at: boundAt), nil)
        assertEquals(routing.claim("first", pid: 42, launchDate: launch), nil)
        assertTrue(routing.claim("second", pid: 42, launchDate: launch)?.contains("already claimed") == true)
        assertEquals(routing.workspaceName(for: 42, launchDate: launch), "one")
        assertTrue(routing.bind("first", to: "two", at: boundAt)?.contains("unbind") == true)
        assertEquals(routing.workspaceName(for: 42, launchDate: launch), "one")

        routing.unbind("first")
        assertEquals(routing.workspaceName(for: 42, launchDate: launch), nil)
        assertEquals(routing.claim("second", pid: 42, launchDate: launch), nil)
        assertEquals(routing.workspaceName(for: 42, launchDate: launch), "two")
        routing.unbind("second")
        assertEquals(routing.workspaceName(for: 42, launchDate: launch), nil)
    }
}
