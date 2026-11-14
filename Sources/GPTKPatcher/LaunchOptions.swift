import Foundation

/// A game's launch options as Steam runs them: variables, then %command%, then arguments.
enum LaunchOptions {
    private static func pattern(_ name: String) -> NSRegularExpression {
        // Not part of a longer name, so D3DM_MAX_FPS leaves NOTPROTON_ENV_D3DM_MAX_FPS alone.
        try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: name) + #"=(\S*)[ \t]*"#)
    }

    static func value(of name: String, in options: String) -> String? {
        guard let match = pattern(name).firstMatch(in: options, range: NSRange(options.startIndex..., in: options)),
              let range = Range(match.range(at: 1), in: options) else { return nil }
        return String(options[range])
    }

    /// The options with the variable set, or removed for nil. Everything else is kept. The
    /// variable goes in front of the whole line, so options that chain commands with ; or && are
    /// not handled.
    static func setting(_ name: String, to value: String?, in options: String) -> String {
        let rest = pattern(name).stringByReplacingMatches(in: options, range: NSRange(options.startIndex..., in: options),
                                                          withTemplate: "").trimmingCharacters(in: .whitespaces)
        guard let value else { return rest == "%command%" ? "" : rest }
        if rest.range(of: "%command%", options: .caseInsensitive) != nil { return "\(name)=\(value) \(rest)" }
        return "\(name)=\(value) %command%" + (rest.isEmpty ? "" : " " + rest)
    }

    /// Adds an argument to the end, unless it is already there.
    static func adding(_ argument: String, to options: String) -> String {
        if options.range(of: argument, options: .caseInsensitive) != nil { return options }
        return options.isEmpty ? argument : options + " " + argument
    }

    /// The MoltenVK settings as NotProton takes them: it hands a game FOO from a
    /// NOTPROTON_ENV_FOO launch option.
    static var moltenVKVariables: [(name: String, value: String)] {
        GraphicsSettings.moltenVKVariables.map { ("NOTPROTON_ENV_" + $0.key, $0.value) }
    }

    /// What a game needs to use a swapped-in MoltenVK under NotProton: those settings and the
    /// game's own argument. Options that already have them come back unchanged.
    static func settingUpMoltenVK(in options: String, argument: String?) -> String {
        var options = options
        for variable in moltenVKVariables.reversed() {
            options = setting(variable.name, to: variable.value, in: options)
        }
        return argument.map { adding($0, to: options) } ?? options
    }
}

/// D3DMetal's frame rate cap as a launch option.
enum FrameCap {
    private static let variable = "D3DM_MAX_FPS"

    /// The usual rates, plus the one a game already has.
    static func choices(including current: Int) -> [Int] {
        Set([30, 40, 60, 120, 144] + (current > 0 ? [current] : [])).sorted()
    }

    static func current(in options: String) -> Int {
        LaunchOptions.value(of: variable, in: options).flatMap(Int.init) ?? 0
    }

    /// The options with the cap set, or removed for 0.
    static func apply(_ fps: Int, to options: String) -> String {
        LaunchOptions.setting(variable, to: fps > 0 ? String(fps) : nil, in: options)
    }
}
