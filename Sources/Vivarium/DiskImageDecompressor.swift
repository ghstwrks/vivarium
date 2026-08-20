import Compression
import CryptoKit
import Foundation

enum DiskImageCompression: Sendable {
    case none
    case xz

    static func detect(at url: URL, stage: VivStage) throws -> DiskImageCompression {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw VivError(stage, "Cannot open \(url.path).")
        }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 6)) ?? Data()
        return magic == Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) ? .xz : .none
    }
}

enum DiskImageDecompressor {
    struct Result: Sendable {
        let byteCount: Int64
        let sha256: String
    }

    static func decompress(
        from source: URL,
        to destination: URL,
        stage: VivStage,
        onProgress: (Int64) -> Void = { _ in }
    ) throws -> Result {
        let input = open(source.path, O_RDONLY)
        guard input != -1 else {
            throw VivError(stage, "Cannot open \(source.path): \(String(cString: strerror(errno))).")
        }
        defer { close(input) }

        let output = open(destination.path, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        guard output != -1 else {
            throw VivError(
                stage,
                "Cannot create \(destination.path): \(String(cString: strerror(errno)))."
            )
        }
        defer { close(output) }

        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: -1)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: -1)!,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA)
            == COMPRESSION_STATUS_OK else {
            throw VivError(stage, "Could not start an xz decoder.")
        }
        defer { compression_stream_destroy(&stream) }

        let inputCapacity = 4 << 20
        let outputCapacity = 8 << 20
        let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputCapacity)
        let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: outputCapacity)
        defer {
            inputBuffer.deallocate()
            outputBuffer.deallocate()
        }

        var hasher = SHA256()
        var written: Int64 = 0
        var lastReported: Int64 = 0
        var reachedInputEnd = false
        var flags: Int32 = 0

        while true {
            if stream.src_size == 0 && !reachedInputEnd {
                let count = read(input, inputBuffer, inputCapacity)
                guard count >= 0 else {
                    throw VivError(
                        stage,
                        "Reading \(source.path) failed: \(String(cString: strerror(errno)))."
                    )
                }
                if count == 0 {
                    reachedInputEnd = true
                    flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                } else {
                    stream.src_ptr = UnsafePointer(inputBuffer)
                    stream.src_size = count
                }
            }

            stream.dst_ptr = outputBuffer
            stream.dst_size = outputCapacity
            let status = compression_stream_process(&stream, flags)
            let produced = outputCapacity - stream.dst_size

            if produced > 0 {
                hasher.update(
                    bufferPointer: UnsafeRawBufferPointer(start: outputBuffer, count: produced)
                )
                var offset = 0
                while offset < produced {
                    let count = write(output, outputBuffer + offset, produced - offset)
                    guard count > 0 else {
                        throw VivError(
                            stage,
                            "Writing \(destination.path) failed: "
                                + "\(String(cString: strerror(errno)))."
                        )
                    }
                    offset += count
                }
                written += Int64(produced)
                if written - lastReported >= 512 << 20 {
                    lastReported = written
                    onProgress(written)
                }
            }

            switch status {
            case COMPRESSION_STATUS_OK:
                continue
            case COMPRESSION_STATUS_END:
                guard stream.src_size == 0, isAtEnd(input) else {
                    throw VivError(
                        stage,
                        "\(source.path) holds more than one xz stream, and macOS's decoder "
                            + "reads only the first. Decompressing it here would produce a disk "
                            + "image that is silently a prefix of the real one. Decompress it "
                            + "with `xz -d` and pass the result to --image instead."
                    )
                }
                return Result(byteCount: written, sha256: hasher.finalize().hexadecimal)
            default:
                throw VivError(
                    stage,
                    "\(source.path) is not a readable xz stream; the decoder failed after "
                        + "\(written.formattedByteCount)."
                )
            }
        }
    }

    private static func isAtEnd(_ descriptor: Int32) -> Bool {
        var byte: UInt8 = 0
        return read(descriptor, &byte, 1) == 0
    }
}

extension SHA256.Digest {
    var hexadecimal: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
