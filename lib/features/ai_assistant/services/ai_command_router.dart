import '../providers/ai_provider.dart';
import '../providers/llama_cpp_provider.dart';
import '../providers/rule_based_provider.dart';
import 'ai_context_service.dart';

/// Result returned by [AiCommandRouter.route].
/// [navRoute] is set when the message maps to an in-app navigation action.
class AiRouterResult {
  final String text;
  final String? navRoute;
  const AiRouterResult(this.text, {this.navRoute});
}

class AiCommandRouter {
  AiCommandRouter._();
  static final AiCommandRouter instance = AiCommandRouter._();

  final AiContextService _contextService = AiContextService.instance;

  final List<AiProvider> _providers = const [
    LlamaCppProvider(),
    RuleBasedProvider(),
  ];

  /// Maps a user message to a navigation route if it matches a known command.
  static String? _matchNavRoute(String message) {
    final m = message.trim().toLowerCase();

    // Live barcode scanner (cashier scan)
    if (_has(m, ['افتح المسح', 'ابدأ المسح', 'مسح الباركود', 'مسح حي',
        'المسح السريع', 'open scanner', 'start scan', 'barcode scan', 'live scan'])) {
      return '/scanner/live';
    }
    // Add to invoice / cart scan (checked before add-product)
    if (_has(m, ['أضف إلى الفاتورة', 'اضف الى الفاتورة', 'أضف للفاتورة',
        'اضف للفاتورة', 'أضف منتج للفاتورة',
        'add to invoice', 'add to cart', 'scan for sale'])) {
      return '/scanner/live';
    }
    // Add product
    if (_has(m, ['أضف منتج', 'إضافة منتج', 'منتج جديد', 'إضافة سلعة',
        'add product', 'new product'])) {
      return '/scanner';
    }
    // Debts
    if (_has(m, ['افتح الديون', 'اضف دين', 'أضف دين', 'ديون العملاء',
        'أنشئ دين', 'إضافة دين', 'ديون',
        'add debt', 'new debt', 'debts', 'debt'])) {
      return '/debts';
    }
    // Sales / invoice
    if (_has(m, ['افتح المبيعات', 'أنشئ فاتورة', 'فاتورة جديدة',
        'اذهب إلى المبيعات', 'فاتورة', 'مبيعات',
        'sales', 'invoice', 'checkout', 'new sale'])) {
      return '/sales';
    }
    // Analytics
    if (_has(m, ['افتح التحليل', 'افتح التقارير', 'عرض التقارير',
        'تحليل', 'تقارير', 'analytics', 'reports', 'statistics'])) {
      return '/analytics';
    }
    // Inventory / search product
    if (_has(m, ['افتح المخزون', 'افتح المنتجات', 'ابحث عن منتج',
        'ابحث عن', 'بحث منتج', 'عرض المنتجات',
        'المخزون', 'المنتجات', 'inventory', 'products', 'stock'])) {
      return '/inventory';
    }
    // Marketing
    if (_has(m, ['افتح التسويق', 'افتح العروض', 'تسويق', 'عروض',
        'marketing', 'promotions'])) {
      return '/marketing';
    }
    // Branches
    if (_has(m, ['افتح الفروع', 'فروع', 'الفروع', 'branches'])) {
      return '/branches';
    }
    return null;
  }

  static bool _has(String haystack, List<String> needles) =>
      needles.any((n) => haystack.contains(n));

  Future<AiRouterResult> route(String message, {bool isArabic = false}) async {
    // Check for navigation commands first (works fully offline).
    final navRoute = _matchNavRoute(message);
    if (navRoute != null) {
      final confirmation =
          isArabic ? 'جارٍ الانتقال...' : 'Opening that for you...';
      return AiRouterResult(confirmation, navRoute: navRoute);
    }

    final context = await _contextService.buildContext();
    for (final provider in _providers) {
      if (provider.isAvailable) {
        final text =
            await provider.respond(message, context, isArabic: isArabic);
        return AiRouterResult(text);
      }
    }

    return AiRouterResult(
      isArabic
          ? 'لا أستطيع معالجة طلبك الآن. حاول مرة أخرى.'
          : 'I\'m unable to process your request right now. Please try again.',
    );
  }

  void invalidateContext() => _contextService.invalidate();
}
