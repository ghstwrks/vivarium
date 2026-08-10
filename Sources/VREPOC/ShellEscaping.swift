import Foundation

enum ShellEscaping {
    /// Wraps a value so a POSIX shell reads it as one literal word.
    ///
    /// Single quotes suppress every form of expansion, so the only character
    /// needing care is the single quote itself: the string is closed, an
    /// escaped quote is emitted, and the string reopened.
    static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Wraps a whole script for remote execution over SSH.
    ///
    /// The script is base64-encoded rather than quoted through two shells. The
    /// SSH client concatenates its command arguments and hands the result to
    /// the remote login shell, so a quoted-in-place script has to survive local
    /// quoting, SSH's own concatenation, and the remote shell — three chances
    /// to get it wrong. Base64 is alphanumeric plus `+/=`, so one layer of
    /// single quotes is provably sufficient.
    static func base64RemoteCommand(script: String, shell: String = "/bin/zsh") -> String {
        let encoded = Data(script.utf8).base64EncodedString()
        return "printf %s \(singleQuoted(encoded)) | /usr/bin/base64 -d | \(shell) -s"
    }
}
