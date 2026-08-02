import 'package:intl/intl.dart';

class AppDateUtils {
  AppDateUtils._();

  static String formatDate(DateTime date) =>
      DateFormat('dd MMM yyyy').format(date);

  static String formatDateTime(DateTime date) =>
      DateFormat('dd MMM yyyy • HH:mm').format(date);

  static String formatTime(DateTime date) => DateFormat('HH:mm').format(date);

  static String formatCurrency(double amount, {String symbol = 'YER'}) =>
      '$symbol ${NumberFormat('#,##0.00').format(amount)}';

  static String formatNumber(num value) => NumberFormat('#,##0').format(value);

  static String relativeTime(DateTime date) {
    final diff = DateTime.now().difference(date);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return formatDate(date);
  }

  static bool isToday(DateTime date) {
    final now = DateTime.now();
    return date.year == now.year &&
        date.month == now.month &&
        date.day == now.day;
  }

  /// Returns ThemeMode recommendation based on device time:
  /// Dark mode between 20:00 and 07:00.
  static bool shouldUseDarkModeByTime() {
    final hour = DateTime.now().hour;
    return hour >= 20 || hour < 7;
  }
}
