import Darwin
import Foundation

struct CapturedProcessIdentity: Equatable, Sendable {
  let pid: pid_t
  let uniqueID: UInt64
  let version: Int32

  // XNU PROC_PIDUNIQIDENTIFIERINFO (flavor 17), present in macOS 14.4.
  // The private result layout is not exposed by the public SDK's proc_info.h.
  private struct GenerationInfo {
    var executableUUID: (UInt64, UInt64) = (0, 0)
    var uniqueID: UInt64 = 0
    var parentUniqueID: UInt64 = 0
    var version: Int32 = 0
    var reserved2: UInt32 = 0
    var reserved3: UInt64 = 0
    var reserved4: UInt64 = 0
  }

  static func read(pid: pid_t) throws -> CapturedProcessIdentity {
    guard pid > 0 else { throw POSIXError(.EINVAL) }
    var info = GenerationInfo()
    let size = Int32(MemoryLayout<GenerationInfo>.size)
    guard size == 56 else { throw POSIXError(.EINVAL) }
    errno = 0
    guard proc_pidinfo(pid, 17, 0, &info, size) == size else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return CapturedProcessIdentity(pid: pid, uniqueID: info.uniqueID, version: info.version)
  }

  func hasExited() -> Bool {
    do {
      return try Self.read(pid: self.pid) != self
    } catch let error as POSIXError where error.code == .ESRCH {
      return true
    } catch {
      return false
    }
  }

  func sendSignal(_ signal: Int32) -> Int32 {
    var token = audit_token_t()
    token.val.5 = UInt32(bitPattern: self.pid)
    token.val.7 = UInt32(bitPattern: self.version)
    // libproc returns errno directly. The kernel checks the retained generation
    // and applies ordinary signal permissions; never fall back to kill(pid).
    return proc_signal_with_audittoken(&token, signal)
  }
}
