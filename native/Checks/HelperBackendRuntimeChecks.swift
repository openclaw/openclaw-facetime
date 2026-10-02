import Darwin
import Foundation

@main
struct HelperBackendRuntimeChecks {
  static func main() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = directory.appendingPathComponent("key")
    let token = String(repeating: "a", count: 64)
    for suffix in ["", "\n"] {
      try Data((token + suffix).utf8).write(to: key)
      chmod(key.path, 0o600)
      precondition(readHelperKey(key.path) == Data((token + "\n").utf8))
    }
    chmod(key.path, 0o644)
    precondition(readHelperKey(key.path) == nil)
    chmod(key.path, 0o600)
    for invalid in [token + "x", String(repeating: "z", count: 64), "", token + "\n\n"] {
      try Data(invalid.utf8).write(to: key)
      precondition(readHelperKey(key.path) == nil)
    }
    try Data(token.utf8).write(to: key)
    let link = directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: key)
    precondition(readHelperKey(link.path) == nil)
    precondition(readHelperKey(directory.path) == nil)
    precondition(readHelperKey(directory.appendingPathComponent("missing").path) == nil)
    let fifo = directory.appendingPathComponent("fifo")
    precondition(mkfifo(fifo.path, 0o600) == 0)
    precondition(readHelperKey(fifo.path) == nil)

    precondition(helperCString("a\"\\\n") == #""\141\042\134\012""#)
    precondition(helperDidInitialize(.init(succeeded: true, output: "(int) $0 = 1\n")))
    for result in [
      HelperCommandResult(succeeded: false, output: "(int) $0 = 1\n"),
      .init(succeeded: true, output: "(int) $0 = 0\n"),
      .init(succeeded: true, output: "(int) $0 = 10\n"),
      .init(succeeded: true, output: "mapping process is a platform binary, but mapped file is not"),
      .init(succeeded: true, output: ""),
    ] { precondition(!helperDidInitialize(result)) }
    let helper = directory.appendingPathComponent("fixture.dylib")
    try Data("synthetic dylib bytes".utf8).write(to: helper)
    let staging = directory.appendingPathComponent("staging")
    for success in [true, false] {
      var attempts = 0
      let selected = withStagedHelper(helper: helper, directory: staging, key: Data(token.utf8)) { image in
        attempts += 1
        precondition((try? Data(contentsOf: image)) == Data("synthetic dylib bytes".utf8))
        precondition(readHelperKey(image.appendingPathExtension("auth").path) == Data((token + "\n").utf8))
        return success
      }
      precondition(selected == success && attempts == 1)
      let leftovers = try FileManager.default.contentsOfDirectory(atPath: staging.path)
      precondition(leftovers.isEmpty)
    }
    precondition(!withStagedHelper(helper: link.appendingPathComponent("missing"), directory: staging, key: Data()) { _ in
      fatalError("staging failure must not invoke the loader")
    })
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: staging.path)
    precondition(leftovers.isEmpty)

    let command = runHelperCommand("/bin/sh", ["-c", "printf fixture"], timeout: 2)
    precondition(command.succeeded && command.output == "fixture")
    precondition(!runHelperCommand("/bin/sh", ["-c", "exit 1"], timeout: 2).succeeded)
    precondition(!runHelperCommand("/nonexistent", [], timeout: 2).succeeded)
    let started = ProcessInfo.processInfo.systemUptime
    precondition(!runHelperCommand("/bin/sh", ["-c", "exec sleep 30"], timeout: 0.1).succeeded)
    precondition(ProcessInfo.processInfo.systemUptime - started < 5)
    print("Helper runtime checks passed (synthetic processes and credentials only)")
  }
}
