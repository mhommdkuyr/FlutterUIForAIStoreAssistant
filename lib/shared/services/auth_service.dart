import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/user_model.dart';
import '../../core/constants/app_constants.dart';
import 'supabase_service.dart';

class AuthService {
  AuthService._();

  static final AuthService instance = AuthService._();

  UserModel? _currentUser;
  bool _isAuthenticated = false;

  UserModel? get currentUser => _currentUser;
  bool get isAuthenticated => _isAuthenticated;
  String? get currentRole => _currentUser?.role;
  String? get currentUserId => _currentUser?.id;

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final supabase = SupabaseService.instance.client;

    if (supabase != null) {
      final user = supabase.auth.currentUser;
      if (user != null) {
        _setSupabaseUser(user);
        await _persistSession(_currentUser!);
      } else {
        await _clearSession(prefs);
      }
      return;
    }

    final userJson = prefs.getString('_current_user');
    if (userJson == null) return;

    try {
      _currentUser =
          UserModel.fromJson(jsonDecode(userJson) as Map<String, dynamic>);
      _isAuthenticated = true;
    } catch (_) {
      await _clearSession(prefs);
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

  Future<AuthResult> login({
    required String email,
    required String password,
  }) async {
    try {
      final supabase = SupabaseService.instance.client;
      if (supabase != null) {
        final response = await supabase.auth.signInWithPassword(
          email: email,
          password: password,
        );
        final user = response.user;
        if (user == null) {
          return AuthResult.failure('تعذر تسجيل الدخول.');
        }

        _setSupabaseUser(user);
        await _persistSession(_currentUser!);
        return AuthResult.success(_currentUser!);
      }

      await Future.delayed(const Duration(milliseconds: 300));
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
    } on AuthException catch (error) {
      return AuthResult.failure(error.message);
    } catch (error) {
      return AuthResult.failure(error.toString());
    }
  }

  Future<AuthResult> register({
    required String fullName,
    required String email,
    required String password,
    required String phone,
    required String role,
    String? storeName,
  }) async {
    try {
      final supabase = SupabaseService.instance.client;
      if (supabase != null) {
        final response = await supabase.auth.signUp(
          email: email,
          password: password,
          data: {
            'full_name': fullName,
            'phone': phone,
            'role': role,
            'store_name': storeName,
          },
        );

        final user = response.user;
        if (user == null) {
          return AuthResult.failure('لم يتم إنشاء الحساب.');
        }

        if (response.session == null) {
          return AuthResult.failure(
            'تم إنشاء الحساب. تحقق من البريد الإلكتروني ثم سجّل الدخول.',
          );
        }

        _setSupabaseUser(user);
        await _persistSession(_currentUser!);
        return AuthResult.success(_currentUser!);
      }

      await Future.delayed(const Duration(milliseconds: 500));
      final user = UserModel(
        id: 'new-user-' + DateTime.now().millisecondsSinceEpoch.toString(),
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
    } on AuthException catch (error) {
      return AuthResult.failure(error.message);
    } catch (error) {
      return AuthResult.failure(error.toString());
    }
  }

  Future<void> logout() async {
    final supabase = SupabaseService.instance.client;
    if (supabase != null) {
      await supabase.auth.signOut();
    }

    final prefs = await SharedPreferences.getInstance();
    await _clearSession(prefs);
  }

  void _setSupabaseUser(User user) {
    final metadata = user.userMetadata ?? const <String, dynamic>{};
    final roleValue =
        metadata['role']?.toString() ?? AppConstants.roleCustomer;

    _currentUser = UserModel(
      id: user.id,
      fullName: metadata['full_name']?.toString() ??
          user.email?.split('@').first ??
          'مستخدم السوق',
      email: user.email ?? '',
      phone: metadata['phone']?.toString() ?? '',
      role: roleValue,
      storeName: metadata['store_name']?.toString(),
      createdAt: DateTime.tryParse(user.createdAt) ?? DateTime.now(),
    );
    _isAuthenticated = true;
  }
}

class AuthResult {
  final bool success;
  final UserModel? user;
  final String? errorMessage;

  const AuthResult._({
    required this.success,
    this.user,
    this.errorMessage,
  });

  factory AuthResult.success(UserModel user) =>
      AuthResult._(success: true, user: user);

  factory AuthResult.failure(String message) =>
      AuthResult._(success: false, errorMessage: message);
}
