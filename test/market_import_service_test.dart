import 'package:flutter_test/flutter_test.dart';
import 'package:ai_store_assistant/features/market/services/market_import_service.dart';

void main() {
  test('market import row preserves product fields', () {
    const row = MarketImportRow(
      nameAr: 'أرز بسمتي',
      nameEn: 'Basmati Rice',
      brand: 'Brand',
      category: 'أغذية',
      barcode: '6281234567890',
      price: 9200,
      quantity: 4,
      available: true,
    );

    expect(row.nameAr, 'أرز بسمتي');
    expect(row.nameEn, 'Basmati Rice');
    expect(row.barcode, '6281234567890');
    expect(row.price, 9200);
    expect(row.quantity, 4);
  });
}
