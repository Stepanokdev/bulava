import AppKit
import CoreGraphics
import EventKit
import Foundation

/// What an automation will need from this Mac, found from what it is set to do — and asked for
/// while he is at the computer, when he creates it, never at night.
///
/// Every one of these used to surface the first time a run touched it: the calendar was asked for
/// when a watch first polled, Mail when its first letter was read, a protected folder when it was
/// first listed — whenever that happened to be, and the dialog then sat in front of an empty chair.
nonisolated enum AutomationNeed: Hashable, Identifiable, Sendable {
    /// A meeting-ended trigger reads the calendar.
    case calendar
    /// A letter trigger asks Mail, by Apple Events.
    case mail
    /// A folder trigger lists a folder macOS guards (Desktop, Documents, Downloads, iCloud, a volume).
    case folder(String)
    /// Its own browser: no window, a throwaway profile (`engine/supervisor/automation-mcp.json`).
    case browser
    /// Screenshots of apps on this Mac, taken by Bulava for the run.
    case screen

    var id: String {
        switch self {
        case .calendar: "calendar"
        case .mail: "mail"
        case .folder(let path): "folder:\(path)"
        case .browser: "browser"
        case .screen: "screen"
        }
    }

    /// Set by the trigger, so certain; the others are read from the brief's words and only offered.
    var comesFromTrigger: Bool {
        switch self {
        case .calendar, .mail, .folder: true
        case .browser, .screen: false
        }
    }
}

nonisolated enum NeedState: Equatable, Sendable {
    case ready
    /// Never asked: the system asks once, now, while he is here.
    case askNow
    /// Refused before — only System Settings changes it.
    case blocked
    /// A guarded folder: known only by reading it, which may show the system's question.
    case checkNow
    /// Something this needs is not on the Mac.
    case missing
    /// Known only when it runs — Mail is closed now.
    case atRunTime

    /// What keeps a trigger-set need from being saved: unanswered or refused.
    var stopsTheTrigger: Bool { self == .askNow || self == .blocked || self == .checkNow }
}

nonisolated enum AutomationNeeds {

    // MARK: What it needs

    static func needs(trigger: AutomationTrigger, brief: String) -> [AutomationNeed] {
        var out: [AutomationNeed] = []
        switch trigger {
        case .event(let event):
            switch event.kind {
            case .meetingEnded: out.append(.calendar)
            case .mail: out.append(.mail)
            case .folder(let path):
                let clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
                if isGuarded(clean) { out.append(.folder(clean)) }
            }
        case .watch(let watch):
            if case .webPage = watch.source { out.append(.browser) }
        case .manual, .schedule:
            break
        }
        let words = brief.lowercased()
        if !out.contains(.browser), browserWords.contains(where: words.contains) { out.append(.browser) }
        if screenWords.contains(where: words.contains) { out.append(.screen) }
        return out
    }

    /// Ukrainian, Russian and English, as he writes briefs.
    static let browserWords = ["браузер", "сайт", "веб-сторінк", "вебсторінк", "сторінку", "сторінки",
                               "страниц", "website", "web page", "webpage", "browser", "http://", "https://"]
    static let screenWords = ["скріншот", "знімок екрана", "знімки екрана", "запис екрана",
                              "скриншот", "снимок экрана", "screenshot", "screen recording"]

    /// Folders macOS asks about before anything may list them.
    static func isGuarded(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        guard !path.isEmpty else { return false }
        let guarded = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"]
            .map { (home as NSString).appendingPathComponent($0) }
        let standard = (path as NSString).standardizingPath
        return standard.hasPrefix("/Volumes/")
            || guarded.contains { standard == $0 || standard.hasPrefix($0 + "/") }
    }

    // MARK: Where things stand — never shows a dialog

    @MainActor
    static func state(of need: AutomationNeed) async -> NeedState {
        switch need {
        case .calendar:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return .ready
            case .notDetermined: return .askNow
            default: return .blocked
            }
        case .mail:
            return await mailState(asking: false)
        case .folder:
            return .checkNow
        case .browser:
            return chromeInstalled ? .ready : .missing
        case .screen:
            return CGPreflightScreenCaptureAccess() ? .ready : .askNow
        }
    }

    // MARK: Asking — he is here, so the system's own question may appear

    @MainActor
    static func ask(_ need: AutomationNeed) async -> NeedState {
        switch need {
        case .calendar:
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                _ = try? await WatchSources.calendarStore.requestFullAccessToEvents()
            }
            return await state(of: .calendar)
        case .mail:
            return await mailState(asking: true)
        case .folder(let path):
            // Listing it is how macOS is asked: Bulava itself reads it when a file arrives.
            let readable = await Task.detached { (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil }.value
            return readable ? .ready : .blocked
        case .browser:
            return await state(of: .browser)
        case .screen:
            _ = CGRequestScreenCaptureAccess()
            return await state(of: .screen)
        }
    }

    /// Where a refusal is undone, or what to open.
    static func fixURL(_ need: AutomationNeed) -> URL? {
        switch need {
        case .calendar: WatchFix.calendarPrivacy.url
        case .mail: WatchFix.automationPrivacy.url
        case .folder: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
        case .browser: URL(string: "https://www.google.com/chrome/")
        case .screen: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }

    static var chromeInstalled: Bool {
        ["/Applications/Google Chrome.app",
         (NSHomeDirectory() as NSString).appendingPathComponent("Applications/Google Chrome.app")]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: Mail, by Apple Events

    /// Mail's permission for Bulava's Apple Events. Asking blocks until he answers, so it is done
    /// off the main thread; a closed Mail cannot be asked at all.
    static func mailState(asking: Bool) async -> NeedState {
        let status = await Task.detached { () -> OSStatus in
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.mail")
            guard let desc = target.aeDesc else { return OSStatus(procNotFound) }
            return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, asking)
        }.value
        return mailState(status)
    }

    nonisolated static func mailState(_ status: OSStatus) -> NeedState {
        switch Int(status) {
        case Int(noErr): return .ready
        case -1744: return .askNow     // errAEEventWouldRequireUserConsent
        case -1743: return .blocked    // errAEEventNotPermitted
        case Int(procNotFound): return .atRunTime
        default: return .atRunTime
        }
    }
}
