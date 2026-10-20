import Foundation

/// Where the guest writes the files that Safari's MCP server returns, and
/// where the same directory appears on the host.
struct MCPPathMapping: Sendable {
    /// The artifacts directory as the guest sees it.
    static let defaultGuestArtifactsDirectory = "/Volumes/My Shared Files/artifacts"

    /// Neither directory carries a trailing slash.
    let guestArtifactsDirectory: String
    let hostArtifactsDirectory: String

    init(guestArtifactsDirectory: String = Self.defaultGuestArtifactsDirectory, hostArtifactsDirectory: String) {
        self.guestArtifactsDirectory = Self.trimmingTrailingSlashes(guestArtifactsDirectory)
        self.hostArtifactsDirectory = Self.trimmingTrailingSlashes(hostArtifactsDirectory)
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }
}

/// A JSON-RPC request identifier. The specification allows a string or an
/// integer; anything else is never matched.
enum JSONRPCID: Hashable, Sendable {
    case int(Int)
    case string(String)
}

/// A tool call whose result file the guest could not write to the share.
struct ShareWriteDenial: Sendable {
    let requestID: JSONRPCID
    /// The request exactly as it was forwarded to the server, `savePath`
    /// included, so sending it again repeats the same write.
    let originalRequest: Data
}

/// Rewrites the JSON-RPC frames of a Safari MCP session as they cross the
/// host/guest boundary.
///
/// Toward the server, a `screenshot` or `get_page_content` call without a
/// `savePath` is given one inside the guest artifacts directory, so the file
/// lands on the share instead of in a guest temporary directory the host
/// cannot see. Toward the client, guest artifact paths in result text become
/// host paths, provided they stay inside the host artifacts directory.
///
/// A frame that needs no change is returned byte for byte. A frame that does is
/// re-serialised with sorted keys, so its key order and number formatting may
/// differ from what the sender wrote. Frames that are not JSON objects pass
/// through untouched.
///
/// Safe to call from two threads at once; the client and server directions
/// are expected to run on one thread each.
final class MCPFrameRewriter: @unchecked Sendable {
    private enum SaveTool: String {
        case screenshot
        case getPageContent = "get_page_content"
    }

    /// Part of the server's message when the share refuses the write.
    private static let permissionFailureText = "permission to save the file"

    private let mapping: MCPPathMapping
    private let lock = NSLock()
    private var nextFileNumber = 1
    private var pendingSaves: [JSONRPCID: Data] = [:]

    init(mapping: MCPPathMapping) {
        self.mapping = mapping
    }

    /// Prepares one frame, without its line terminator, on its way to the server.
    func clientToServer(_ line: Data) -> Data {
        guard var message = Self.parseObject(line),
              message["method"] as? String == "tools/call",
              var params = message["params"] as? [String: Any],
              let name = params["name"] as? String,
              let tool = SaveTool(rawValue: name)
        else { return line }

        var arguments: [String: Any]
        switch params["arguments"] {
        case nil: arguments = [:]
        case let given as [String: Any]: arguments = given
        default: return line
        }

        var forwarded = line
        let writesToShare: Bool
        if let chosen = arguments["savePath"] {
            writesToShare = (chosen as? String)?.hasPrefix(mapping.guestArtifactsDirectory + "/") == true
        } else {
            arguments["savePath"] = savePath(for: tool, format: arguments["format"] as? String)
            params["arguments"] = arguments
            message["params"] = params
            guard let rewritten = Self.serialise(message) else { return line }
            forwarded = rewritten
            writesToShare = true
        }

        if writesToShare, let id = Self.requestID(of: message) {
            lock.lock()
            pendingSaves[id] = forwarded
            lock.unlock()
        }
        return forwarded
    }

