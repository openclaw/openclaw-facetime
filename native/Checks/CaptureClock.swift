// Same-module test clock keeps the production owner's monotonic-time logic
// intact while native checks advance handoffs without sleeping or polling.
struct ContinuousClock {
  struct Instant: Comparable {
    let offset: Duration

    func duration(to other: Instant) -> Duration { other.offset - self.offset }
    static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    static func + (instant: Instant, duration: Duration) -> Instant {
      Instant(offset: instant.offset + duration)
    }
  }

  static var now = Instant(offset: .zero)
  static func advance(by duration: Duration) { self.now = self.now + duration }
}
