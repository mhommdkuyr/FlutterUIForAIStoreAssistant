import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../shared/services/auth_service.dart';
import '../constants/app_constants.dart';

/// Route guard that redirects unauthenticated users to login
/// and enforces role-based access control.
class AuthGuard {
  const AuthGuard._();

  /// Returns a redirect path if the user is not allowed to access [state.uri],
  /// or null to allow access.
  static String? redirect(BuildContext context, GoRouterState state) {
    final authService = AuthService.instance;
    final isLoggedIn = authService.isAuthenticated;
    final currentPath = state.uri.path;

    // Public routes that don't require authentication
    const publicRoutes = [
      '/splash',
      '/welcome',
      '/account-type',
      '/login',
      '/register'
    ];
    final isPublic = publicRoutes.any((r) => currentPath.startsWith(r));

    if (!isLoggedIn && !isPublic) {
      return '/login';
    }
    if (isLoggedIn && isPublic && currentPath != '/splash') {
      return _homeForRole(authService.currentRole);
    }
    return null;
  }

  /// Returns the home route for a given role.
  static String _homeForRole(String? role) {
    switch (role) {
      case AppConstants.roleMerchant:
        return '/merchant/dashboard';
      case AppConstants.roleWorker:
        return '/worker/dashboard';
      case AppConstants.roleCustomer:
        return '/customer/search';
      default:
        return '/account-type';
    }
  }

  /// Checks whether the current user has the required role.
  static bool hasRole(String requiredRole) {
    return AuthService.instance.currentRole == requiredRole;
  }

  /// Checks whether the current user has any of the given roles.
  static bool hasAnyRole(List<String> roles) {
    return roles.contains(AuthService.instance.currentRole);
  }
}
