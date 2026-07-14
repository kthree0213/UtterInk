import Darwin
import Foundation

enum SecureFileReader {
    static func readRegularFile(
        at url: URL,
        limit: Int,
        displayName: String
    ) throws -> Data {
        guard let data = try readRegularFileIfPresent(
            at: url,
            limit: limit,
            displayName: displayName
        ) else {
            throw IdentityExporterError.unreadableInput(displayName)
        }
        return data
    }

    static func readRegularFileIfPresent(
        at url: URL,
        limit: Int,
        displayName: String
    ) throws -> Data? {
        guard limit >= 0, limit < Int.max else {
            throw IdentityExporterError.invalidInput("invalid identity input size boundary")
        }

        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        if descriptor < 0 {
            if errno == ENOENT {
                return nil
            }
            throw IdentityExporterError.unreadableInput(displayName)
        }
        defer { Darwin.close(descriptor) }

        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              UInt64(info.st_size) <= UInt64(limit) else {
            throw IdentityExporterError.unreadableInput(displayName)
        }

        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, limit + 1))
        if buffer.isEmpty {
            buffer = [0]
        }

        while data.count <= limit {
            let remaining = limit + 1 - data.count
            let requestCount = min(buffer.count, remaining)
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, requestCount)
            }
            if bytesRead < 0 {
                if errno == EINTR {
                    continue
                }
                throw IdentityExporterError.unreadableInput(displayName)
            }
            if bytesRead == 0 {
                break
            }
            data.append(contentsOf: buffer[0..<bytesRead])
        }

        guard data.count <= limit else {
            throw IdentityExporterError.invalidInput("identity input exceeds its size boundary")
        }
        return data
    }
}
