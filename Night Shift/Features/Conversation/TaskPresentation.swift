import SwiftUI

struct ResultAction: Identifiable {
    enum Emphasis { case primary, secondary, quiet, danger }

    var id: String
    var titleKey: LocalizedStringKey
    var symbol: String
    var emphasis: Emphasis = .secondary
    var disabledReason: String?
    var perform: (AppModel) -> Void
}

extension WorkerPhase {

    var humanLabel: String {
        switch self {
        case .starting:         String(localized: "Spinning up")
        case .working:          String(localized: "Doing the work")
        case .awaitingDecision: String(localized: "Waiting for a decision")
        case .pausedForLimit:   String(localized: "Paused on a limit")
        case .reviewing:        String(localized: "Being reviewed")
        case .done:             String(localized: "Finished")
        case .blocked:          String(localized: "Blocked")
        case .stalled:          String(localized: "Gone quiet")

        case .offline:          String(localized: "Waiting for the network")
        case .idle:             String(localized: "Idle")
        }
    }
}

enum TaskPresentation {

    // MARK: - Actions in the conversation

    static func cardActions(for task: BacklogTask, model: AppModel) -> [ResultAction] {
        let state = model.workState(of: task)

        switch state {
        case .reportReady, .partial:
            var out: [ResultAction] = []
            if task.isInformationalReview {

                out.append(ResultAction(id: "read", titleKey: "Open the answer",
                                        symbol: "doc.text", emphasis: .primary) {
                    $0.openReport(task)
                })
                out.append(ResultAction(id: "ack", titleKey: "That answers it",
                                        symbol: "checkmark") {
                    $0.markReviewed(task: task)
                })
            } else {
                out.append(ResultAction(id: "report", titleKey: "Open the report",
                                        symbol: "doc.text", emphasis: .primary) {
                    $0.openReport(task)
                })
            }
            out.append(ResultAction(id: "changes", titleKey: "Ask for changes",
                                    symbol: "arrow.uturn.backward", emphasis: .quiet) {
                $0.beginAskingChanges(task)
            })
            return out

        case .running:
            return [
                ResultAction(id: "instruct", titleKey: "Give an instruction",
                             symbol: "text.bubble") { $0.beginInstructing(task) },
                ResultAction(id: "pause", titleKey: "Pause", symbol: "pause",
                             emphasis: .quiet) { $0.pause(task: task) },
            ]

        case .paused:
            return [
                ResultAction(id: "resume", titleKey: "Resume", symbol: "play",
                             emphasis: .primary) { $0.resume(task: task) }
            ]

        case .planned:

            if task.isNote {
                return [
                    ResultAction(id: "adopt", titleKey: "Take this on", symbol: "play.fill",
                                 emphasis: .primary) { $0.adoptNote(task) },
                    ResultAction(id: "drop", titleKey: "Not needed", symbol: "trash",
                                 emphasis: .quiet) { $0.deleteTask(task) },
                ]
            }
            return [
                ResultAction(id: "start", titleKey: "Start now", symbol: "play.fill",
                             emphasis: .primary) { $0.dispatch(task: task) },
                ResultAction(id: "drop", titleKey: "Drop it", symbol: "trash",
                             emphasis: .danger) { $0.deleteTask(task) },
            ]

        case .failed:
            var out: [ResultAction] = []
            if model.canDispatch(task) {
                out.append(ResultAction(id: "retry", titleKey: "Run it again",
                                        symbol: "arrow.clockwise", emphasis: .primary) {
                    $0.dispatch(task: task)
                })
            }
            out.append(ResultAction(id: "drop", titleKey: "Drop it", symbol: "trash",
                                    emphasis: .danger) { $0.deleteTask(task) })
            return out

        case .stopped:

            var out: [ResultAction] = []
            if !model.hasLiveTrail(for: task) {
                out.append(ResultAction(id: "trail", titleKey: "What happened?",
                                        symbol: "list.bullet.rectangle", emphasis: .primary) {
                    $0.showWorkerTrail(task: task)
                })
            }
            if model.reportPath(for: task) != nil {
                out.append(ResultAction(id: "report", titleKey: "Open the report",
                                        symbol: "doc.text") { $0.openReport(task) })
            }
            if model.canDispatch(task) {
                out.append(ResultAction(id: "retry", titleKey: "Run it again",
                                        symbol: "arrow.clockwise", emphasis: .quiet) {
                    $0.dispatch(task: task)
                })
            }
            out.append(ResultAction(id: "instruct", titleKey: "Give an instruction",
                                    symbol: "text.bubble", emphasis: .quiet) {
                $0.beginInstructing(task)
            })
            return out

        case .needsAnswer:

            var out: [ResultAction] = []
            out.append(ResultAction(id: "decide", titleKey: "What needs deciding?",
                                    symbol: "questionmark.bubble", emphasis: .primary) {
                $0.askForDecision(task: task)
            })
            if model.reportPath(for: task) != nil {
                out.append(ResultAction(id: "report", titleKey: "Open the report",
                                        symbol: "doc.text") { $0.openReport(task) })
            }
            out.append(ResultAction(id: "instruct", titleKey: "Give an instruction",
                                    symbol: "text.bubble") { $0.beginInstructing(task) })
            return out

        case .done:
            return [
                ResultAction(id: "report", titleKey: "Open the report",
                             symbol: "doc.text") { $0.openReport(task) }
            ]
        }
    }

