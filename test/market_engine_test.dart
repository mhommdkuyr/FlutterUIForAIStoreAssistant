import 'package:flutter_test/flutter_test.dart';
import '../lib/features/market/services/market_backend.dart';
import '../lib/features/market/services/market_repository.dart';

void main() {
  test('haversine returns a nearby distance', () {
    final km = MarketRepository.haversineKm(
      13.9667,
      44.1833,
      13.9764,
      44.1925,
    );
    expect(km, greaterThan(0));
    expect(km, lessThan(2));
  });

  test('backend is disabled without configuration', () {
    final backend = MarketBackend.instance;
    backend.configure(
      supabaseUrl: '',
      supabasePublishableKey: '',
    );
    expect(backend.isConfigured, isFalse);
  });
}
