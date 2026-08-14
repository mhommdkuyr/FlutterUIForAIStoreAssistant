import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:ai_store_assistant/shared/services/product_image_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tempDir;
  late ProductImageService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('product_images_test_');
    service = ProductImageService();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return tempDir.path;
      }
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('saves primary and multiple additional product reference images',
      () async {
    final sourceA = File('${tempDir.path}/source-a.jpg')
      ..writeAsBytesSync([1, 2, 3]);
    final sourceB = File('${tempDir.path}/source-b.jpg')
      ..writeAsBytesSync([4, 5, 6]);
    final sourceC = File('${tempDir.path}/source-c.jpg')
      ..writeAsBytesSync([7, 8, 9]);

    final primaryPath = await service.savePickedImage(XFile(sourceA.path));
    final firstReferencePath = await service.saveAdditionalImage(
      'product-1',
      XFile(sourceB.path),
    );
    final secondReferencePath = await service.saveAdditionalImage(
      'product-1',
      XFile(sourceC.path),
    );

    final references = await service.getAdditionalImagePaths('product-1');

    expect(File(primaryPath).existsSync(), isTrue);
    expect(File(firstReferencePath).existsSync(), isTrue);
    expect(File(secondReferencePath).existsSync(), isTrue);
    expect(references, hasLength(2));
    expect(references, containsAll([firstReferencePath, secondReferencePath]));
  });
}
