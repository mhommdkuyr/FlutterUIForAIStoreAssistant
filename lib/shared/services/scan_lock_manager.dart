/// Tracks which products are "locked" (detected and added to the cart, and
/// still visible in the camera frame).
///
/// Locking rules
/// ─────────────
/// • A product is locked the moment it is first detected (→ added to cart).
/// • While locked, it will NOT be added again, even if the camera keeps
///   detecting it in subsequent frames.
/// • Each frame tick where a locked product is NOT detected increments its
///   absent counter. Once the counter reaches [unlockAfterTicks], the product
///   is unlocked.
/// • When an unlocked product is detected again (it left and came back), it is
///   re-locked and a new cart entry is triggered.
///
/// Isolation
/// ─────────
/// Every product is tracked independently. Locking product A never blocks
/// product B from being detected and added immediately.
class ScanLockManager {
  ScanLockManager({this.unlockAfterTicks = 10});

  /// Number of consecutive absent ticks before a product is unlocked.
  ///
  /// With a frame-skip of 4 at ~30 fps → ~7.5 processed frames / sec.
  /// 10 ticks ≈ 1.3 seconds of the product being absent.
  final int unlockAfterTicks;

  final Map<String, _LockEntry> _map = {};

  // ── API ──────────────────────────────────────────────────────────────────────

  /// Call once per processed frame with the set of product IDs detected in
  /// that frame. Updates absent counters and auto-unlocks stale products.
  ///
  /// Call this BEFORE [onDetected] so that the absent counter for the detected
  /// product is reset to 0 within [tick] before [onDetected] is invoked.
  void tick(Set<String> detectedIds) {
    for (final e in _map.entries) {
      if (!e.value.locked) continue;
      if (detectedIds.contains(e.key)) {
        e.value.absentTicks = 0; // still in view
      } else {
        if (++e.value.absentTicks >= unlockAfterTicks) {
          e.value.locked = false; // left the frame long enough
        }
      }
    }
  }

  /// Call when a specific product has been detected in the current frame.
  ///
  /// Returns `true` when the product should be added to the cart:
  ///   • First detection ever, OR
  ///   • Previously locked, left the frame (unlocked), and now returned.
  ///
  /// Returns `false` when the product is currently locked (already in cart
  /// and still continuously visible).
  bool onDetected(String productId) {
    final entry = _map[productId];
    if (entry == null) {
      // First time this product is seen → lock it → signal add to cart.
      _map[productId] = _LockEntry();
      return true;
    }
    if (entry.locked) {
      // Continuously visible while locked → reset absent counter, ignore.
      entry.absentTicks = 0;
      return false;
    }
    // Was unlocked (left view) and now returned → re-lock → signal add.
    entry.locked = true;
    entry.absentTicks = 0;
    return true;
  }

  /// Whether [productId] is currently locked (visible and already counted).
  bool isLocked(String productId) => _map[productId]?.locked ?? false;

  /// Clear all lock state (e.g. when restarting a scan session).
  void reset() => _map.clear();
}

class _LockEntry {
  bool locked = true;
  int absentTicks = 0;
}
