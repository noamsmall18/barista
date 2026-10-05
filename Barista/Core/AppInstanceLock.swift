import Foundation
import Darwin

/// One native menu-bar process per flavor, even when another build copy is opened.
/// The research helper has a separate lock and lifetime.
final class AppInstanceLock {
    private let descriptor: Int32

    init?(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(directory.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(fd)
            if code == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = fd
    }

    deinit { Darwin.close(descriptor) }
}
