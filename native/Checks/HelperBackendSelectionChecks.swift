import Foundation

@main
struct HelperBackendSelectionChecks {
  static func main() throws {
    let fixtures: [(String?, Bool, SIPDebuggingState)] = [
      ("System Integrity Protection status: enabled.", true, .enabled),
      ("System Integrity Protection status: disabled.", true, .disabled),
      ("System Integrity Protection status: unknown (Custom Configuration).\n\tDebugging Restrictions: disabled", true, .disabled),
      ("System Integrity Protection status: unknown (Custom Configuration).\n\tDebugging Restrictions: enabled", true, .enabled),
      ("System Integrity Protection status: disabled.\nDebugging Restrictions: enabled", true, .enabled),
      ("System Integrity Protection status: disabled.\nDebugging Restrictions: unknown", true, .unknown),
      ("System Integrity Protection status: disabled.\nSystem Integrity Protection status: enabled.", true, .unknown),
      ("Debugging Restrictions: disabled\nDebugging Restrictions: enabled", true, .unknown),
      ("System Integrity Protection status: disabled unexpectedly", true, .unknown),
      ("System Integrity Protection status: unknown", true, .unknown),
      ("System Integrity Protection status: disabled.", false, .unknown),
      (nil, false, .unknown), ("", true, .unknown),
    ]
    for (output, succeeded, expected) in fixtures {
      precondition(SIPDebuggingState.parse(output, succeeded: succeeded) == expected)
    }
    for sip in [SIPDebuggingState.enabled, .unknown] {
      let selected = HelperBackendSelection.select(
        sip: sip,
        developerToolsEnabled: { fatalError("blocked SIP must not probe Developer Tools") },
        initializeHelper: { fatalError("blocked SIP must not attach") })
      precondition(selected.backend == .capture)
      precondition(selected.reason == "sip-\(sip.rawValue)")
    }
    let blockedTools = HelperBackendSelection.select(
      sip: .disabled, developerToolsEnabled: { false },
      initializeHelper: { fatalError("unauthorized Developer Tools must not attach") })
    precondition(blockedTools.reason == "developer-tools-unavailable")
    for initialized in [false, true] {
      var attempts = 0
      let selected = HelperBackendSelection.select(
        sip: .disabled, developerToolsEnabled: { true },
        initializeHelper: { attempts += 1; return initialized })
      precondition(attempts == 1)
      precondition(selected.backend == (initialized ? .injected : .capture))
      precondition(selected.reason == (initialized ? "helper-initialized" : "helper-unavailable"))
      let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selected)) as! [String: String]
      precondition(json["captureExecutable"] == "facetime-audio-capture")
      precondition(json["backend"] == (initialized ? "injected" : "out-of-process"))
    }
    print("Helper backend selection checks passed")
  }
}