    /// Prepares one frame, without its line terminator, on its way to the
    /// client. `shareWriteDenied` is set when the frame answers a save request
    /// that failed because the share refused the write.
    func serverToClient(_ line: Data) -> (frame: Data, shareWriteDenied: ShareWriteDenial?) {
        guard var message = Self.parseObject(line) else { return (line, nil) }

        let id = Self.requestID(of: message)
        let request: Data?
        if let id {
            lock.lock()
            request = pendingSaves.removeValue(forKey: id)
            lock.unlock()
        } else {
            request = nil
        }

        guard var result = message["result"] as? [String: Any],
              var content = result["content"] as? [Any]
        else { return (line, nil) }

        var changed = false
        var permissionDenied = false
        for index in content.indices {
            guard var item = content[index] as? [String: Any], let text = item["text"] as? String else { continue }
            let hostText = hostPaths(in: text)
            if hostText != text {
                item["text"] = hostText
                content[index] = item
                changed = true
            }
            if text.contains(Self.permissionFailureText) { permissionDenied = true }
        }

        var denial: ShareWriteDenial?
        if permissionDenied, result["isError"] as? Bool == true, let id, let request {
            denial = ShareWriteDenial(requestID: id, originalRequest: request)
        }
        guard changed else { return (line, denial) }

        result["content"] = content
        message["result"] = result
        return (Self.serialise(message) ?? line, denial)
    }

    /// Replaces each guest artifact path in `text` with its host path.
    ///
    /// The guest chooses what the server reports, so a path is only rewritten
    /// when it resolves to a regular file inside the host artifacts directory;
    /// any other path is left as the guest wrote it.
    private func hostPaths(in text: String) -> String {
        let guestPrefix = mapping.guestArtifactsDirectory + "/"
        var output = ""
        var cursor = text.startIndex
        while let match = text.range(of: guestPrefix, range: cursor..<text.endIndex) {
            output += text[cursor..<match.lowerBound]
            let end = text[match.upperBound...].firstIndex(where: Self.endsPath) ?? text.endIndex
            let relative = text[match.upperBound..<end]
            if let host = hostPath(forRelative: String(relative)) {
                output += host
            } else {
                output += text[match.lowerBound..<end]
            }
            cursor = end
        }
        output += text[cursor...]
        return output
    }

    private static func endsPath(_ character: Character) -> Bool {
        character.isWhitespace || "'\"`\u{2018}\u{2019}\u{201C}\u{201D}".contains(character)
    }

    private func hostPath(forRelative relative: String) -> String? {
        let directory = URL(fileURLWithPath: mapping.hostArtifactsDirectory).standardizedFileURL.path
        let candidate = URL(fileURLWithPath: mapping.hostArtifactsDirectory + "/" + relative)
        guard candidate.standardizedFileURL.path.hasPrefix(directory + "/") else { return nil }

        var status = stat()
        if lstat(candidate.path, &status) == 0 {
            guard status.st_mode & S_IFMT == S_IFREG else { return nil }
            let resolvedDirectory = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
            guard candidate.resolvingSymlinksInPath().path.hasPrefix(resolvedDirectory + "/") else { return nil }
        } else if errno != ENOENT && errno != ENOTDIR {
            return nil
        }
        return mapping.hostArtifactsDirectory + "/" + relative
    }

    private func savePath(for tool: SaveTool, format: String?) -> String {
        lock.lock()
        let number = nextFileNumber
        nextFileNumber += 1
        lock.unlock()

        let filename: String
        switch tool {
        case .screenshot:
            filename = "screenshot-\(number).png"
        case .getPageContent:
            let fileExtension: String
            switch format {
            case "markdown": fileExtension = "md"
            case "json": fileExtension = "json"
            case "html": fileExtension = "html"
            default: fileExtension = "txt"
            }
            filename = "page-content-\(number).\(fileExtension)"
        }
        return mapping.guestArtifactsDirectory + "/" + filename
    }

    private static func parseObject(_ line: Data) -> [String: Any]? {
        guard line.first(where: { $0 != 0x20 && $0 != 0x09 }) == UInt8(ascii: "{") else { return nil }
        return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    private static func serialise(_ message: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func requestID(of message: [String: Any]) -> JSONRPCID? {
        switch message["id"] {
        case let string as String:
            return .string(string)
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            return Double(number.intValue) == number.doubleValue ? .int(number.intValue) : nil
        default:
            return nil
        }
    }
}
