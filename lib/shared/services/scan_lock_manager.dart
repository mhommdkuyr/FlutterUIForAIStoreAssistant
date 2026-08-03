/// Tracks which products are "locked" (added to the cart and still visible
/// in the camera frame), preventing duplicate additions while continuous
/// detection occurs.
///
/// Locking rules
/// ─────────────
/// • A product is locked the moment it is first detected (→ added to cart).
/// • While locked, it will NOT be added again even if the camera keeps
///   detecting it in subsequent frames.
/// • Each processed frame in which a locked product is NOT detected increments
///   its absent counter. When the counter reaches [unlockAfterTicks] the
///   product is unlocked — it has left the frame long enough to be counted
///   as a genuinely new scan when it next appears.
/// • When an unlocked product is detected again (it left and came back), it
///   is re-locked and a new cart entry is triggered.
///
/// Isolation
/// ─────────
/// Each product is tracked independently: locking product A never blocks
/// product B from being detected and added immediately.
///
/// Phase 2 additions
/// ─────────────────
/// • [removeProduct]   — remove a product entry entirely (call after deletion).
/// • [lockedProductIds] — read-only view of currently locked product IDs.
/// • [lockCount]        — number of products currently locked.
class ScanLockManager {
  ScanLockManager({this.unlockAfterTicks = 10});

  /// Consecutive absent-frames threshold before a locked product is unlocked.
  ///
  /// With frameSkip=4 at 30 fps → ~7.5 processed frames/sec.
  /// Default 10 ticks ≈ 1.3 seconds of absence before re-allowing.
  final int unlockAfterTicks;

  final Map<String, _LockEntry> _map = {};

  // ── Core API ──────────────────────────────────────────────────────────────

  /// Call once per processed frame with the set of product IDs detected in
  /// that frame.
  ///
  /// Updates absent counters for locked products not in [detectedIds] and
  /// auto-unlocks any that have exceeded [unlockAfterTicks].
  ///
  /// Call this BEFORE [onDetected] so the detected product's absent counter
  /// is already reset within this same tick.
  void tick(Set<String> detectedIds) {
    for (final entry in _map.entries) {
      if (!entry.value.locked) continue;
      if (detectedIds.contains(entry.key)) {
        entry.value.absentTicks = 0; // still in view
      } else {
        if (++entry.value.absentTicks >= unlockAfterTicks) {
          entry.value.locked = false; // left the frame long enough
        }
      }
    }
  }

  /// Call when [productId] was detected in the current frame (after [tick]).
  ///
  /// Returns `true` when the product should be added to the cart:
  ///   • First-ever detection, OR
  ///   • Previously locked, left the frame (unlocked), and now returned.
  ///
  /// Returns `false` when the product is currently locked (already in the
  /// cart and still continuously visible).
  bool onDetected(String productId) {
    final entry = _map[productId];
    if (entry == null) {
      // First time seeing this product → lock it → signal add.
      _map[productId] = _LockEntry();
      return true;
    }
    if (entry.locked) {
      // Continuously visible while locked → reset counter, suppress add.
      entry.absentTicks = 0;
      return false;
    }
    // Was unlocked (left view) and now returned → re-lock → signal add.
    entry.locked = true;
    entry.absentTicks = 0;
    return true;
  }

  // ── Query API ─────────────────────────────────────────────────────────────

  /// Whether [productId] is currently locked (in the cart and still visible).
  bool isLocked(String productId) => _map[productId]?.locked ?? false;

  /// All product IDs currently in a locked state.
  Set<String> get lockedProductIds =>
      _map.entries.where((e) => e.value.locked).map((e) => e.key).toSet();

  /// Number of products currently locked.
  int get lockCount => _map.values.where((e) => e.locked).length;

  // ── Mutation API ──────────────────────────────────────────────────────────

  /// Remove tracking state for [productId] (call after product deletion).
  ///
  /// The next detection of [productId] will be treated as a first-ever
  /// detection and trigger a cart add.
  void removeProduct(String productId) => _map.remove(productId);

  /// Clear all lock state (call when restarting a scan session).
  void reset() => _map.clear();
}

// ─────────────────────────────────────────────────────────────────────────────

class _LockEntry {
  bool locked = true;
  int absentTicks = 0;
}
