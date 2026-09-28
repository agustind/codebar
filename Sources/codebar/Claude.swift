import Darwin
import Foundation

// Claude Code sets the terminal title to "<prefix> <title>", where the prefix
// alternates ◐/◑ while it works and is ✳ otherwise. ✳ can mean it finished or
// that it's waiting on you, so that's settled from its session file:
// <config>/sessions/<pid>.json, which it keeps current with its `status`
// ('busy', 'idle' or 'waiting') and, when waiting, what for ('permission
// prompt', 'input needed', ...).

struct ClaudeStatus {
  let status: String?
  let waitingFor: String?
  let updatedAt: Double

  /// 'dialog open' is a dialog you opened yourself (/config and the like).
  var isWaiting: Bool { status == "waiting" && waitingFor != "dialog open" }
}

enum Claude {
  static var sessionsDir: URL {
    let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? homeDir + "/.claude"
    return URL(fileURLWithPath: config).appendingPathComponent("sessions")
  }

  /// The newest status among the Claude processes on this terminal; nil when
  /// there's none.
  static func status(tty: dev_t) -> ClaudeStatus? {
    var found: ClaudeStatus?
    for pid in pids(onTTY: tty) {
      guard let data = try? Data(contentsOf: sessionsDir.appendingPathComponent("\(pid).json")),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
      let st = ClaudeStatus(
        status: obj["status"] as? String,
        waitingFor: obj["waitingFor"] as? String,
        updatedAt: (obj["updatedAt"] as? NSNumber)?.doubleValue ?? 0)
      if found == nil || st.updatedAt > found!.updatedAt { found = st }
    }
    return found
  }

  static func pids(onTTY tty: dev_t) -> [pid_t] {
    let type = UInt32(PROC_TTY_ONLY)
    let arg = UInt32(bitPattern: tty)
    let bytes = proc_listpids(type, arg, nil, 0)
    guard bytes > 0 else { return [] }
    var buf = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 32)
    let got = proc_listpids(type, arg, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
    guard got > 0 else { return [] }
    return buf.prefix(Int(got) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
  }
}

enum Pty {
  /// The device of the terminal a pty master drives, for finding the
  /// processes running on it.
  static func device(master fd: Int32) -> dev_t? {
    guard fd >= 0, let name = ptsname(fd) else { return nil }
    var st = stat()
    guard stat(name, &st) == 0 else { return nil }
    return st.st_rdev
  }

  /// The working directory of the terminal's foreground process (the shell,
  /// or whatever it's running), so the header can follow `cd`.
  static func foregroundDirectory(master fd: Int32, fallback: pid_t) -> String? {
    var pid = fd >= 0 ? tcgetpgrp(fd) : -1
    if pid <= 0 { pid = fallback }
    guard pid > 0 else { return nil }
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
    return path.isEmpty ? nil : path
  }
}