    // MARK: - Final actions in the report

    static func finalActions(for task: BacklogTask,
                             package: ReviewPackage?,
                             blocker: String?,
                             model: AppModel) -> [ResultAction] {
        var out: [ResultAction] = []

        if task.isInformationalReview {
            out.append(ResultAction(id: "ack", titleKey: "That answers it",
                                    symbol: "checkmark", emphasis: .primary,
                                    disabledReason: blocker) {
                $0.markReviewed(task: task)
            })
            out.append(ResultAction(id: "followup", titleKey: "Turn this into work",
                                    symbol: "arrow.turn.down.right") {
                $0.beginFollowUp(task)
            })
            return out
        }

        out.append(ResultAction(id: "changes", titleKey: "Ask for changes",
                                symbol: "arrow.uturn.backward") {
            $0.beginAskingChanges(task)
        })
        if let project = model.project(for: task) {
            out.append(ResultAction(id: "open", titleKey: "Open the project",
                                    symbol: "folder", emphasis: .quiet) {
                $0.openInEditor(project.path)
            })
        }

        guard let package else {

            out.insert(ResultAction(id: "unavailable", titleKey: "Cannot read the changes",
                                    symbol: "exclamationmark.triangle", emphasis: .secondary,
                                    disabledReason: String(localized: "Bulava could not read this run's changes, so it will not offer to merge them. Open the project to look, or ask for changes.")) { _ in },
                       at: 0)
            return out
        }

        let mode = model.deliveryMode(for: task)
        let hasRemote = package.mergeTarget != nil && (model.projectRemote(for: task) != nil)

        if mode.mergesOnApprove || !hasRemote {
            out.append(ResultAction(id: "merge", titleKey: "Merge it in",
                                    symbol: "arrow.triangle.merge", emphasis: .primary,
                                    disabledReason: blocker) {
                $0.approve(task: task, package: package)
            })
        } else {

            out.append(ResultAction(id: "pr", titleKey: "Open a pull request",
                                    symbol: "arrow.up.forward.square", emphasis: .primary,
                                    disabledReason: blocker) {
                $0.approve(task: task, package: package)
            })
        }

        return out
    }

    // MARK: - Copy

    static func failedReason(task: BacklogTask, model: AppModel) -> String {
        switch task.lastOutcome {
        case "gone":
            return String(localized: "The worker was stopped before it finished, so there is no result. You can run it again or drop it.")
        case "vanished":
            return String(localized: "The run disappeared before finishing and left no result. You can run it again or drop it.")
        default:
            return model.backlog.blockReason(task) ?? task.externalBlocker
                ?? String(localized: "This run did not finish. You can run it again or drop it.")
        }
    }

    static func subtitle(for task: BacklogTask, model: AppModel) -> String? {
        let instance = model.liveInstance(for: task)
        switch model.workState(of: task) {
        case .running, .paused:
            return nil
        case .planned:
            return model.backlog.blockReason(task)
                ?? String(localized: "Waiting its turn")
        case .needsAnswer:

            return model.backlog.blockReason(task) ?? task.externalBlocker
                ?? instance?.pendingQuestion?.summary ?? instance?.outcomeSummary
        case .stopped:

            return instance?.outcomeSummary
                ?? String(localized: "It stopped without asking anything — open the trail to see where")
        case .partial:
            return String(localized: "Part of this is in — the report says what is missing")
        case .failed:
            return failedReason(task: task, model: model)
        case .reportReady:
            return instance?.outcomeSummary
        case .done:
            return task.lastOutcome.map { QueueOutcome(raw: $0).label }
        }
    }
}
