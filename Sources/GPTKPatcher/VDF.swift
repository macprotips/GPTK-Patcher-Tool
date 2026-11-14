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
            if escaped {
                out.append(character == "n" ? "\n" : character == "t" ? "\t" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character)
            }
        }
        return out
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
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
        let apps = appsPath
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

    private static let appsPath = ["userlocalconfigstore", "software", "valve", "steam", "apps"]

    static func launchOptions(for app: String, in text: String) -> String? {
        spot(for: app, in: text).value.map { unescaped(String(text[$0])) }
    }

    /// Every game's launch options, by app id, read in one pass.
    static func launchOptions(in text: String) -> [String: String] {
        var found: [String: String] = [:]
        var path: [String] = []
        var pending: String?
        for token in tokens(text) {
            switch token {
            case .string(let value, _):
                if let name = pending {
                    if path.count == appsPath.count + 1, Array(path.dropLast()) == appsPath, name.lowercased() == "launchoptions" {
                        found[path[appsPath.count]] = unescaped(value)
                    }
                    pending = nil
                } else { pending = value }
            case .open:
                path.append((pending ?? "").lowercased())
                pending = nil
            case .close:
                path = Array(path.dropLast())
                pending = nil
            }
        }
        return found
    }

    /// The file with that game's launch options replaced. Nil when it has no apps section, or
    /// when the result does not read back as intended, so a file this does not understand is
    /// never written.
    static func settingLaunchOptions(_ options: String, for app: String, in text: String) -> String? {
        let value = escaped(options)
        let spot = spot(for: app, in: text)
        var edited = text
        // A new line goes in above the closing brace, one level deeper than it, in the file's
        // own line endings.
        func insert(above brace: String.Index, _ lines: (_ indent: String, _ newline: String) -> String) {
            var start = brace
            while start > edited.startIndex, " \t".contains(edited[edited.index(before: start)]) {
                start = edited.index(before: start)
            }
            let indent = String(edited[start..<brace])
            let newline = edited.contains("\r\n") ? "\r\n" : "\n"
            let ownLine = start == edited.startIndex || edited[edited.index(before: start)].isNewline
            edited.insert(contentsOf: (ownLine ? "" : newline) + lines(indent + "\t", newline), at: start)
        }
        if let range = spot.value {
            edited.replaceSubrange(range, with: value)
        } else if let end = spot.appEnd {
            insert(above: end) { "\($0)\"LaunchOptions\"\t\t\"\(value)\"\($1)" }
        } else if let end = spot.appsEnd {
            insert(above: end) { "\($0)\"\(app)\"\($1)\($0){\($1)\($0)\t\"LaunchOptions\"\t\t\"\(value)\"\($1)\($0)}\($1)" }
        } else {
            return nil
        }
        let before = tokens(text), after = tokens(edited)
        func braces(_ list: [Token]) -> Int {
            list.reduce(0) { if case .string = $1 { return $0 } else { return $0 + 1 } }
        }
        guard launchOptions(for: app, in: edited) == options, braces(after) - braces(before) == (spot.appEnd == nil && spot.value == nil ? 2 : 0)
        else { return nil }
        return edited
    }
}
