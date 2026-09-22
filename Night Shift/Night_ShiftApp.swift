import SwiftUI
import AppKit
import OSLog

@main
struct NightShiftApp: App {
    @State private var model = AppModel()
    @State private var updates = UpdateController()

    init() {
        Log.lifecycle.notice("Bulava launch pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public) debugger=\(LanguageBundle.isDebuggerAttached, privacy: .public)")
        if SavedSplitLayout.repairIfNeeded() {
            Log.lifecycle.notice("discarded a split-view layout wider than its saved window")
        }

        if SingleInstance.shouldYield() {
            NSApplication.shared.terminate(nil)
        }

        LanguageBundle.ensureLaunchedLanguageAtStartup()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: Metrics.minimumWindowWidth,
                       minHeight: Metrics.minimumWindowHeight)
                .environment(updates)
                .task { model.start() }
                .task {
                    // The updater must not put a window in front of a run in progress.
                    updates.isWorkInFlight = { !model.activeInstances.isEmpty }
                    updates.start()
                }
                .preferredColorScheme(model.settings.appearance.colorScheme)
                .themedLocale(model.settings.interfaceLanguage)

                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification)) { _ in
                    model.stop()
                }
        }
        .defaultSize(width: 1380, height: 900)
        .windowResizability(.contentMinSize)
        .commands {

            CommandGroup(after: .appInfo) {
                Button(updates.checking ? "Checking for updates…" : "Check for Updates…") {
                    updates.checkForUpdates()
                }
                .disabled(updates.checking)
            }

            CommandGroup(replacing: .newItem) {
                Button("New Product…") { model.beginNewProduct() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Chat") {
                    if let productID = model.route.productID { model.newChat(in: productID) }
                }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(model.route.productID == nil)
            }
            // Find belongs under Edit, beside the rest of the text commands, and the name "Find…"
            // belongs to it. ⌘K searches the whole app — every product, chat and report — and
            // while it was the only search in the app calling it "Find…" was fair enough. With a
            // real in-conversation find on ⌘F, two menu items of the same name meaning different
            // scopes is the defect; ⌘K is a way to somewhere else, so it says so.
            CommandGroup(after: .textEditing) {
                Divider()
                Button("Find…") {
                    model.findOpenRequest = UUID()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!model.conversationFindReachable)

                Button("Find Next") { model.findNextRequest = UUID() }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(!model.conversationFindReachable || !model.findBarOpen)

                Button("Find Previous") { model.findPreviousRequest = UUID() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(!model.conversationFindReachable || !model.findBarOpen)
            }

            CommandGroup(after: .sidebar) {
                Button("Go to…") { model.searchPresented = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Refresh") { model.refreshNow() }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Product Details") {
                    withAnimation(Motion.surface) { model.inspectorShown.toggle() }
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model.route.productID == nil)
                Button("Switch Appearance") { model.settings.appearance = model.settings.appearance.next }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
                Button("All Products") { model.openProducts() }
                    .keyboardShortcut("0", modifiers: .command)
                Button("Skills") { model.openSkills() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Back") { model.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!model.canGoBack)
                Button("Forward") { model.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!model.canGoForward)
                Divider()
                Button("Check Readiness…") { model.openPreflight() }
                SkillsWindowButton()
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .resolveMotionPreference()
                .preferredColorScheme(model.settings.appearance.colorScheme)
                .themedLocale(model.settings.interfaceLanguage)
        } label: {
            Image(systemName: model.nightModeActive ? "moon.stars.fill" : "moon.stars")
        }
        .menuBarExtraStyle(.window)

        Window("Skills & MCP", id: "skills") {
            SkillLibrary()
                .environment(model)
                .resolveMotionPreference()
                .frame(minWidth: 520, minHeight: 460)
                .preferredColorScheme(model.settings.appearance.colorScheme)
                .themedLocale(model.settings.interfaceLanguage)
        }
        .defaultSize(width: 620, height: 680)

        Settings {
            SettingsView()
                .environment(model)
                .resolveMotionPreference()
                .frame(width: 660, height: 620)
                .preferredColorScheme(model.settings.appearance.colorScheme)
                .themedLocale(model.settings.interfaceLanguage)
        }
    }
}

extension View {

    @ViewBuilder func themedLocale(_ language: AppLanguage) -> some View {
        if let id = language.localeIdentifier {
            environment(\.locale, Locale(identifier: id))
        } else {
            self
        }
    }
}

private struct SkillsWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open Skills & MCP") { openWindow(id: "skills") }
            .keyboardShortcut("k", modifiers: [.command, .shift])
    }
}
