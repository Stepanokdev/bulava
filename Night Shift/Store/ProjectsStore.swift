import SwiftUI
import Observation

@MainActor
@Observable
final class ProjectsStore {
    private(set) var projects: [Project] = []
    private(set) var live: [UUID: ProjectLiveStatus] = [:]

    private let file = JSONFile<[Project]>(url: AppSupport.file("projects.json"))

    init() {
        projects = file.load() ?? []
    }

    private func persist() { file.save(projects) }

    // MARK: Mutations

    @discardableResult
    func add(path: String) -> Project {
        let canonical = Slug.canonicalPath(path)
        if let existing = projects.first(where: { Slug.canonicalPath($0.path) == canonical }) { return existing }
        let detected = ProjectScanner.detect(path: canonical)
        let p = Project(name: (canonical as NSString).lastPathComponent,
                        path: canonical, kind: detected.kind, stacks: detected.stacks)
        projects.append(p)
        persist()
        return p
    }

    func remove(_ id: UUID) {
        projects.removeAll { $0.id == id }
        live[id] = nil
        persist()
    }

    func update(_ project: Project) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[idx] = project
        persist()
    }

    func togglePin(_ id: UUID) {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[idx].pinned.toggle()
        persist()
    }

    func setDelivery(_ id: UUID, _ mode: DeliveryMode) {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[idx].delivery = mode
        persist()
    }

    func rescan(_ id: UUID) {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        let detected = ProjectScanner.detect(path: projects[idx].path)
        projects[idx].kind = detected.kind
        projects[idx].stacks = detected.stacks
        projects[idx].buildCommand = Project.defaultBuildCommand(for: detected.kind)
        persist()
    }

    func setGitInfo(_ id: UUID, remote: String?, defaultBranch: String?) {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        var changed = false
        if projects[idx].gitRemote != remote { projects[idx].gitRemote = remote; changed = true }
        if projects[idx].defaultBranch != defaultBranch { projects[idx].defaultBranch = defaultBranch; changed = true }
        if changed { persist() }
    }

    var needingGitInfo: [Project] { projects.filter { $0.defaultBranch == nil } }

    // MARK: Lookups

    func project(id: UUID) -> Project? { projects.first { $0.id == id } }
    func project(path: String) -> Project? {
        let canonical = Slug.canonicalPath(path)
        return projects.first { Slug.canonicalPath($0.path) == canonical }
    }
    func project(slug: String) -> Project? { projects.first { $0.slug == slug } }

    var sorted: [Project] {
        projects.sorted {
            if $0.pinned != $1.pinned { return $0.pinned && !$1.pinned }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: Live reconciliation

    func reconcile(with snap: SupervisorSnapshot) {
        var next: [UUID: ProjectLiveStatus] = [:]
        for p in projects {
            var status = ProjectLiveStatus()
            let slug = p.slug
            if let inst = snap.instances.first(where: { $0.slug == slug }) {
                status.supervised = inst.active
                status.phase = inst.phase
                status.branch = inst.branch
                status.healthy = inst.healthy || inst.doneResult != nil
                if inst.doneResult == "needs-user" { status.needsAttention = true }
            }
            let canonical = Slug.canonicalPath(p.path)
            status.queuedCount = snap.queue.pending.filter { Slug.canonicalPath($0.projectPath) == canonical }.count
            if snap.queue.needsUser.contains(where: { Slug.canonicalPath($0.projectPath) == canonical }) {
                status.needsAttention = true
            }
            if let recent = snap.queue.done.first(where: { Slug.canonicalPath($0.projectPath) == canonical }) {
                status.lastOutcome = recent.outcome
            }
            next[p.id] = status
        }
        if next != live { live = next }
    }

    func status(for id: UUID) -> ProjectLiveStatus { live[id] ?? ProjectLiveStatus() }
}
