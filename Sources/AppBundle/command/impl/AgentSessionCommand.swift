import AppKit
import Common

struct AgentSessionCommand: Command {
    let args: AgentSessionCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        switch args.action.val {
            case .bind(let sessionId, let workspace):
                if let error = AgentSessionRouting.shared.bind(sessionId, to: workspace.raw) { return .fail(io.err(error)) }
            case .claim(let sessionId, let pid):
                guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated, let launchDate = app.launchDate else {
                    return .fail(io.err("Process \(pid) is not running or its start time is unavailable"))
                }
                if let error = AgentSessionRouting.shared.claim(sessionId, pid: pid, launchDate: launchDate) {
                    return .fail(io.err(error))
                }
                guard let workspaceName = AgentSessionRouting.workspaceName(for: app) else {
                    return .fail(io.err("Process \(pid) changed identity during claim"))
                }
                resetClosedWindowsCache()
                let workspace = Workspace.get(byName: workspaceName)
                // These windows may have been detected after app launch but before OMP obtained the PID.
                // The process start time was checked against the binding time before touching any window.
                for window in MacWindow.allWindowsMap.values where window.macApp.pid == pid &&
                    window.macApp.nsApp.launchDate == launchDate && window.nodeWorkspace != nil &&
                    window.nodeWorkspace !== workspace
                {
                    _ = moveWindowToWorkspace(window, workspace, io, focusFollowsWindow: false, failIfNoop: false)
                }
            case .unbind(let sessionId):
                AgentSessionRouting.shared.unbind(sessionId)
                resetClosedWindowsCache()
        }
        return .succ
    }
}

/// Binding must precede *process launch*, not merely claim. Windows belonging to an old,
/// already-running app must never be mistaken for windows opened by the agent.
@MainActor
struct AgentSessionRouting {
    static var shared = AgentSessionRouting()

    private struct Binding {
        let workspaceName: String
        let createdAt: Date
    }

    private struct Claim {
        let sessionId: String
        let launchDate: Date
    }

    private var bindings: [String: Binding] = [:]
    private var claims: [pid_t: Claim] = [:]

    mutating func bind(_ sessionId: String, to workspaceName: String, at date: Date = .now) -> String? {
        if let binding = bindings[sessionId] {
            return binding.workspaceName == workspaceName ? nil : "Session '\(sessionId)' is already bound; unbind it before changing workspace"
        }
        bindings[sessionId] = Binding(workspaceName: workspaceName, createdAt: date)
        return nil
    }

    mutating func claim(_ sessionId: String, pid: pid_t, launchDate: Date) -> String? {
        guard let binding = bindings[sessionId] else { return "Session '\(sessionId)' is not bound" }
        guard launchDate >= binding.createdAt else {
            return "Process \(pid) was already running when session '\(sessionId)' was bound; refusing to move unrelated windows"
        }
        if let previous = claims[pid], previous.launchDate == launchDate, previous.sessionId != sessionId {
            return "Process \(pid) is already claimed by session '\(previous.sessionId)'"
        }
        claims[pid] = Claim(sessionId: sessionId, launchDate: launchDate)
        return nil
    }

    mutating func unbind(_ sessionId: String) {
        bindings.removeValue(forKey: sessionId)
        claims = claims.filter { $0.value.sessionId != sessionId }
    }

    func workspaceName(for pid: pid_t, launchDate: Date) -> String? {
        guard let claim = claims[pid], claim.launchDate == launchDate else { return nil }
        return bindings[claim.sessionId]?.workspaceName
    }

    /// Resolve the *current* process, not just the cached MacApp or a recycled PID.
    static func workspaceName(for app: NSRunningApplication) -> String? {
        let pid = app.processIdentifier
        guard shared.claims[pid] != nil, !app.isTerminated,
            let current = NSRunningApplication(processIdentifier: pid), !current.isTerminated,
            let launchDate = current.launchDate, launchDate == app.launchDate
        else { return nil }
        return shared.workspaceName(for: pid, launchDate: launchDate)
    }

    static func workspaceName(for app: MacApp) -> String? {
        workspaceName(for: app.nsApp)
    }
}
