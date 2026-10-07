import CoreServices
import CryptoKit
import Foundation

/// The watch and event half of automations: looking, remembering what was seen, gathering a burst
/// into one run.
extension AppModel {

    func pollWatch(_ automation: Automation, now: Date) {
        guard !automationChecking.contains(automation.id) else { return }
        let state = automation.watch ?? WatchState()
        let interval = WatchSources.interval(automation.trigger)
        let folderMoved = folderChangedAt[automation.id].map { now.timeIntervalSince($0) > 20 } ?? false
        let due = state.lastCheckedAt.map { now.timeIntervalSince($0) >= interval } ?? true
        if due || folderMoved {
            folderChangedAt[automation.id] = nil
            automationChecking.insert(automation.id)
            let asked = automation.trigger
            Task {
                let result = await WatchSources.check(asked, state: state, now: now)
                self.automationChecking.remove(automation.id)
                self.take(result, for: automation.id, at: now, asked: asked)
                self.handOverGathered(automation.id, now: Date())
            }
            return
        }
        handOverGathered(automation.id, now: now)
    }

    /// Fold one look into what the watch remembers. The first look only learns what is already
    /// there; after that, anything not seen before is gathered for a run.
    ///
    /// `asked` is what the look was asked of. An answer about a source he has since changed is an
    /// answer about the wrong thing, and is dropped rather than poured into the new source's state.
    func take(_ result: WatchCheck, for automationID: UUID, at now: Date, asked: AutomationTrigger? = nil) {
        automations.update(automationID) { a in
            if let asked, a.trigger != asked { return }
            var w = a.watch ?? WatchState()
            w.lastCheckedAt = now
            w.lastError = result.error ?? result.warning
            w.lastErrorFix = result.error == nil ? nil : result.fix
            if result.error == nil { w.lastSucceededAt = now }
            if let cursor = result.cursor { w.cursor = cursor }
            let fresh = result.items.filter { !w.seen.contains($0.id) }
            if !w.baselined {
                // A failed first look learns nothing, and is tried again.
                if result.error == nil || !result.items.isEmpty || result.cursor != nil {
                    w.remember(result.items.map(\.id))
                    w.baselined = true
                }
            } else if !fresh.isEmpty {
                w.remember(fresh.map(\.id))
                for item in fresh {
                    // A file still being written comes back under a new name each look; only its
                    // latest state is worth a run.
                    if let link = item.link, item.id.hasPrefix("file:") {
                        w.pending.removeAll { $0.link == link }
                    }
                    w.pending.append(item)
                }
                if w.pendingSince == nil { w.pendingSince = now }
                w.lastFoundAt = now
            }
            a.watch = w
        }
    }

    /// Start one run with everything gathered, once the burst has gone quiet — or has gone on long
    /// enough that waiting further would mean never.
    func handOverGathered(_ automationID: UUID, now: Date) {
        reconcileWatchItems(automationID)
        guard let automation = automations.automation(id: automationID), automation.enabled,
              let w = automation.watch, !w.pending.isEmpty, let since = w.pendingSince else { return }
        let (quiet, longest) = WatchSources.gathering(automation.trigger)
        let lastNew = w.lastFoundAt ?? since
        guard now.timeIntervalSince(lastNew) >= quiet || now.timeIntervalSince(since) >= longest else { return }
        // No more than a run is shown: what is beyond the batch waits for the next run, instead of
        // being marked handled by a run that never saw it.
        let items = Array(w.pending.prefix(AutomationBrief.batchLimit))
        let isEvent: Bool = { if case .event = automation.trigger { return true }; return false }()
        // A second attempt at the same items is a different occurrence from the first, or the
        // retry promised after a failure would be refused as a duplicate of it.
        let key = "watch:" + items.map { $0.retried ? $0.id + "#retry" : $0.id }.sorted()
            .joined(separator: ",").sha1Prefix
        // The run goes on the record first and the items leave the watch second. A quit in between
        // finds them still gathered and already owned by a run — `reconcileWatchItems` lets them go
        // then, never lost and never run twice.
        switch beginRun(automation, occurrence: key,
                        reason: isEvent ? .event(count: items.count) : .changed(count: items.count),
                        items: items, now: now) {
        case .recorded, .duplicate:
            releasePending(items, from: automationID)
        case .refused:
            break
        }
    }

    // MARK: Who owns what

    /// What an item is owned under. A retry is a claim of its own: handed back after a failure, it
    /// is not mistaken for the first run still holding it.
    nonisolated static func ownershipKey(_ item: WatchItem) -> String {
        item.retried ? item.id + "#retry" : item.id
    }

