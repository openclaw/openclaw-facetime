import Foundation

/// The ordered control stream owns close intent; stdout failure can arrive first.
final class ParentLossCoordinator: @unchecked Sendable {
  private let lock = NSLock()
  private var handler: (@Sendable () -> Void)?
  private var closeSafe = false
  private var outputClosed = false
  private var stopRequested = false
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
    if (self.outputClosed || self.stopRequested) && !self.claimed {
      self.stopping = true
      self.handler = nil
    }
    self.lock.unlock()
  }

  func isStopping() -> Bool {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.stopping
  }

  func requestStop() {
    self.lock.lock()
    self.stopRequested = true
    // A signal can overtake a queued safe-close marker just like stdout loss.
    // Only the ordered control stream can authorize release or settlement.
    if self.closeSafe && !self.claimed {
      self.stopping = true
      self.handler = nil
    }
    self.lock.unlock()
  }

  func handleOutputClosed() {
    self.lock.lock()
    self.outputClosed = true
    if self.closeSafe && !self.claimed {
      self.stopping = true
      self.handler = nil
    }
    self.lock.unlock()
  }

  func handleUnexpectedParentEOF() {
    self.lock.lock()
    if self.closeSafe || self.claimed {
      self.lock.unlock()
      return
    }
    self.claimed = true
    let handler = self.handler
    self.handler = nil
    self.lock.unlock()
    handler?()
    self.lock.lock()
    self.stopping = true
    self.lock.unlock()
  }
}
