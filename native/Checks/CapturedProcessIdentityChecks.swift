import Darwin
import Foundation

@main
struct CapturedProcessIdentityChecks {
  static func main() throws {
    let input = Pipe()
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/cat")
    child.standardInput = input
    child.standardOutput = FileHandle.nullDevice
    try child.run()
    defer {
      try? input.fileHandleForWriting.close()
      if child.isRunning { child.terminate() }
      child.waitUntilExit()
    }
    let identity = try CapturedProcessIdentity.read(pid: child.processIdentifier)
    precondition(!identity.hasExited())
    let stale = CapturedProcessIdentity(pid: identity.pid, uniqueID: identity.uniqueID, version: identity.version ^ 1)
    precondition(stale.sendSignal(SIGTERM) == ESRCH, "stale generation must not signal a reused PID")
    precondition(stale.hasExited() && child.isRunning && !identity.hasExited(), "stale identity must leave the actual child alive")
    precondition(identity.sendSignal(SIGTERM) == 0, "captured generation must signal its own child")
    child.waitUntilExit()
    precondition(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGTERM)
    precondition(identity.hasExited(), "reaped generation must be absent")
    precondition(identity.sendSignal(SIGTERM) == ESRCH, "retired generation must stay absent")
    fputs("PASS: generation-bound signaling rejects stale identity and settles only the owned child\n", stderr)
  }
}
