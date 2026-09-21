import Foundation

nonisolated enum ProjectHandoff: Equatable {

    case proceed

    case takeOver(TakeOver)

    case refuse(holder: String)

    nonisolated struct TakeOver: Equatable {
        var projectPath: String
        var session: String
        /// True when the chat that is taking over already has a session id of its own. It must
        /// then be RESUMED rather than started fresh, and its `activeRunID` — which points at the
        /// run being torn down — has to be cleared or the engine fail-closes on the mismatch.
        var resumesOwnSession: Bool
    }

    /// `holderIsTakeable` is the whole question, and it is deliberately not "is it running".
    ///
    /// A run holding a question for the director, paused on a usage window, parked on a deadline,
    /// waiting out a network outage or stopped for going quiet is idle at this instant and is not
    /// over. Handing its project to another chat would end it. So the permission is a terminal
    /// result, not an absence of activity: anything short of finished is refused, and the
    /// director stops it himself if he means to.
    static func decide(holderTitle: String?,
                       holderProjectPath: String,
                       holderSession: String,
                       holderIsTakeable: Bool,
                       callerHasSessionID: Bool) -> ProjectHandoff {
        guard let holderTitle else { return .proceed }
        guard holderIsTakeable else { return .refuse(holder: holderTitle) }
        return .takeOver(.init(projectPath: holderProjectPath,
                               session: holderSession,
                               resumesOwnSession: callerHasSessionID))
    }
}

/// Freeing a project, as a sequence that can be checked rather than assumed.
///
/// The first version declared success once the tmux session vanished, and ignored what stopping
/// the instance actually returned. Both have to be gone: an instance record left behind means the
/// app still sees a run that is not there, and the next send is made against stale state.
nonisolated struct ProjectRelease {

    enum Failure: Equatable {
        case stopRefused(String)
        case instanceRemains
        case sessionRemains
    }

    /// Injected so the sequence can be exercised without an engine: each closure answers for one
    /// real effect, and the order and the confirmation are what is being tested.
    var stop: @Sendable () async -> (ok: Bool, message: String)
    var killSession: @Sendable () async -> Void
    var instanceGone: @Sendable () async -> Bool
    var sessionGone: @Sendable () async -> Bool
    var wait: @Sendable () async -> Void = { }
    var attempts: Int = 20

    func run() async -> Failure? {
        let stopped = await stop()
        guard stopped.ok else { return .stopRefused(stopped.message) }
        await killSession()
        for _ in 0..<attempts {
            let noInstance = await instanceGone()
            let noSession = await sessionGone()
            if noInstance && noSession { return nil }
            await wait()
        }
        return await instanceGone() ? .sessionRemains : .instanceRemains
    }
}
