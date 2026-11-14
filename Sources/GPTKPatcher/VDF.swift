import Foundation

/// Just enough of Valve's text format to read a value and to change one launch option without
/// disturbing the rest of the file.
enum VDF {
    private enum Token { case string(String, Range<String.Index>), open(String.Index), close(String.Index) }

    private static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        var i = text.startIndex
        while i < text.endIndex {
            switch text[i] {
            case "{": result.append(.open(i)); i = text.index(after: i)
            case "}": result.append(.close(i)); i = text.index(after: i)
            case "\"":
                let start = text.index(after: i)
                var j = start
                while j < text.endIndex, text[j] != "\"" {
                    j = text.index(j, offsetBy: text[j] == "\\" ? 2 : 1, limitedBy: text.endIndex) ?? text.endIndex
                }
                result.append(.string(String(text[start..<j]), start..<j))
                i = j < text.endIndex ? text.index(after: j) : j
            default: i = text.index(after: i)
            }
        }
        return result
    }

    private static func unescaped(_ raw: String) -> String {
        var out = "", escaped = false
        for character in raw {
            if escaped { out.append(character); escaped = false }
            else if character == "\\" { escaped = true }
            else { out.append(character) }
        }
        return out
    }

    /// Every value stored under `key`, at any depth.
    static func values(of key: String, in text: String) -> [String] {
        var found: [String] = []
        var pending: String?
        for token in tokens(text) {
            switch token {
            case .string(let value, _):
                if let name = pending {
                    if name.caseInsensitiveCompare(key) == .orderedSame { found.append(unescaped(value)) }
                    pending = nil
                } else { pending = value }
            case .open, .close: pending = nil
            }
        }
        return found
    }

    private struct Spot {
        var value: Range<String.Index>?
        var appEnd: String.Index?
        var appsEnd: String.Index?
    }

    private static func spot(for app: String, in text: String) -> Spot {
        let apps = ["userlocalconfigstore", "software", "valve", "steam", "apps"]
        var spot = Spot()
        var path: [String] = []
        var pending: String?
        for token in tokens(text) {
            switch token {
            case .string(let value, let range):
                if let name = pending {
                    if path == apps + [app], name.lowercased() == "launchoptions" { spot.value = range }
                    pending = nil
                } else { pending = value }
            case .open:
                path.append((pending ?? "").lowercased())
                pending = nil
            case .close(let index):
                if path == apps + [app] { spot.appEnd = index }
                if path == apps { spot.appsEnd = index }
                path = Array(path.dropLast())
                pending = nil
            }
        }
        return spot
    }

    static func launchOptions(for app: String, in text: String) -> String? {
        spot(for: app, in: text).value.map { unescaped(String(text[$0])) }
    }

    /// The file with that game's launch options replaced, or nil when it has no apps section.
    static func settingLaunchOptions(_ options: String, for app: String, in text: String) -> String? {
        let escaped = options.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let spot = spot(for: app, in: text)
        var text = text
        if let range = spot.value {
            text.replaceSubrange(range, with: escaped)
            return text
        }
        // A new line goes in above the closing brace, one level deeper than it.
        func insert(above brace: String.Index, _ lines: (String) -> String) {
            let lineStart = text[..<brace].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            text.insert(contentsOf: lines(String(text[lineStart..<brace]) + "\t"), at: lineStart)
        }
        if let end = spot.appEnd {
            insert(above: end) { "\($0)\"LaunchOptions\"\t\t\"\(escaped)\"\n" }
        } else if let end = spot.appsEnd {
            insert(above: end) { "\($0)\"\(app)\"\n\($0){\n\($0)\t\"LaunchOptions\"\t\t\"\(escaped)\"\n\($0)}\n" }
        } else {
            return nil
        }
        return text
    }
}
