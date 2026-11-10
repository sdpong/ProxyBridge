import Foundation
import Darwin

// One instance of the app at a time.
//
// Two launchers can start the app at the same moment: the login item of
// macOS and the launch agent that waits for the network. Two apps would
// write over each other's settings, and both of them would talk to the
// tunnel - which is a tunnel that is half of one thing and half of another.
//
// The lock is a lock of the system: the kernel gives it back when the
// process is gone, so an app that was taken down does not leave it behind.
enum InstanceLock {
    /// the file that holds the lock
    ///
    /// The home of the person can be given, so that the lock of a test is
    /// not the lock of the app that is running on the machine.
    private static func lockFileURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        return UpstreamWait.supportFolderURL(home: home).appendingPathComponent("app.lock")
    }

    /// the descriptor of the lock. it stays open for the life of the app.
    private static var descriptor: Int32 = -1

    /// Takes the lock, or says that another instance has it.
    @discardableResult
    static func acquire(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let manager = FileManager.default
        try? manager.createDirectory(at: UpstreamWait.supportFolderURL(home: home),
                                    withIntermediateDirectories: true)
        let path = lockFileURL(home: home).path
        let handle = path.withCString { pointer in
            open(pointer, O_CREAT | O_RDWR, 0o644)
        }
        if handle < 0 {
            // the file cannot be opened. The app runs without the lock
            // rather than not at all - a machine where the file cannot be
            // made is a machine where the person cannot use the app either.
            return true
        }
        if flock(handle, LOCK_EX | LOCK_NB) != 0 {
            close(handle)
            return false
        }
        descriptor = handle
        // the number of the process is written into the file, so that the
        // instance that comes second can bring the first one to the front
        let text = "\(getpid())\n"
        ftruncate(handle, 0)
        if let data = text.data(using: .utf8) {
            data.withUnsafeBytes { raw in
                _ = write(handle, raw.baseAddress, raw.count)
            }
        }
        return true
    }

    /// The instance that holds the lock, when there is one.
    static func otherInstance(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> pid_t? {
        let path = lockFileURL(home: home).path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Int(trimmed), number > 0, number != getpid() else { return nil }
        let pid = pid_t(number)
        // the number is of a process that is there, and not of one that is
        // remembered
        guard kill(pid, 0) == 0 else { return nil }
        return pid
    }
}
