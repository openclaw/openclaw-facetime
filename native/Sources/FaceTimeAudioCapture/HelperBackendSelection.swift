import Foundation

enum SIPDebuggingState: String, Codable {
  case enabled, disabled, unknown

  static func parse(_ output: String?, succeeded: Bool) -> Self {
    guard succeeded, let output else { return .unknown }
    let lines = output.split(separator: "\n").map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let debug = lines.filter { $0.hasPrefix("Debugging Restrictions:") }
    if !debug.isEmpty {
      guard debug.count == 1 else { return .unknown }
      switch debug[0] {
      case "Debugging Restrictions: disabled": return .disabled
      case "Debugging Restrictions: enabled": return .enabled
      default: return .unknown
      }
    }
    let overall = lines.filter { $0.hasPrefix("System Integrity Protection status:") }
    guard overall.count == 1 else { return .unknown }
    switch overall[0] {
    case "System Integrity Protection status: disabled.": return .disabled
    case "System Integrity Protection status: enabled.": return .enabled
    default: return .unknown
    }
  }
}

struct HelperBackendSelection: Encodable, Equatable {
  enum Backend: String, Codable {
    case injected
    case capture = "out-of-process"
  }

  let backend: Backend
  let reason: String
  let sipDebugging: SIPDebuggingState
  let captureExecutable = "facetime-audio-capture"

  // SIP permits an attempt, not a dylib load. AMFI/library validation and the
  // target's current policy are decided by the real loader, never by boot args.
  static func select(
    sip: SIPDebuggingState,
    developerToolsEnabled: () -> Bool,
    initializeHelper: () -> Bool
  ) -> Self {
    guard sip == .disabled else {
      return Self(backend: .capture, reason: "sip-\(sip.rawValue)", sipDebugging: sip)
    }
    guard developerToolsEnabled() else {
      return Self(backend: .capture, reason: "developer-tools-unavailable", sipDebugging: sip)
    }
    guard initializeHelper() else {
      return Self(backend: .capture, reason: "helper-unavailable", sipDebugging: sip)
    }
    return Self(backend: .injected, reason: "helper-initialized", sipDebugging: sip)
  }
}