    /// Make the gathered list agree with the runs, whichever of the two files reached the disk
    /// last: a retry a failure owes is put back if it went missing, and what a run already holds is
    /// let go. Cheap, changes nothing when they already agree, and safe to call at any time.
    func reconcileWatchItems(_ automationID: UUID) {
        recoverOwedRetries(automationID)
        releaseOwnedPending(automationID)
    }

    /// Put back the retries failures owe that are neither gathered nor held by a run.
    ///
    /// The failure and its retry are two writes to two files; a quit between them used to lose the
    /// retry for good, since a failed run is never looked at again. The failure now carries the debt
    /// itself (`retryOwed`), so it is settled from here: once every retry is held by a run, or can
    /// no longer apply, the debt is cleared and the run is not looked at again.
    func recoverOwedRetries(_ automationID: UUID) {
        let owing = automations.runs(for: automationID).filter { $0.retryOwed == true }
        guard !owing.isEmpty else { return }
        let watch = automations.automation(id: automationID)?.watch
        let owned = ownedKeys(automationID)
        var waiting = Set((watch?.pending ?? []).map(Self.ownershipKey))
        var handBack: [WatchItem] = []
        var settled: [UUID] = []
        for run in owing {
            let retries = run.items.filter { !$0.retried }.map { item -> WatchItem in
                var retry = item; retry.retried = true; return retry
            }
            var open = false
            for retry in retries where !owned.contains(Self.ownershipKey(retry)) {
                // A source he has since changed starts afresh — its watch has never seen this item —
                // and an old find is not retried against the new one.
                guard let watch, run.isRealFailure, watch.seen.contains(retry.id) else { continue }
                open = true
                if waiting.insert(Self.ownershipKey(retry)).inserted { handBack.append(retry) }
            }
            if !open { settled.append(run.id) }
        }
        if !handBack.isEmpty {
            automations.update(automationID) { a in
                a.watch?.pending.append(contentsOf: handBack)
                if a.watch?.pendingSince == nil { a.watch?.pendingSince = Date() }
            }
        }
        for id in settled { automations.updateRun(id) { $0.retryOwed = false } }
    }

    /// Every item the automation's runs own, under their ownership keys.
    func ownedKeys(_ automationID: UUID) -> Set<String> {
        Set(automations.runs(for: automationID).flatMap { $0.items.map(Self.ownershipKey) })
    }

    /// Let go of gathered items that a run already owns.
    ///
    /// A run is written to one file and the gathered list to another, and nothing makes the two
    /// reach the disk together: a quit between them leaves an item gathered that a run already has.
    /// Who owns it is read from the runs themselves — not from the batch it went out in, which a
    /// newly arrived item changes, nor from how the run was started, which a manual run's name does
    /// not share with a watch's. So whatever order the files were written in, an item belongs to one
    /// run, and only a retry, under its own key, can take it again.
    func releaseOwnedPending(_ automationID: UUID) {
        guard let pending = automations.automation(id: automationID)?.watch?.pending, !pending.isEmpty else { return }
        let owned = ownedKeys(automationID)
        let held = pending.filter { owned.contains(Self.ownershipKey($0)) }
        guard !held.isEmpty else { return }
        releasePending(held, from: automationID)
    }

    // MARK: Folders

    /// One FSEvents stream per folder automation that is switched on. A change marks the folder;
    /// the next poll looks at it. A dropped event costs nothing: the folder is also read on a clock.
    func syncFolderWatchers() {
        var wanted: [UUID: String] = [:]
        for a in automations.automations where a.enabled {
            if case .event(let e) = a.trigger, case .folder(let path) = e.kind { wanted[a.id] = path }
        }
        for (id, watcher) in folderWatchers where wanted[id] != watcher.path {
            watcher.stop()
            folderWatchers[id] = nil
        }
        for (id, path) in wanted where folderWatchers[id] == nil {
            let watcher = FolderWatcher(path: path) { [weak self] in
                Task { @MainActor in self?.folderChangedAt[id] = Date() }
            }
            if watcher.start() { folderWatchers[id] = watcher }
        }
    }
}

/// Tells when anything in one folder changes. Coalesced by FSEvents itself over a few seconds.
final class FolderWatcher {
    let path: String
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?

    init(path: String, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() -> Bool {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.onChange()
        }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                                               [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 3.0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else {
            return false
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    isolated deinit { stop() }
}

extension String {
    /// A short stable name for a long key.
    nonisolated var sha1Prefix: String {
        let digest = Insecure.SHA1.hash(data: Data(utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}
