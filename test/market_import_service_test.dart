import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_store_assistant/features/market/services/market_import_service.dart';

void main() {
  const service = MarketImportService();

  test('parses quoted CSV rows with Arabic names', () {
    final csv = 'name_ar,price,quantity,available\n'
        '"أرز بسمتي, فاخر",9200,4,true\n'
        'حليب,1800,10,false\n';

    final result = service.parseBytes(
      fileName: 'products.csv',
      bytes: Uint8List.fromList(utf8.encode(csv)),
    );

    expect(result.rows.length, 2);
    expect(result.rows.first.nameAr, 'أرز بسمتي, فاخر');
    expect(result.rows.first.price, 9200);
    expect(result.rows.first.quantity, 4);
    expect(result.rows.first.available, isTrue);
    expect(result.rows.last.available, isFalse);
    expect(result.errors, isEmpty);
  });

  test('parses JSON product arrays', () {
    final json = jsonEncode({
      'products': [
        {
          'name_ar': 'زيت طبخ',
          'barcode': '6281234567890',
          'price': 5500,
        }
      ],
    });

    final result = service.parseBytes(
      fileName: 'products.json',
      bytes: Uint8List.fromList(utf8.encode(json)),
    );

    expect(result.rows.single.nameAr, 'زيت طبخ');
    expect(result.rows.single.barcode, '6281234567890');
    expect(result.rows.single.price, 5500);
  });
}
