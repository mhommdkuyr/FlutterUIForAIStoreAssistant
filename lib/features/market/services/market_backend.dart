import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../shared/services/supabase_service.dart';

class MarketBackend {
  MarketBackend._();

  static final MarketBackend instance = MarketBackend._();

  String? _baseUrl;
  String? _publishableKey;

  void configure({
    String? supabaseUrl,
    String? supabasePublishableKey,
  }) {
    _baseUrl = _clean(supabaseUrl);
    _publishableKey = _clean(supabasePublishableKey);
  }

  bool get isConfigured =>
      (_baseUrl?.isNotEmpty ?? false) &&
      (_publishableKey?.isNotEmpty ?? false);

  Future<List<Map<String, dynamic>>> callRpc(
    String functionName,
    Map<String, dynamic> payload,
  ) async {
    if (!isConfigured) {
      throw StateError('Market backend is not configured.');
    }

    final response = await http
        .post(
          Uri.parse(_baseUrl! + '/rest/v1/rpc/' + functionName),
          headers: _headers(),
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode == 204 || response.body.trim().isEmpty) {
      return const [];
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'Market backend ' +
            response.statusCode.toString() +
            ': ' +
            response.body,
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! List) return const [];

    return decoded
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
  }

  Map<String, String> _headers() {
    final token =
        SupabaseService.instance.client?.auth.currentSession?.accessToken;

    return {
      'apikey': _publishableKey!,
      'Authorization': 'Bearer ' + (token ?? _publishableKey!),
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
  }

  String? _clean(String? value) {
    final result = value?.trim();
    return result == null || result.isEmpty ? null : result;
  }
}
