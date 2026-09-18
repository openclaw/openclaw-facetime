import Foundation

/// One-shot parent-loss cleanup shared by stdin EOF and stdout pipe failure.
final class ParentLossCoordinator: @unchecked Sendable {
  private let lock = NSLock()
  private var handler: (@Sendable () -> Void)?
  private var closeSafe = false
  private var claimed = false
  private var stopping = false

  func setHandler(_ handler: @escaping @Sendable () -> Void) {
    self.lock.lock()
    self.handler = handler
    self.lock.unlock()
  }

  func markCloseSafe() {
    self.lock.lock()
    self.closeSafe = true
    self.lock.unlock()
  }

  func isCloseSafe() -> Bool {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.closeSafe
  }

  func isStopping() -> Bool {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.stopping
  }

  func requestStop() {
    self.lock.lock()
    if self.claimed && !self.stopping {
      self.lock.unlock()
      return
    }
    self.stopping = true
    self.lock.unlock()
  }

  func notifyParentLost() {
    self.lock.lock()
    if self.claimed {
      self.lock.unlock()
      return
    }
    self.claimed = true
    let handler = self.closeSafe ? nil : self.handler
    self.handler = nil
    self.lock.unlock()
    handler?()
    self.lock.lock()
    self.stopping = true
    self.lock.unlock()
  }

  func handleUnexpectedParentEOF() {
    if self.isCloseSafe() {
      return
    }
    self.notifyParentLost()
  }
}
