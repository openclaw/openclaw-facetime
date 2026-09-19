import Foundation

@main
private struct CaptureStandardOutputChecks {
  static func main() {
    CaptureStandardOutput.ignoreBrokenPipeSignal()

    let closed = Pipe()
    try! closed.fileHandleForReading.close()
    let closedWrite = CaptureStandardOutput.write(
      Data(repeating: 0x78, count: 64),
      to: closed.fileHandleForWriting)
    precondition(
      !closedWrite,
      "a closed capture stdout pipe must report write failure instead of dying")

    let live = Pipe()
    let liveWrite = CaptureStandardOutput.write(Data("ok".utf8), to: live.fileHandleForWriting)
    precondition(liveWrite, "a live capture stdout pipe must accept PCM bytes")
    try! live.fileHandleForWriting.close()
    try! live.fileHandleForReading.close()
  }
}
