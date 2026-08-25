import Foundation

/// A directory in the temporary directory, unique to one test.
///
/// Tests run in parallel and share a temporary directory, so the name has to
/// be unique per call rather than per suite.
func temporaryDirectory(_ prefix: String = "viv-tests") throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A file in the temporary directory holding exactly `contents`.
func temporaryFile(_ contents: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("viv-tests-\(UUID().uuidString)")
    try Data(contents.utf8).write(to: url)
    return url
}
