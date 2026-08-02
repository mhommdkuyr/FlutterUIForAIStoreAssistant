import '../constants/app_strings.dart';

class AppValidators {
  AppValidators._();

  static String? required(String? value, [String? fieldName]) {
    if (value == null || value.trim().isEmpty) {
      return fieldName != null
          ? '$fieldName is required.'
          : AppStrings.fieldRequired;
    }
    return null;
  }

  static String? email(String? value) {
    if (value == null || value.trim().isEmpty) return AppStrings.fieldRequired;
    final emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
    if (!emailRegex.hasMatch(value.trim())) return AppStrings.invalidEmail;
    return null;
  }

  static String? password(String? value) {
    if (value == null || value.isEmpty) return AppStrings.fieldRequired;
    if (value.length < 8) return AppStrings.passwordTooShort;
    return null;
  }

  static String? confirmPassword(String? value, String original) {
    final err = password(value);
    if (err != null) return err;
    if (value != original) return AppStrings.passwordMismatch;
    return null;
  }

  static String? phone(String? value) {
    if (value == null || value.trim().isEmpty) return AppStrings.fieldRequired;
    final phoneRegex = RegExp(r'^\+?[0-9]{7,15}$');
    if (!phoneRegex.hasMatch(value.trim()))
      return 'Please enter a valid phone number.';
    return null;
  }

  static String? positiveNumber(String? value, [String? label]) {
    if (value == null || value.trim().isEmpty) return AppStrings.fieldRequired;
    final n = double.tryParse(value.trim());
    if (n == null) return '${label ?? 'Value'} must be a number.';
    if (n <= 0) return '${label ?? 'Value'} must be greater than zero.';
    return null;
  }

  static String? nonNegativeInteger(String? value, [String? label]) {
    if (value == null || value.trim().isEmpty) return AppStrings.fieldRequired;
    final n = int.tryParse(value.trim());
    if (n == null) return '${label ?? 'Value'} must be a whole number.';
    if (n < 0) return '${label ?? 'Value'} cannot be negative.';
    return null;
  }
}
