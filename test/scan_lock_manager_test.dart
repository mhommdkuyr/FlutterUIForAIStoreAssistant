import 'package:flutter_test/flutter_test.dart';
import 'package:ai_store_assistant/shared/services/scan_lock_manager.dart';

void main() {
  group('ScanLockManager', () {
    // ── Basic lock ───────────────────────────────────────────────────────────

    test('onDetected returns true on first detection', () {
      final mgr = ScanLockManager();
      expect(mgr.onDetected('p1'), isTrue);
    });

    test('onDetected returns false while product is still locked', () {
      final mgr = ScanLockManager();
      mgr.onDetected('p1'); // first detection — lock
      expect(mgr.onDetected('p1'), isFalse); // still visible
    });

    test('isLocked is true after first detection', () {
      final mgr = ScanLockManager();
      mgr.onDetected('p1');
      expect(mgr.isLocked('p1'), isTrue);
    });

    test('isLocked is false for unseen product', () {
      final mgr = ScanLockManager();
      expect(mgr.isLocked('unknown'), isFalse);
    });

    // ── Tick / absent counting ────────────────────────────────────────────────

    test('product unlocks after unlockAfterTicks absent ticks', () {
      final mgr = ScanLockManager(unlockAfterTicks: 3);
      mgr.onDetected('p1');

      // 3 absent ticks should unlock.
      for (var i = 0; i < 3; i++) {
        mgr.tick({}); // p1 absent
      }
      expect(mgr.isLocked('p1'), isFalse);
    });

    test('product stays locked while still detected in ticks', () {
      final mgr = ScanLockManager(unlockAfterTicks: 3);
      mgr.onDetected('p1');

      // 2 absent ticks then seen again — should NOT unlock.
      mgr.tick({});
      mgr.tick({});
      mgr.tick({'p1'}); // seen again, counter resets

      expect(mgr.isLocked('p1'), isTrue);
    });

    test('product can be re-detected after unlock', () {
      final mgr = ScanLockManager(unlockAfterTicks: 2);
      mgr.onDetected('p1'); // first detection

      // Absent long enough to unlock.
      mgr.tick({});
      mgr.tick({});
      expect(mgr.isLocked('p1'), isFalse);

      // Re-enters frame — should signal add again.
      expect(mgr.onDetected('p1'), isTrue);
      expect(mgr.isLocked('p1'), isTrue);
    });

    // ── Multiple products ─────────────────────────────────────────────────────

    test('locking one product does not block another', () {
      final mgr = ScanLockManager();
      mgr.onDetected('p1');
      // p2 has never been seen — should return true.
      expect(mgr.onDetected('p2'), isTrue);
    });

    test('two products can be locked simultaneously', () {
      final mgr = ScanLockManager();
      mgr.onDetected('p1');
      mgr.onDetected('p2');
      expect(mgr.isLocked('p1'), isTrue);
      expect(mgr.isLocked('p2'), isTrue);
    });

    test('lockCount reflects number of locked products', () {
      final mgr = ScanLockManager();
      expect(mgr.lockCount, 0);
      mgr.onDetected('p1');
      expect(mgr.lockCount, 1);
      mgr.onDetected('p2');
      expect(mgr.lockCount, 2);
    });

    test('lockedProductIds contains all locked products', () {
      final mgr = ScanLockManager();
      mgr.onDetected('p1');
      mgr.onDetected('p2');
      expect(mgr.lockedProductIds, containsAll(['p1', 'p2']));
    });

    // ── Duplicate prevention ──────────────────────────────────────────────────

    test('rapid repeat detection of same product only adds once', () {
      final mgr = ScanLockManager();
      var addCount = 0;

      // Simulate 20 consecutive frames all detecting the same product.
      for (var i = 0; i < 20; i++) {
        mgr.tick({'p1'});
        if (mgr.onDetected('p1')) addCount++;
      }
      expect(addCount, 1);
    });

    // ── Reset & remove ────────────────────────────────────────────────────────

    test('reset clears all locks', () {
      final mgr = ScanLockManager();
      mgr.onDetected('p1');
      mgr.onDetected('p2');
      mgr.reset();
      expect(mgr.lockCount, 0);
      expect(mgr.isLocked('p1'), isFalse);
    });

    test('removeProduct removes its tracking entry', () {
      final mgr = ScanLockManager();
      mgr.onDetected('p1');
      expect(mgr.isLocked('p1'), isTrue);
      mgr.removeProduct('p1');
      // After removal, the next detection is treated as first-ever.
      expect(mgr.isLocked('p1'), isFalse);
      expect(mgr.onDetected('p1'), isTrue);
    });

    // ── Exit and re-entry ─────────────────────────────────────────────────────

    test('exit and re-entry produces correct add signals', () {
      final mgr = ScanLockManager(unlockAfterTicks: 2);
      final adds = <String>[];

      void frame(Set<String> seen) {
        mgr.tick(seen);
        for (final id in seen) {
          if (mgr.onDetected(id)) adds.add(id);
        }
      }

      frame({'p1'}); // detection #1 → add
      frame({'p1'}); // still visible → no add
      frame({}); // absent tick 1
      frame({}); // absent tick 2 → unlocked
      frame({'p1'}); // re-enters → add again

      expect(adds.length, 2);
      expect(adds, everyElement('p1'));
    });

    // ── Absent counter reset ──────────────────────────────────────────────────

    test('absent counter resets to 0 when product reappears before threshold',
        () {
      final mgr = ScanLockManager(unlockAfterTicks: 5);
      mgr.onDetected('p1');

      mgr.tick({}); // absent 1
      mgr.tick({}); // absent 2
      mgr.tick({}); // absent 3
      mgr.tick({'p1'}); // seen again — counter resets
      mgr.tick({}); // absent 1 (fresh counter)
      mgr.tick({}); // absent 2

      // Should still be locked (only 2 absents since last seen, < threshold 5)
      expect(mgr.isLocked('p1'), isTrue);
    });
  });
}
