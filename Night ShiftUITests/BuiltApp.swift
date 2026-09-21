//
//  BuiltApp.swift
//  Night ShiftUITests
//
//  Which copy of Bulava a UI test drives.
//
//  `XCUIApplication()` resolves by bundle identifier, and LaunchServices answers with whatever
//  copy it likes — after Bulava was installed into /Applications, that is the installed one, not
//  the build this scheme just produced. The runner then waits on an app that never becomes the app
//  under test and fails with "Timed out while enabling automation mode", which says nothing about
//  the cause.
//
//  Addressed by path instead: the products directory is two levels above the runner's own bundle,
//  and the app under test sits in it beside the runner.
//

import XCTest

nonisolated enum BuiltApp {

    static func app(for testCase: XCTestCase) -> XCUIApplication {
        XCUIApplication(url: url(for: testCase))
    }

    static func url(for testCase: XCTestCase) -> URL {
        // …/Debug/Night ShiftUITests-Runner.app/Contents/PlugIns/Night ShiftUITests.xctest
        var dir = Bundle(for: type(of: testCase)).bundleURL
        for _ in 0..<4 { dir = dir.deletingLastPathComponent() }   // → …/Debug
        return dir.appendingPathComponent("Bulava.app")
    }
}
