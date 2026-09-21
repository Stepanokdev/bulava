import Foundation

nonisolated struct ReportManifest: Sendable, Codable, Equatable {
    enum Format: String, Sendable, Codable { case photos, video, notes }

    nonisolated struct Item: Sendable, Codable, Equatable {
        var caption: String?
        var before: String?
        var after: String?
    }

    var format: Format
    var language: String?
    var title: String?
    var summary: String?
    var items: [Item]?
    var video: String?
    var poster: String?

    var body: String?

    struct Section: Sendable, Codable, Equatable {

        enum Status: String, Sendable, Codable {
            case closed, partial, notClosed = "not_closed", blocked, notApplicable = "n/a", unknown

            var label: String {
                switch self {
                case .closed:        return String(localized: "Closed")
                case .partial:       return String(localized: "Partly")
                case .notClosed:     return String(localized: "Not closed")
                case .blocked:       return String(localized: "Blocked")
                case .notApplicable: return String(localized: "Not applicable")
                case .unknown:       return String(localized: "No verdict")
                }
            }
            var cssClass: String {
                switch self {
                case .closed: return "closed"
                case .partial: return "partial"
                case .notClosed: return "notclosed"
                case .blocked: return "blocked"
                case .notApplicable: return "na"
                case .unknown: return "unknown"
                }
            }
        }

        var ref: String?
        var title: String?
        var status: Status = .unknown

        var body: String?

        var items: [Item]?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ref = try? c.decodeIfPresent(String.self, forKey: .ref)
            title = try? c.decodeIfPresent(String.self, forKey: .title)
            body = try? c.decodeIfPresent(String.self, forKey: .body)
            items = try? c.decodeIfPresent([Item].self, forKey: .items)
            let raw = ((try? c.decodeIfPresent(String.self, forKey: .status)) ?? "")?
                .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            status = Status(rawValue: raw) ?? Self.spoken(raw)
        }

        static func spoken(_ raw: String) -> Status {
            switch raw {
            case let s where s.contains("частков") || s.contains("partial"): return .partial
            case let s where s.contains("заблок") || s.contains("block"): return .blocked
            case let s where s.contains("не закри") || s.contains("не зробл"): return .notClosed
            case let s where s.contains("не застос") || s.contains("n/a") || s.contains("not app"): return .notApplicable
            case let s where s.contains("закри") || s.contains("зробл") || s.contains("done") || s.contains("clos"): return .closed
            default: return .unknown
            }
        }
    }

    var sections: [Section]?

    var attention: [String]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        items = try c.decodeIfPresent([Item].self, forKey: .items)
        video = try c.decodeIfPresent(String.self, forKey: .video)
        poster = try c.decodeIfPresent(String.self, forKey: .poster)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        sections = try? c.decodeIfPresent([Section].self, forKey: .sections)

        if let many = try? c.decodeIfPresent([String].self, forKey: .attention) {
            attention = many
        } else if let one = try? c.decodeIfPresent(String.self, forKey: .attention), !one.isEmpty {
            attention = [one]
        }
        if let f = try c.decodeIfPresent(Format.self, forKey: .format) {
            format = f
        } else if video?.isEmpty == false {
            format = .video
        } else if items?.isEmpty == false {
            format = .photos
        } else {
            format = .notes
        }
    }

    var hasContent: Bool {
        if !(sections ?? []).isEmpty { return true }
        if !(body ?? "").isEmpty { return true }
        if !(video ?? "").isEmpty { return true }
        if !(items ?? []).isEmpty { return true }
        return !(summary ?? "").isEmpty
    }
}
