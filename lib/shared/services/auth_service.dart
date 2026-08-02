import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user_model.dart';
import '../../core/constants/app_constants.dart';

/// Authentication service — interface prepared for backend integration.
/// Currently uses SharedPreferences as a local session store.
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  UserModel? _currentUser;
  bool _isAuthenticated = false;

  UserModel? get currentUser => _currentUser;
  bool get isAuthenticated => _isAuthenticated;
  String? get currentRole => _currentUser?.role;
  String? get currentUserId => _currentUser?.id;

  // ── Session ───────────────────────────────────────────────────────────────

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final userJson = prefs.getString('_current_user');
    if (userJson != null) {
      try {
        _currentUser =
            UserModel.fromJson(jsonDecode(userJson) as Map<String, dynamic>);
        _isAuthenticated = true;
      } catch (_) {
        await _clearSession(prefs);
      }
    }
  }

  Future<void> _persistSession(UserModel user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('_current_user', jsonEncode(user.toJson()));
    await prefs.setString(AppConstants.keyUserRole, user.role);
    await prefs.setString(AppConstants.keyUserId, user.id);
  }

  Future<void> _clearSession(SharedPreferences prefs) async {
    await prefs.remove('_current_user');
    await prefs.remove(AppConstants.keyAuthToken);
    await prefs.remove(AppConstants.keyUserRole);
    await prefs.remove(AppConstants.keyUserId);
    _currentUser = null;
    _isAuthenticated = false;
  }

  // ── Auth operations ───────────────────────────────────────────────────────

  /// Login — replace body with real API call when backend is ready.
  Future<AuthResult> login(
      {required String email, required String password}) async {
    try {
      // TODO: Replace with real API call
      // final response = await ApiService.instance.post('/auth/login', { 'email': email, 'password': password });
      await Future.delayed(
          const Duration(milliseconds: 800)); // simulate network

      // Demo: accept any credentials and map to merchant role
      final user = UserModel(
        id: 'demo-merchant-001',
        fullName: 'Store Owner',
        email: email,
        phone: '+967700000000',
        role: AppConstants.roleMerchant,
        storeName: 'My Store',
        createdAt: DateTime.now(),
      );

      _currentUser = user;
      _isAuthenticated = true;
      await _persistSession(user);
      return AuthResult.success(user);
    } catch (e) {
      return AuthResult.failure(e.toString());
    }
  }

  /// Register — replace body with real API call when backend is ready.
  Future<AuthResult> register({
    required String fullName,
    required String email,
    required String password,
    required String phone,
    required String role,
    String? storeName,
  }) async {
    try {
      // TODO: Replace with real API call
      await Future.delayed(const Duration(milliseconds: 1000));

      final user = UserModel(
        id: 'new-user-${DateTime.now().millisecondsSinceEpoch}',
        fullName: fullName,
        email: email,
        phone: phone,
        role: role,
        storeName: storeName,
        createdAt: DateTime.now(),
      );

      _currentUser = user;
      _isAuthenticated = true;
      await _persistSession(user);
      return AuthResult.success(user);
    } catch (e) {
      return AuthResult.failure(e.toString());
    }
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await _clearSession(prefs);
  }
}

class AuthResult {
  final bool success;
  final UserModel? user;
  final String? errorMessage;

  const AuthResult._({required this.success, this.user, this.errorMessage});

  factory AuthResult.success(UserModel user) =>
      AuthResult._(success: true, user: user);

  factory AuthResult.failure(String message) =>
      AuthResult._(success: false, errorMessage: message);
}
