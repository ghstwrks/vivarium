import Foundation

/// A project's `viv.json`.
///
/// Every field is optional, and every one of them can be overridden on the
/// command line: the manifest records what a project usually wants, not what
/// this invocation must do.
///
/// JSON rather than YAML or TOML because `Codable` reads it with no
/// dependency, and because a project's test command is not a thing worth
/// inventing a syntax for.
struct VivManifest: Sendable {
    /// A human label for the project. Reported, never used as a path.
    var name: String?
    /// The test command, run by the guest's shell in the copied code
    /// directory.
    var test: String?
    /// Globs, relative to the guest workdir, whose matches are harvested.
    var artifacts: [String]
    /// The test command's budget, in seconds.
    var timeout: Int?
    /// Extra environment for the test command.
    var environment: [String: String]

    static let filename = "viv.json"

    /// Decoded by hand rather than through a synthesised `Codable` because
    /// `Codable` ignores keys it does not recognise. A manifest whose
    /// `artefacts` key is silently dropped is a run that quietly harvests
    /// nothing and reports success, which is a far more expensive mistake than
    /// being told about the typo.
    static func read(from url: URL) throws -> VivManifest {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw VivError(
                .bundlePreparation,
                "Cannot read the manifest at \(url.path).",
                underlying: error
            )
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw VivError(
                .bundlePreparation,
                "\(url.path) is not valid JSON.",
                underlying: error
            )
        }
        guard let fields = object as? [String: Any] else {
            throw VivError(
                .bundlePreparation,
                "\(url.path) must contain a JSON object, for example:\n"
                    + "  { \"test\": \"swift test\", \"artifacts\": [\"logs/**\"] }"
            )
        }

        let known: Set<String> = ["name", "test", "artifacts", "timeout", "env"]
        let unknown = fields.keys.filter { !known.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw VivError(
                .bundlePreparation,
                "\(url.path) has \(unknown.count == 1 ? "an unrecognised key" : "unrecognised keys"): "
                    + unknown.map { "\"\($0)\"" }.joined(separator: ", ")
                    + ". Known keys are: " + known.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
                    + "."
            )
        }

        var manifest = VivManifest(artifacts: [], environment: [:])
        manifest.name = try string(fields["name"], key: "name", in: url)
        manifest.test = try string(fields["test"], key: "test", in: url)

        if let raw = fields["artifacts"] {
            guard let patterns = raw as? [String] else {
                throw VivError(
                    .bundlePreparation,
                    "\(url.path): \"artifacts\" must be an array of glob strings, "
                        + "for example [\"logs/**\", \"results.xml\"]."
                )
            }
            manifest.artifacts = try patterns.map { try validated(pattern: $0, in: url) }
        }

        if let raw = fields["timeout"] {
            guard let seconds = raw as? Int, seconds > 0 else {
                throw VivError(
                    .bundlePreparation,
                    "\(url.path): \"timeout\" must be a positive whole number of seconds."
                )
            }
            manifest.timeout = seconds
        }

        if let raw = fields["env"] {
            guard let environment = raw as? [String: String] else {
                throw VivError(
                    .bundlePreparation,
                    "\(url.path): \"env\" must be an object mapping names to string values, "
                        + "for example { \"CI\": \"1\" }."
                )
            }
            for name in environment.keys.sorted() {
                try validate(environmentName: name, in: url)
            }
            manifest.environment = environment
        }

        return manifest
    }

    private static func string(_ raw: Any?, key: String, in url: URL) throws -> String? {
        guard let raw else { return nil }
        guard let value = raw as? String else {
            throw VivError(.bundlePreparation, "\(url.path): \"\(key)\" must be a string.")
        }
        return value
    }

    /// Artifact globs are expanded by the guest's shell, relative to the
    /// workdir, and their matches are copied into `$VIV_ARTIFACTS` under the
    /// same relative path. Anything that could name a path outside the workdir,
    /// or split into two shell words, is refused here rather than producing a
    /// confusing harvest.
    private static func validated(pattern: String, in url: URL) throws -> String {
        func refuse(_ reason: String) -> VivError {
            VivError(
                .bundlePreparation,
                "\(url.path): the artifact pattern \"\(pattern)\" \(reason). Patterns are "
                    + "relative to the directory the test command runs in, for example "
                    + "\"logs/**\" or \"build/results.xml\"."
            )
        }
        guard !pattern.isEmpty else { throw refuse("is empty") }
        guard !pattern.hasPrefix("/") else { throw refuse("is an absolute path") }
        guard !pattern.hasPrefix("~") else { throw refuse("starts with a home-directory reference") }
        guard !pattern.contains("\n") else { throw refuse("contains a line break") }
        guard !pattern.split(separator: "/").contains("..") else {
            throw refuse("escapes the workdir with \"..\"")
        }
        guard pattern != GuestTestScript.artifactPatternDelimiter else {
            throw refuse("collides with the delimiter Vivarium uses to pass patterns to the guest")
        }
        return pattern
    }

    /// The names become `export` statements in the guest, so they have to be
    /// shell identifiers. The *values* are quoted and may contain anything.
    private static func validate(environmentName name: String, in url: URL) throws {
        let valid = !name.isEmpty
            && !name.first!.isNumber
            && name.allSatisfy { $0 == "_" || $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII }
        guard valid else {
            throw VivError(
                .bundlePreparation,
                "\(url.path): \"\(name)\" is not a usable environment variable name. Names may "
                    + "contain ASCII letters, digits, and underscores, and may not begin with a digit."
            )
        }
        guard !GuestTestScript.reservedEnvironmentNames.contains(name) else {
            throw VivError(
                .bundlePreparation,
                "\(url.path): \"\(name)\" is set by Vivarium and cannot be overridden by \"env\"."
            )
        }
    }
}
