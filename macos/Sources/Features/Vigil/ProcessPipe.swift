import Darwin
import Foundation

/// Process dup2s the intended pipe end onto stdio. Every other exec must
/// drop both original ends, so unrelated children cannot extend its lifetime
/// (the ssh streams of VigilRemote).
enum ProcessPipe {
    static func make() throws -> Pipe {
        let pipe = Pipe()
        for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
            let fd = handle.fileDescriptor
            let flags = fcntl(fd, F_GETFD)
            guard flags >= 0, fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0 else {
                let code = errno
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
        }
        return pipe
    }
}
