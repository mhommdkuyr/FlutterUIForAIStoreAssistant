import 'dart:convert';

import 'package:file_picker/file_picker.dart';

class MarketImportRow {
  const MarketImportRow({
    required this.nameAr,
    this.nameEn,
    this.brand,
    this.category,
    this.barcode,
    this.price,
    this.quantity,
    this.available = true,
  });

  final String nameAr;
  final String? nameEn;
  final String? brand;
  final String? category;
  final String? barcode;
  final double? price;
  final double? quantity;
  final bool available;
}

class MarketImportResult {
  const MarketImportResult({
    required this.rows,
    required this.errors,
    required this.fileName,
  });

  final List<MarketImportRow> rows;
  final List<String> errors;
  final String fileName;
}

class MarketImportService {
  const MarketImportService();

  Future<MarketImportResult?> pickAndParse() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;

    final file = result.files.single;
    if (file.bytes == null) {
      return MarketImportResult(
        rows: const [],
        errors: const ['تعذر قراءة الملف من الجهاز.'],
        fileName: file.name,
      );
    }

    return parseBytes(fileName: file.name, bytes: file.bytes!);
  }

  MarketImportResult parseBytes({
    required String fileName,
    required List<int> bytes,
  }) {
    final source = utf8.decode(bytes, allowMalformed: true);
    try {
      final parsed = fileName.toLowerCase().endsWith('.json')
          ? _parseJson(source)
          : _parseCsv(source);
      return MarketImportResult(
        rows: parsed.rows,
        errors: parsed.errors,
        fileName: fileName,
      );
    } catch (error) {
      return MarketImportResult(
        rows: const [],
        errors: ['تعذر تحليل الملف: ' + error.toString()],
        fileName: fileName,
      );
    }
  }

  _Parsed _parseJson(String source) {
    final decoded = jsonDecode(source.replaceFirst('﻿', ''));
    final rawRows = decoded is List
        ? decoded
        : decoded is Map<String, dynamic>
            ? (decoded['products'] ?? decoded['rows'])
            : null;

    if (rawRows is! List) {
      return const _Parsed(
        [],
        ['يجب أن يحتوي JSON على مصفوفة products أو rows.'],
      );
    }

    final rows = <MarketImportRow>[];
    final errors = <String>[];

    for (var i = 0; i < rawRows.length; i++) {
      final item = rawRows[i];
      if (item is! Map) {
        errors.add(
          'السطر ' + (i + 1).toString() + ': ليس كائنًا صالحًا.',
        );
        continue;
      }
      final row = _fromMap(Map<String, dynamic>.from(item));
      if (row == null) {
        errors.add(
          'السطر ' + (i + 1).toString() + ': الاسم العربي للمنتج مطلوب.',
        );
      } else {
        rows.add(row);
      }
    }

    return _Parsed(rows, errors);
  }

  _Parsed _parseCsv(String source) {
    final records = _csvRecords(source.replaceFirst('﻿', ''));
    if (records.isEmpty) {
      return const _Parsed([], ['ملف CSV فارغ.']);
    }

    final headers = records.first.map(_header).toList(growable: false);
    final rows = <MarketImportRow>[];
    final errors = <String>[];

    for (var i = 1; i < records.length; i++) {
      final cells = records[i];
      if (cells.every((cell) => cell.trim().isEmpty)) continue;

      final map = <String, dynamic>{};
      for (var c = 0; c < headers.length && c < cells.length; c++) {
        map[headers[c]] = cells[c].trim();
      }

      final row = _fromMap(map);
      if (row == null) {
        errors.add(
          'السطر ' + (i + 1).toString() + ': الاسم العربي للمنتج مطلوب.',
        );
      } else {
        rows.add(row);
      }
    }

    return _Parsed(rows, errors);
  }

  MarketImportRow? _fromMap(Map<String, dynamic> map) {
    String value(List<String> keys) {
      for (final key in keys) {
        final raw = map[key];
        if (raw == null) continue;
        final value = raw.toString().trim();
        if (value.isNotEmpty) return value;
      }
      return '';
    }

    final nameAr =
        value(['name_ar', 'name', 'product_name_ar', 'product_name']);
    if (nameAr.isEmpty) return null;

    return MarketImportRow(
      nameAr: nameAr,
      nameEn: _nullable(value(['name_en', 'product_name_en'])),
      brand: _nullable(value(['brand'])),
      category: _nullable(value(['category', 'category_ar'])),
      barcode: _nullable(value(['barcode', 'ean', 'gtin'])),
      price: _double(value(['price', 'selling_price', 'sale_price'])),
      quantity: _double(value(['quantity', 'stock', 'qty'])),
      available: _bool(value(['available', 'is_available'])) ?? true,
    );
  }

  String _header(String value) => value
      .trim()
      .toLowerCase()
      .replaceAll(' ', '_')
      .replaceAll('-', '_');

  String? _nullable(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  double? _double(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : double.tryParse(trimmed);
  }

  bool? _bool(String value) {
    switch (value.trim().toLowerCase()) {
      case '1':
      case 'true':
      case 'yes':
      case 'متوفر':
        return true;
      case '0':
      case 'false':
      case 'no':
      case 'غير متوفر':
        return false;
      default:
        return null;
    }
  }

  List<List<String>> _csvRecords(String source) {
    final records = <List<String>>[];
    final row = <String>[];
    final field = StringBuffer();
    var quoted = false;
    final lf = String.fromCharCode(10);
    final cr = String.fromCharCode(13);

    void finishField() {
      row.add(field.toString());
      field.clear();
    }

    void finishRow() {
      finishField();
      records.add(List<String>.from(row));
      row.clear();
    }

    for (var i = 0; i < source.length; i++) {
      final char = source[i];
      if (char == '"') {
        if (quoted && i + 1 < source.length && source[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = !quoted;
        }
      } else if (char == ',' && !quoted) {
        finishField();
      } else if ((char == lf || char == cr) && !quoted) {
        if (char == cr &&
            i + 1 < source.length &&
            source[i + 1] == lf) {
          i++;
        }
        finishRow();
      } else {
        field.write(char);
      }
    }

    if (field.isNotEmpty || row.isNotEmpty) finishRow();
    return records;
  }
}

class _Parsed {
  const _Parsed(this.rows, this.errors);

  final List<MarketImportRow> rows;
  final List<String> errors;
}
