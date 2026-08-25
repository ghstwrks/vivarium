import Foundation

/// The environment the test command runs with, and the two ways of supplying
/// it.
///
/// `viv.json`'s `env` records what a project always wants; `--env-file` carries
/// what one invocation needs and must not be committed — a CI token, a registry
/// password, a branch name. A file rather than repeated `--env NAME=value`
/// flags because a command line is readable by every other process on the host,
/// and the whole point of the second mechanism is the values that must not be.
///
/// The rules for a name live here rather than in either caller, so that a name
/// the manifest refuses is refused identically by a file.
enum GuestEnvironment {
    /// Names become `export` statements in the guest, so they have to be shell
    /// identifiers. The *values* are quoted and may contain anything.
    static func isUsableName(_ name: String) -> Bool {
        guard let first = name.first, !first.isNumber else { return false }
        return name.allSatisfy { $0 == "_" || ($0.isLetter && $0.isASCII) || ($0.isNumber && $0.isASCII) }
    }

    /// Whether Vivarium sets this name itself. `$VIV_ARTIFACTS` pointing
    /// somewhere other than the share would silently harvest nothing, so
    /// neither source may claim one of these.
    static func isReserved(_ name: String) -> Bool {
        GuestScripts.reservedEnvironmentNames.contains(name)
    }

    /// Reads a `NAME=value` file.
    ///
    /// Deliberately not a dotenv implementation: there is no quote stripping,
    /// no escape processing, no `export` prefix, and no interpolation, so the
    /// value is exactly the bytes after the first `=` to the end of the line.
    /// A CI system writing this file has already resolved its own quoting, and
    /// a second layer of it here would silently eat the outer quotes of a
    /// password that happens to start with one.
    ///
    /// Blank lines and lines whose first non-blank character is `#` are
    /// ignored, and a line may be indented. Nothing else is trimmed: `NAME =
    /// value` is refused, because the alternative is a parser that decides on
    /// the author's behalf whether those spaces were part of the value.
    ///
    /// A trailing carriage return is dropped, because a file written on one
    /// platform and read on another should not export a value ending in `\r`.
    static func read(envFile url: URL) throws -> [String: String] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw VivError(
                .bundlePreparation,
                "Cannot read the environment file at \(url.path).",
                underlying: error
            )
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw VivError(
                .bundlePreparation,
                "\(url.path) is not valid UTF-8."
            )
        }

        func refuse(_ line: Int, _ reason: String) -> VivError {
            VivError(
                .bundlePreparation,
                "\(url.path):\(line): \(reason). Each line is NAME=value, with the value "
                    + "taken literally to the end of the line; blank lines and lines "
                    + "beginning with # are ignored."
            )
        }

        var environment: [String: String] = [:]
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let number = index + 1
            var line = Substring(rawLine)
            if line.hasSuffix("\r") { line = line.dropLast() }
            let leading = line.drop(while: { $0 == " " || $0 == "\t" })
            if leading.isEmpty || leading.hasPrefix("#") { continue }

            guard let separator = leading.firstIndex(of: "=") else {
                throw refuse(number, "has no \"=\"")
            }
            // Neither half is trimmed. A file that means `NAME = value` has to
            // say which of the spaces belongs to the value, and a parser that
            // guessed here would be the same parser that ate the leading space
            // of a value that wanted one.
            let name = String(leading[leading.startIndex..<separator])
            let value = String(leading[leading.index(after: separator)...])

            guard isUsableName(name) else {
                throw refuse(
                    number,
                    "\"\(name)\" is not a usable environment variable name — names may "
                        + "contain ASCII letters, digits, and underscores, and may not begin "
                        + "with a digit"
                )
            }
            guard !isReserved(name) else {
                throw refuse(number, "\"\(name)\" is set by Vivarium and cannot be supplied here")
            }
            // A NUL truncates the string inside zsh rather than being rejected
            // by it, so a value that carries one would reach the guest as a
            // silently different value.
            guard !name.contains("\0"), !value.contains("\0") else {
                throw refuse(number, "\"\(name)\" contains a NUL byte")
            }
            guard environment[name] == nil else {
                throw refuse(
                    number,
                    "\"\(name)\" is assigned more than once — which of the two was meant is "
                        + "exactly the thing a file like this must not leave to chance"
                )
            }
            environment[name] = value
        }
        return environment
    }
}
