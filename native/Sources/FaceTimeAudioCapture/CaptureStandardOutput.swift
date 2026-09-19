import Darwin
import Foundation

enum CaptureStandardOutput {
  static func ignoreBrokenPipeSignal() {
    signal(SIGPIPE, SIG_IGN)
  }

  static func write(_ data: Data, to handle: FileHandle) -> Bool {
    do {
      try handle.write(contentsOf: data)
      return true
    } catch {
      return false
    }
  }
}
