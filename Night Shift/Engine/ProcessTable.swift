import Foundation
import Darwin

/// The processes on this Mac, each with its arguments exactly as it was started.
///
/// `pgrep -f watchdog.sh` was how the app used to ask whether the engine was in use, and it asks
/// the wrong question: it matches any process whose command line merely CONTAINS those characters.
/// On the machine the engine is written on that was, at one point, seven watchdogs leaked by test
/// runs into temporary folders, the watchdog of another product's state folder, and a Codex
/// reviewer whose prompt happened to quote the word. Every one of them refused the install, and
/// none of them was using the engine being installed.
///
/// So this reads what the kernel holds for each process — `argv`, one element per argument, no
/// joining with spaces — and the question becomes "which file is this process running", answered
/// with a path that can be compared. `ps` cannot answer that: it joins the arguments with spaces,
/// and the path the engine runs from has a space in it.
nonisolated enum ProcessTable {

    struct Entry: Equatable, Sendable {
        var pid: Int32
        var argv: [String]
    }

    /// Every process of this user that the kernel will describe. Other users' processes are not
    /// readable, and are not this app's business either.
    static func snapshot() -> [Entry] {
        allPIDs().compactMap { pid in
            guard pid > 0, let argv = arguments(of: pid), !argv.isEmpty else { return nil }
            return Entry(pid: pid, argv: argv)
        }
    }

    static func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Room for processes started between the two calls.
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBufferPointer { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<Int32>.size))
        }
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled))).filter { $0 > 0 }
    }

    /// `argv` of one process, or nil when it has gone or belongs to someone else.
    ///
    /// KERN_PROCARGS2 is `argc`, then the executable path, then padding, then `argc` strings — and
    /// after them the environment, which is deliberately not read.
    static func arguments(of pid: Int32) -> [String]? {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mibMax: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mibMax, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        var length = Int(argmax)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let ok = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, 3, raw.baseAddress, &length, nil, 0) == 0
        }
        guard ok, length > MemoryLayout<Int32>.size else { return nil }
        return parse(procargs: Array(buffer.prefix(length)))
    }

    /// The layout above, separated out so it can be checked without a live process.
    static func parse(procargs bytes: [UInt8]) -> [String]? {
        guard bytes.count > 4 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return [] }
        var i = 4
        while i < bytes.count, bytes[i] != 0 { i += 1 }   // the executable path
        while i < bytes.count, bytes[i] == 0 { i += 1 }   // its padding
        var args: [String] = []
        while args.count < Int(argc), i < bytes.count {
            let start = i
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            args.append(String(decoding: bytes[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// The directory a process is working in, for a script it was given by a relative path.
    static func workingDirectory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            let path = String(decoding: bytes[..<end], as: UTF8.self)
            return path.isEmpty ? nil : path
        }
    }

    /// One spelling per place on disk: symlinks followed, `/var` and `/private/var` made the same.
    ///
    /// For a path that does not exist (yet, or any more) the deepest part that does is resolved and
    /// the rest is kept as written — an engine that is not installed still has a place it will be
    /// installed to, and a process cannot be running from inside it.
    static func canonical(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        if let real = realpath(standardized, nil) {
            defer { free(real) }
            return String(cString: real)
        }
        var head = standardized
        var tail: [String] = []
        while head != "/" && !head.isEmpty {
            tail.insert((head as NSString).lastPathComponent, at: 0)
            head = (head as NSString).deletingLastPathComponent
            if let real = realpath(head, nil) {
                defer { free(real) }
                return ([String(cString: real)] + tail).joined(separator: "/")
                    .replacingOccurrences(of: "//", with: "/")
            }
        }
        return standardized
    }

    /// Whether `path` is `root` or somewhere under it, compared as places rather than as strings —
    /// so `/Users/x/Engine2` is not inside `/Users/x/Engine`.
    static func path(_ path: String, isInside root: String) -> Bool {
        let p = canonical(path), r = canonical(root)
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }
}

/// Which of the processes on this Mac belong to one particular engine directory.
nonisolated enum EngineProcesses {

    /// The engine's own long-running programs. Anything else it runs is short-lived.
    static let daemons = ["watchdog.sh", "message-pump.sh", "pipeline.sh"]

    /// What a process is running, when it is running a script: the script, not the shell.
    ///
    /// The engine starts its daemons as `nohup /path/bin/watchdog.sh slug`, which the kernel turns
    /// into `/bin/bash /path/bin/watchdog.sh slug` — so the script is the first argument after the
    /// interpreter and its options. A process that is not an interpreter is running itself.
    static func script(of argv: [String]) -> String? {
        guard let first = argv.first else { return nil }
        let interpreters: Set<String> = ["bash", "sh", "zsh", "dash", "ksh", "env"]
        let exe = (first as NSString).lastPathComponent
        guard interpreters.contains(exe) || exe.hasPrefix("-") && interpreters.contains(String(exe.dropFirst())) else {
            return first
        }
        var rest = argv.dropFirst()
        // `bash -c '…'` runs a string, not a file — whatever the string mentions.
        while let arg = rest.first, arg.hasPrefix("-") {
            if arg == "-c" { return nil }
            rest = rest.dropFirst()
        }
        // `env VAR=x bash script` — skip the assignments and the next interpreter.
        if exe == "env" {
            while let arg = rest.first, arg.contains("=") && !arg.hasPrefix("/") { rest = rest.dropFirst() }
            return script(of: Array(rest))
        }
        return rest.first
    }

    /// Engine daemons running from inside `engine` — the ones replacing that directory would
    /// change underneath.
    static func daemons(of engine: URL, in table: [ProcessTable.Entry],
                        cwd: (Int32) -> String? = ProcessTable.workingDirectory(of:)) -> [EngineBusy.Leftover] {
        table.compactMap { entry in
            guard var script = script(of: entry.argv) else { return nil }
            let name = (script as NSString).lastPathComponent
            guard daemons.contains(name) else { return nil }
            if !script.hasPrefix("/") {
                guard let dir = cwd(entry.pid) else { return nil }
                script = (dir as NSString).appendingPathComponent(script)
            }
            guard ProcessTable.path(script, isInside: engine.path) else { return nil }
            return EngineBusy.Leftover(pid: entry.pid, name: name)
        }
    }

    /// An rsync copying into `engine`: the process IS rsync, and one of its arguments is that
    /// directory. A prompt that quotes an rsync command line is neither.
    static func writers(into engine: URL, in table: [ProcessTable.Entry]) -> [Int32] {
        table.compactMap { entry in
            guard let program = script(of: entry.argv),
                  (program as NSString).lastPathComponent == "rsync" else { return nil }
            let touches = entry.argv.dropFirst().contains { arg in
                arg.hasPrefix("/") && ProcessTable.path(arg, isInside: engine.path)
            }
            return touches ? entry.pid : nil
        }
    }
}
