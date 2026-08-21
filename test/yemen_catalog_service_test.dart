import 'package:flutter_test/flutter_test.dart';
import 'package:ai_store_assistant/shared/services/yemen_catalog_service.dart';

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  test('loads the bundled Yemen catalog', () async {
    final service = YemenCatalogService();
    final products = await service.load();

    expect(products, isNotEmpty);
    expect(products.every((p) => p.id.isNotEmpty), isTrue);
    expect(products.every((p) => p.nameAr.isNotEmpty), isTrue);
  });

  test('filters by Arabic product name and category', () {
    const items = [
      YemenCatalogItem(
        id: '1',
        nameAr: 'حليب السعودية كامل الدسم',
        brand: 'السعودية',
        category: 'حليب',
        packSize: '200 مل',
        source: 'test',
        sourceUrl: '',
        imageUrls: [],
      ),
      YemenCatalogItem(
        id: '2',
        nameAr: 'مكرونة الفخامة',
        brand: 'الفخامة',
        category: 'مكرونة',
        packSize: '400 جم',
        source: 'test',
        sourceUrl: '',
        imageUrls: [],
      ),
    ];

    final service = YemenCatalogService();
    expect(service.filter(items, query: 'السعودية').single.id, '1');
    expect(service.filter(items, category: 'مكرونة').single.id, '2');
    expect(service.filter(items, query: '400', category: 'مكرونة').single.id, '2');
  });

  test('reference image readiness is explicit', () {
    const empty = YemenCatalogItem(
      id: 'empty',
      nameAr: 'منتج',
      brand: '',
      category: 'اختبار',
      packSize: '',
      source: '',
      sourceUrl: '',
      imageUrls: [],
    );
    const ready = YemenCatalogItem(
      id: 'ready',
      nameAr: 'منتج',
      brand: '',
      category: 'اختبار',
      packSize: '',
      source: '',
      sourceUrl: '',
      imageUrls: ['https://example.com/product.jpg'],
    );

    expect(empty.hasReferenceImage, isFalse);
    expect(ready.hasReferenceImage, isTrue);
  });
}
