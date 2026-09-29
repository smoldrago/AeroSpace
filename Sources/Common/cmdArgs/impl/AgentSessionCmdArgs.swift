public struct AgentSessionCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .agentSession,
        help: agent_session_help_generated,
        flags: [:],
        posArgs: [newMandatoryPosArgParser(\.action, parseAgentSessionAction, placeholder: "(bind|claim|unbind)")],
    )

    public var action: Lateinit<Action> = .uninitialized

    public enum Action: Equatable, Sendable {
        case bind(sessionId: String, workspace: WorkspaceName)
        case claim(sessionId: String, pid: Int32)
        case unbind(sessionId: String)
    }
}

private func parseAgentSessionAction(i: PosArgParserInput) -> ParsedCliArgs<AgentSessionCmdArgs.Action> {
    let count = i.arg == "unbind" ? 1 : 2
    switch i.arg {
        case "bind", "claim", "unbind": break
        default: return .fail("Unknown action '\(i.arg)'. Possible values: (bind|claim|unbind)", advanceBy: 1)
    }
    guard let sessionId = i.getOrNil(relativeIndex: 1), !sessionId.isEmpty else {
        return .fail("\(i.arg) requires <session-id>", advanceBy: 1)
    }
    guard count == 1 || i.getOrNil(relativeIndex: 2) != nil else {
        return .fail("\(i.arg) requires \(i.arg == "bind" ? "<workspace>" : "<pid>")", advanceBy: 2)
    }
    switch i.arg {
        case "bind":
            let workspace = WorkspaceName.parse(i.getOrNil(relativeIndex: 2)!)
            return .init(workspace.map { .bind(sessionId: sessionId, workspace: $0) }, advanceBy: 3)
        case "claim":
            let rawPid = i.getOrNil(relativeIndex: 2)!
            guard let pid = Int32(rawPid), pid > 0 else { return .fail("Invalid process ID '\(rawPid)'", advanceBy: 3) }
            return .succ(.claim(sessionId: sessionId, pid: pid), advanceBy: 3)
        case "unbind": return .succ(.unbind(sessionId: sessionId), advanceBy: 2)
        default: preconditionFailure("Action checked above")
    }
}
