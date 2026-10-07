import Foundation

/// Which phone app is the newest, read from bulava.app for the phones paired here.
///
/// The phone opens nothing on the internet — its one connection is this Mac, and its settings say
/// so in as many words — so it cannot look for its own updates. The Mac can: it already asks
/// bulava.app about its own (Sparkle's feed). The release publishes `mobile/version.json` beside the
/// APK, the Mac reads it when a phone comes to the door and at most every six hours after that,
/// and passes it on as it was: in every `home`, so a phone offers an update it does not have yet,
/// and in a refusal, so a phone turned away as too old can say which version to get and where.
///
/// Kept on disk as it was last read. A Mac that wakes up offline, or a phone refused in the first
/// second after launch, is still told what was known yesterday rather than nothing.
extension MobileLink {

    /// Reads the manifest unless it was read in the last six hours. Never from the XCTest host,
    /// unless a test pointed it somewhere (`phoneAppsSource`).
    func checkPhoneApps() {
        guard !phoneAppsInFlight else { return }
        guard let source = phoneAppsSource ?? (Self.isTestHost ? nil : LinkProtocol.phoneAppsManifest) else { return }
        if let at = phoneAppsCheckedAt, Date().timeIntervalSince(at) < 6 * 3600 { return }
        phoneAppsInFlight = true
        Task { [weak self] in
            guard let self else { return }
            let request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            let answer = try? await self.pushSession.data(for: request)
            self.phoneAppsInFlight = false
            guard (answer?.1 as? HTTPURLResponse)?.statusCode == 200, let data = answer?.0,
                  let read = Self.decodePhoneApps(data) else { return }
            self.phoneAppsCheckedAt = Date()
            self.adoptPhoneApps(read, save: true)
        }
    }

    /// What a manifest says, or nil when it says nothing usable. An entry with no version, no build
    /// or an address that is not https is left out rather than passed on: a phone shown "update to
    /// version ''" would have been better shown nothing.
    nonisolated static func decodePhoneApps(_ data: Data) -> PhoneAppsDTO? {
        guard let read = try? JSONDecoder().decode(PhoneAppsDTO.self, from: data) else { return nil }
        func usable(_ app: PhoneAppDTO?) -> PhoneAppDTO? {
            guard let app, !app.version.isEmpty, app.build > 0, app.url.hasPrefix("https://") else { return nil }
            return app
        }
        let clean = PhoneAppsDTO(android: usable(read.android), ios: usable(read.ios))
        return clean.android == nil && clean.ios == nil ? nil : clean
    }

    func adoptPhoneApps(_ apps: PhoneAppsDTO, save: Bool) {
        guard apps != phoneApps else { return }
        phoneApps = apps
        if save, let data = try? JSONEncoder().encode(apps) {
            try? FileManager.default.createDirectory(at: phoneAppsFile.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: phoneAppsFile, options: [.atomic])
        }
        scheduleRefresh()
    }

    /// The copy from the last time it was read, at launch.
    func loadPhoneApps() {
        guard phoneApps == nil, let data = try? Data(contentsOf: phoneAppsFile),
              let apps = Self.decodePhoneApps(data) else { return }
        phoneApps = apps
    }
}
