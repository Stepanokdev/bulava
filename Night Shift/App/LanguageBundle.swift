import AppKit
import Darwin
import OSLog

enum LanguageBundle {

    nonisolated static var isDebuggerAttached: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = name.withUnsafeMutableBufferPointer { pointer in
            sysctl(pointer.baseAddress, u_int(pointer.count), &info, &size, nil, 0)
        }
        return result == 0 && (info.kp_proc.p_flag & P_TRACED) != 0
    }

    nonisolated static func shouldRelaunchAtStartup(
        language: AppLanguage,
        arguments: [String],
        isTestHost: Bool,
        debuggerAttached: Bool
    ) -> Bool {
        !isTestHost
            && !debuggerAttached
            && language.localeIdentifier != nil
            && !arguments.contains("-AppleLanguages")
    }

    private nonisolated static var isTestHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }

    nonisolated(unsafe) private(set) static var current: Bundle = .main

    nonisolated(unsafe) private(set) static var currentCode: String = "en"

    nonisolated static func adopt(_ language: AppLanguage) {
        guard let code = language.localeIdentifier else {
            current = .main
            currentCode = Bundle.main.preferredLocalizations.first ?? "en"
            return
        }
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            current = bundle
            currentCode = code
        } else {
            current = .main
            currentCode = Bundle.main.preferredLocalizations.first ?? "en"
        }
    }

    static func relaunch(to language: AppLanguage) {

        if isDebuggerAttached || isTestHost {
            adopt(language)
            Log.lifecycle.notice("interface language applied without relaunch while debugging")
            return
        }
        let path = Bundle.main.bundlePath
        var args = ["-n", path]
        if let code = language.localeIdentifier {
            args += ["--args", "-AppleLanguages", "(\(code))"]
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        try? p.run()
        exit(0)
    }

    static func ensureLaunchedLanguageAtStartup() {
        let saved = AppSettings.load().interfaceLanguage

        adopt(saved)

        if shouldRelaunchAtStartup(language: saved,
                                   arguments: CommandLine.arguments,
                                   isTestHost: isTestHost,
                                   debuggerAttached: isDebuggerAttached) {
            relaunch(to: saved)
        } else if saved.localeIdentifier != nil,
                  !CommandLine.arguments.contains("-AppleLanguages"),
                  isDebuggerAttached {
            Log.lifecycle.notice("launch kept under debugger; saved interface language applied in process")
        }
    }
}
