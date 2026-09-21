import Foundation

nonisolated enum ProjectScanner {

    static func detect(path: String) -> (kind: ProjectKind, stacks: [String]) {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: path)
        let entries = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        var stacks = Set<String>()

        func has(_ predicate: (String) -> Bool) -> Bool { entries.contains(where: predicate) }
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(name).path) }
        func fileContains(_ name: String, _ needles: [String]) -> Bool {
            guard let s = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { return false }
            let lower = s.lowercased()
            return needles.contains { lower.contains($0) }
        }

        if has({ $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) { stacks.insert("ios-native") }
        if exists("Package.swift") { stacks.insert("ios-native") }
        if has({ $0.hasSuffix(".swift") }) { stacks.insert("ios-native") }

        let gradleFiles = entries.filter { $0.hasSuffix(".gradle.kts") }
        if !gradleFiles.isEmpty {
            for g in gradleFiles where fileContains(g, ["multiplatform", "compose", "jetbrains.compose"]) {
                stacks.insert("compose-multiplatform")
            }
        }

        if exists("go.mod") { stacks.insert("backend-go") }
        if exists("pyproject.toml") || exists("requirements.txt") { stacks.insert("backend-python") }

        if exists("package.json") {
            if fileContains("package.json", ["\"react\"", "\"vite\"", "\"next\"", "\"vue\"", "\"svelte\"", "@angular/core"]) {
                stacks.insert("web-frontend")
            } else {
                stacks.insert("web-frontend"); stacks.insert("web-landing")
            }
            if fileContains("package.json", ["maplibre", "mapbox", "leaflet", "postgis", "geojson"]) {
                stacks.insert("maps")
            }
        }
        if exists("index.html") { stacks.insert("web-landing") }

        return (primaryKind(from: stacks), stacks.sorted())
    }

    private static func primaryKind(from stacks: Set<String>) -> ProjectKind {
        if stacks.contains("maps") { return .maps }
        if stacks.contains("ios-native") { return .iosNative }
        if stacks.contains("compose-multiplatform") { return .composeMultiplatform }
        if stacks.contains("web-frontend") { return .webFrontend }
        if stacks.contains("web-landing") { return .webLanding }
        if stacks.contains("backend-go") { return .backendGo }
        if stacks.contains("backend-python") { return .backendPython }
        return .unknown
    }
}
