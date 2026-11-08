import Foundation
import Darwin

// A running process, as the process picker shows it.
//
// The app sandbox blocks proc_listpids and refuses to spawn /bin/ps, so the
// list comes from sysctl(KERN_PROC_ALL), which the sandbox does allow. The
// full path of every process can be read with proc_pidpath, and the owner
// with proc_pidinfo, both of which are allowed as well.
struct RunningProcess: Identifiable, Equatable {
    let pid: Int32
    let name: String        // the executable name, for example "Google Chrome"
    let path: String        // the full path, empty when it cannot be read
    let bundleId: String?   // the bundle id, for a process inside an app bundle
    let uid: UInt32

    var id: Int32 { pid }

    // what a rule matches on. the matcher compares the pattern against the
    // bundle id and against the executable name, and a pattern with a slash in
    // it is compared against the full path.
    var ruleValueByName: String { name }
    var ruleValueByBundleId: String { bundleId ?? name }
    var ruleValueByPath: String { path.isEmpty ? name : path }

    var displayPath: String { path.isEmpty ? "-" : path }
}

enum ProcessEnumerator {
    // every process on the machine, sorted by name so the list is stable
    static func all() -> [RunningProcess] {
        let raw = readKernelProcessTable()
        var out: [RunningProcess] = []
        out.reserveCapacity(raw.count)
        for entry in raw {
            guard entry.pid > 0 else { continue }
            let path = readPath(entry.pid)
            let name = path.isEmpty ? entry.shortName : (path as NSString).lastPathComponent
            guard !name.isEmpty else { continue }
            out.append(RunningProcess(
                pid: entry.pid,
                name: name,
                path: path,
                bundleId: bundleId(forProcessPath: path),
                uid: readOwner(entry.pid) ?? entry.uid
            ))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // the processes of one user. other users' processes are left out: a rule
    // about them would never match anything this Mac runs.
    static func owned(by uid: UInt32) -> [RunningProcess] {
        return all().filter { $0.uid == uid }
    }

    // the bundle id of the app a process lives in, nil when it is not an app
    static func bundleId(forProcessPath path: String) -> String? {
        guard let appPath = appBundlePath(forProcessPath: path) else { return nil }
        guard let id = Bundle(path: appPath)?.bundleIdentifier, !id.isEmpty else { return nil }
        return id
    }

    // the app bundle a process lives in. a helper of an app lives in its own
    // bundle inside the outer one, so the innermost bundle is the one that
    // belongs to the process.
    static func appBundlePath(forProcessPath path: String) -> String? {
        guard !path.isEmpty else { return nil }
        // the last ".app/" in the path opens the innermost bundle
        guard let range = path.range(of: ".app/", options: .backwards) else { return nil }
        return String(path[path.startIndex..<range.lowerBound]) + ".app"
    }

    // the kernel's process table. sysctl is the only way an app can see it:
    // the sandbox blocks proc_listpids.
    private struct KernelEntry {
        let pid: Int32
        let shortName: String
        let uid: UInt32
    }

    private static func readKernelProcessTable() -> [KernelEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let stride = Int(MemoryLayout<kinfo_proc>.size)
        var table = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 1)
        var readSize = size
        var readMib = mib
        guard sysctl(&readMib, u_int(readMib.count), &table, &readSize, nil, 0) == 0 else { return [] }

        let count = min(table.count, readSize / stride)
        var out: [KernelEntry] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let entry = table[i]
            let pid = Int32(entry.kp_proc.p_pid)
            guard pid > 0 else { continue }
            out.append(KernelEntry(
                pid: pid,
                shortName: shortName(entry),
                uid: 0
            ))
        }
        return out
    }

    // the kernel's p_comm is a fixed 17 byte field, so it is cut short. it is
    // only used when the path cannot be read at all.
    private static func shortName(_ entry: kinfo_proc) -> String {
        return withUnsafeBytes(of: entry.kp_proc.p_comm) { raw in
            let chars = raw.bindMemory(to: CChar.self)
            return String(cString: Array(chars).prefix { $0 != 0 }.map { $0 })
        }
    }

    private static func readPath(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN)) > 0 else { return "" }
        return String(cString: buffer)
    }

    // the owner of a process. the short flavor fills a proc_bsdshortinfo, which
    // is a smaller layout than proc_bsdinfo, so the right struct has to be used
    // or the uid is read from the wrong offset.
    private static func readOwner(_ pid: Int32) -> UInt32? {
        let info = UnsafeMutablePointer<proc_bsdshortinfo>.allocate(capacity: 1)
        defer { info.deallocate() }
        info.initialize(repeating: proc_bsdshortinfo(), count: 1)
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        let written = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, info, size)
        guard written == size else { return nil }
        return info.pointee.pbsi_uid
    }
}
