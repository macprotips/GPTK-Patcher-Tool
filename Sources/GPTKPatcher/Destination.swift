import Foundation

/// What is being patched: CrossOver for its own bottles, or the CrossOver NotProton copies its
/// runner from. Asked once and remembered.
enum Destination: String, CaseIterable, Identifiable, Sendable {
    case crossOver
    case notProton

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crossOver: return "CrossOver"
        case .notProton: return "NotProton"
        }
    }

    /// The line under the title in the question.
    var subtitle: String {
        switch self {
        case .crossOver: return "For games in CrossOver bottles"
        case .notProton: return "For Steam games through NotProton"
        }
    }

    var symbol: String {
        switch self {
        case .crossOver: return "wineglass"
        case .notProton: return "gamecontroller"
        }
    }

    private static let key = "destination"

    /// The answer given last time, or nil when it has never been asked.
    static var remembered: Destination? {
        UserDefaults.standard.string(forKey: key).flatMap(Destination.init(rawValue:))
    }

    static func remember(_ destination: Destination) {
        UserDefaults.standard.set(destination.rawValue, forKey: key)
    }
}
