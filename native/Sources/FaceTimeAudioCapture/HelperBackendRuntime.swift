import AppKit
import Darwin
import Foundation
import Security

struct HelperCommandResult {
  let succeeded: Bool
  let output: String
}

// Subprocess diagnostics stay private and bounded. In particular, a failed
// loader must not turn its raw output into a public backend-selection response.
func runHelperCommand(_ executable: String, _ arguments: [String], timeout: TimeInterval)
  -> HelperCommandResult
{
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  do {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("output")
    guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
      return HelperCommandResult(succeeded: false, output: "")
    }
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output
    process.environment = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
      "LC_ALL": "C",
    ]
    try process.run()
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
      return HelperCommandResult(succeeded: false, output: "")
    }
    process.waitUntilExit()
    let input = try FileHandle(forReadingFrom: log)
    defer { try? input.close() }
    let bytes = try input.read(upToCount: 1_048_576) ?? Data()
    return HelperCommandResult(
      succeeded: process.terminationReason == .exit && process.terminationStatus == 0,
      output: String(decoding: bytes, as: UTF8.self))
  } catch {
    return HelperCommandResult(succeeded: false, output: "")
  }
}

func selectHelperBackend(app: String, executable: URL) -> HelperBackendSelection {
  let sip = runHelperCommand("/usr/bin/csrutil", ["status"], timeout: 5)
  return HelperBackendSelection.select(
    sip: SIPDebuggingState.parse(sip.output, succeeded: sip.succeeded),
    developerToolsEnabled: {
      let tools = runHelperCommand("/usr/sbin/DevToolsSecurity", ["-status"], timeout: 5)
      return tools.succeeded
        && tools.output.trimmingCharacters(in: .whitespacesAndNewlines)
          == "Developer mode is currently enabled."
    },
    initializeHelper: { initializeNativeHelper(app: app, executable: executable) })
}

func readHelperKey(_ path: String) -> Data? {
  let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
  guard descriptor >= 0 else { return nil }
  defer { close(descriptor) }
  var info = stat()
  guard fstat(descriptor, &info) == 0,
    info.st_mode & S_IFMT == S_IFREG,
    info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
    info.st_size == 64 || info.st_size == 65
  else { return nil }
  var bytes = [UInt8](repeating: 0, count: 66)
  let count = read(descriptor, &bytes, bytes.count)
  guard count == info.st_size else { return nil }
  let token = Array(bytes.prefix(64))
  guard token.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
    count == 64 || bytes[64] == 10
  else { return nil }
  return Data(token + [10])
}

func helperCString(_ value: String) -> String {
  // Encode every UTF-8 byte as a fixed-width octal escape; paths cannot escape
  // the LLDB expression, including paths containing quotes or newlines.
  "\"" + value.utf8.map { String(format: "\\%03o", $0) }.joined() + "\""
}

private func initializeNativeHelper(app: String, executable: URL) -> Bool {
  let bundleID: String
  switch app {
  case "FaceTime": bundleID = "com.apple.FaceTime"
  case "Phone": bundleID = "com.apple.mobilephone"
  default: return false
  }
  let targets = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { !$0.isTerminated }
  guard targets.count == 1, let target = targets.first else { return false }
  var code: SecCode?
  var requirement: SecRequirement?
  guard SecCodeCopyGuestWithAttributes(
    nil, [kSecGuestAttributePid as String: target.processIdentifier] as CFDictionary,
    SecCSFlags(), &code) == errSecSuccess,
    let code,
    SecRequirementCreateWithString(
      "anchor apple and identifier \"\(bundleID)\"" as CFString, SecCSFlags(), &requirement) == errSecSuccess,
    let requirement,
    SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
  else { return false }

  // The Gateway owns this credential and the subsequent authenticated handshake.
  // Selection never creates a competing key or includes it in process arguments.
  let home = FileManager.default.homeDirectoryForCurrentUser
  guard let key = readHelperKey(
    home.appendingPathComponent("Library/Application Support/OpenClaw/FaceTime/helper-ipc-key").path)
  else { return false }
  let helper = executable.resolvingSymlinksInPath().deletingLastPathComponent()
    .appendingPathComponent("FaceTimeHelper.dylib")
  let directory = home.appendingPathComponent("Library/Containers/\(bundleID)/Data/tmp")
  return withStagedHelper(helper: helper, directory: directory, key: key) { staged in
    guard !target.isTerminated else { return false }
    let expression = "expr -- (int)({ void *h = (void *)dlopen(\(helperCString(staged.path)), 2); int *ready = h ? (int *)(void *)dlsym(h, \"OpenClawFaceTimeHelperInitialized\") : 0; ready && *ready == 1; })"
    let result = runHelperCommand(
      "/usr/bin/xcrun", ["lldb", "--no-lldbinit", "--batch", "-p", String(target.processIdentifier),
        "-o", expression, "-o", "detach", "-o", "quit"], timeout: 90)
    return helperDidInitialize(result)
  }
}

func withStagedHelper(
  helper: URL, directory: URL, key: Data, initialize: (URL) -> Bool
) -> Bool {
  let staged = directory.appendingPathComponent("FaceTimeHelper-\(UUID().uuidString).dylib")
  let sidecar = staged.appendingPathExtension("auth")
  do {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: helper, to: staged)
    // dlopen and +load finish before the attempt returns. The mapped vnode
    // survives unlink; neither the image nor the one-use key needs a pathname.
    defer {
      unlink(sidecar.path)
      unlink(staged.path)
    }
    let descriptor = open(sidecar.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { return false }
    let written = key.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    let synced = fsync(descriptor)
    close(descriptor)
    guard written == key.count, synced == 0 else { return false }
    return initialize(staged)
  } catch {
    return false
  }
}

func helperDidInitialize(_ result: HelperCommandResult) -> Bool {
  result.succeeded && result.output.split(separator: "\n").contains {
    $0.range(of: #"^\(int\) \$[0-9]+ = 1$"#, options: .regularExpression) != nil
  }
}
