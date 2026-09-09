import Darwin
import Foundation

enum CredentialInputError: Error, LocalizedError {
    case descriptor, custody, io, timeout, frame

    var errorDescription: String? {
        switch self {
        case .descriptor: return "Credential input must use inherited descriptor 3."
        case .custody: return "Credential input is not an owned pipe or socket."
        case .io: return "Credential input could not be read."
        case .timeout: return "Credential input deadline expired."
        case .frame: return "Credential input frame is invalid."
        }
    }
}

// This is a parent-created private channel, not a caller-selected filesystem
// path. stdin remains available for PC NDJSON. Authenticate only after a whole
// frame and EOF; a crashed writer must not turn a partial password into a login.
enum CredentialInput {
    static let maximumBytes = 4096
    private static let deadlineNanoseconds: UInt64 = 5_000_000_000

    static func readInherited(fd: Int32) throws -> String {
        guard fd == 3 else { throw CredentialInputError.descriptor }
        defer { Darwin.close(fd) }

        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw CredentialInputError.custody }
        let type = metadata.st_mode & mode_t(S_IFMT)
        guard (type == mode_t(S_IFIFO) || type == mode_t(S_IFSOCK)),
              metadata.st_uid == geteuid(), getuid() == geteuid() else {
            throw CredentialInputError.custody
        }
        let descriptorFlags = fcntl(fd, F_GETFD)
        let statusFlags = fcntl(fd, F_GETFL)
        guard descriptorFlags >= 0, statusFlags >= 0,
              fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, statusFlags | O_NONBLOCK) == 0 else {
            throw CredentialInputError.io
        }

        let deadline = try nowNanoseconds() + deadlineNanoseconds
        var frame = Data()
        var chunk = [UInt8](repeating: 0, count: 512)
        // This clears temporary buffers only. The returned String is retained
        // by VNCConfiguration because ARD reconnect needs the same credential.
        defer {
            frame.resetBytes(in: 0..<frame.count)
            _ = chunk.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        }
        while true {
            let now = try nowNanoseconds()
            guard now < deadline else { throw CredentialInputError.timeout }
            let remainingMS = Int32((deadline - now + 999_999) / 1_000_000)
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let result = poll(&descriptor, 1, remainingMS)
            if result < 0 {
                if errno == EINTR { continue }
                throw CredentialInputError.io
            }
            if result == 0 { throw CredentialInputError.timeout }
            guard descriptor.revents & Int16(POLLERR | POLLNVAL) == 0 else {
                throw CredentialInputError.io
            }
            let capacity = min(chunk.count, maximumBytes + 5 - frame.count)
            let count = chunk.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress, capacity)
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw CredentialInputError.io
            }
            if count == 0 { break }
            frame.append(contentsOf: chunk.prefix(count))
            guard frame.count <= maximumBytes + 4 else { throw CredentialInputError.frame }
        }
        guard frame.count >= 4 else { throw CredentialInputError.frame }
        let length = frame.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= maximumBytes, frame.count == length + 4 else {
            throw CredentialInputError.frame
        }
        let payload = frame.dropFirst(4)
        guard !payload.contains(0), let password = String(data: payload, encoding: .utf8) else {
            throw CredentialInputError.frame
        }
        return password
    }

    private static func nowNanoseconds() throws -> UInt64 {
        var value = timespec()
        guard clock_gettime(CLOCK_MONOTONIC, &value) == 0 else { throw CredentialInputError.io }
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }
}
