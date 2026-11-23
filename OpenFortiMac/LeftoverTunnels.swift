import Foundation

/// Tunnels started by an earlier run of the app that ended without stopping them (a crash,
/// a forced quit). openfortivpn keeps running as root, with no app left to stop it.
enum LeftoverTunnels {
    /// The `sudo … openfortivpn -c …/fortivpn_….conf` processes whose parent is gone.
    /// Blocking: runs ps, call it off the main thread.
    static func find() -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            // Parent 1 is launchd: the app that started this tunnel no longer exists
            guard fields.count == 3, let pid = Int32(fields[0]), fields[1] == "1" else { return nil }
            let command = fields[2]
            guard command.hasPrefix("sudo ") || command.hasPrefix("/usr/bin/sudo "),
                  command.contains("openfortivpn -c "), command.contains("/fortivpn_") else { return nil }
            return pid
        }
    }

    /// sudo keeps the real user id of who started it, so SIGTERM needs no password. It relays
    /// the signal to openfortivpn, which restores routes and DNS before exiting.
    static func stop(_ pids: [Int32]) {
        for pid in pids {
            kill(pid, SIGTERM)
        }
    }

    /// A crash can also leave the temporary openfortivpn configuration, which holds the password.
    static func removeStaleConfigFiles() {
        let directory = FileManager.default.temporaryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []

        for file in files where file.lastPathComponent.hasPrefix("fortivpn_") && file.pathExtension == "conf" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            // A connection in progress deletes its file within a second: leave fresh ones alone
            if let modified = modified, Date().timeIntervalSince(modified) > 60 {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
