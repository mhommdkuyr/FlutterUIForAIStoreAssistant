import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseService {
  SupabaseService._();

  static final SupabaseService instance = SupabaseService._();

  bool _initialized = false;

  bool get isConfigured => _initialized;

  SupabaseClient? get client =>
      _initialized ? Supabase.instance.client : null;

  Future<void> initialize() async {
    final url = const String.fromEnvironment('SUPABASE_URL').trim();
    final key =
        const String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY').trim();

    if (url.isEmpty || key.isEmpty) return;

    await Supabase.initialize(
      url: url,
      publishableKey: key,
    );
    _initialized = true;
  }
}
