import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utilities/app_date_utils.dart';
import '../../../shared/repositories/product_repository.dart';
import '../../../shared/models/sale_model.dart';
import '../../../shared/repositories/sale_repository.dart';
import '../../../shared/services/auth_service.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/stat_card.dart';

class MerchantDashboardScreen extends StatefulWidget {
  const MerchantDashboardScreen({super.key});

  @override
  State<MerchantDashboardScreen> createState() => _MerchantDashboardScreenState();
}

class _MerchantDashboardScreenState extends State<MerchantDashboardScreen> {
  int _navIndex = 0;

  final _tabs = const [
    _DashboardTab(),
    _PlaceholderTab(label: 'Inventory', icon: Icons.inventory_2_rounded, route: '/inventory'),
    _PlaceholderTab(label: 'Sales', icon: Icons.receipt_long_rounded, route: '/sales'),
    _PlaceholderTab(label: 'Analytics', icon: Icons.bar_chart_rounded, route: '/analytics'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _navIndex, children: _tabs),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _navIndex,
        onTap: (i) {
          if (i == 0) { setState(() => _navIndex = 0); return; }
          // Navigate to full screens for other tabs
          switch (i) {
            case 1: context.push('/inventory');
            case 2: context.push('/sales');
            case 3: context.push('/analytics');
          }
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.dashboard_rounded), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.inventory_2_rounded), label: 'Inventory'),
          BottomNavigationBarItem(icon: Icon(Icons.receipt_long_rounded), label: 'Sales'),
          BottomNavigationBarItem(icon: Icon(Icons.bar_chart_rounded), label: 'Analytics'),
        ],
      ),
    );
  }
}

class _DashboardTab extends StatefulWidget {
  const _DashboardTab();

  @override
  State<_DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<_DashboardTab> {
  final ProductRepository _productRepository = ProductRepository();
  final SaleRepository _saleRepository = SaleRepository();
  int _inventoryCount = 0;
  int _lowStockCount = 0;
  double _todayRevenue = 0;
  double _todayProfit = 0;
  List<SaleModel> _recentSales = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadMetrics();
  }

  Future<void> _loadMetrics() async {
    setState(() => _isLoading = true);
    try {
      final results = await Future.wait([
        _productRepository.getInventoryCount(),
        _productRepository.getLowStockCount(),
        _saleRepository.getTodayRevenue(),
        _saleRepository.getTodayProfit(),
        _saleRepository.getRecentSales(),
      ]);
      if (!mounted) return;
      setState(() {
        _inventoryCount = results[0] as int;
        _lowStockCount = results[1] as int;
        _todayRevenue = results[2] as double;
        _todayProfit = results[3] as double;
        _recentSales = results[4] as List<SaleModel>;
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = AuthService.instance.currentUser;
    final textTheme = Theme.of(context).textTheme;
    final greeting = _greeting();

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // App bar
          SliverAppBar(
            expandedHeight: 140,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppColors.primary, AppColors.primaryDark],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(20, 56, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$greeting,',
                      style: textTheme.bodyLarge?.copyWith(color: Colors.white70),
                    ),
                    Text(
                      user?.fullName ?? 'Merchant',
                      style: textTheme.headlineSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.notifications_outlined, color: Colors.white),
                onPressed: () {},
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined, color: Colors.white),
                onPressed: () => context.push('/settings'),
              ),
            ],
          ),

          SliverPadding(
            padding: const EdgeInsets.all(AppConstants.paddingMD),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                // Date
                Text(
                  AppDateUtils.formatDate(DateTime.now()),
                  style: textTheme.bodySmall,
                ),
                const SizedBox(height: 16),

                // Stats grid
                _isLoading
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : GridView.count(
                        crossAxisCount: 2,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        childAspectRatio: 1.4,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          StatCard(
                            label: AppStrings.todaySales,
                            value: 'YER ${_todayRevenue.toStringAsFixed(0)}',
                            icon: Icons.trending_up_rounded,
                            color: AppColors.primary,
                            change: null,
                          ),
                          StatCard(
                            label: AppStrings.todayProfit,
                            value: 'YER ${_todayProfit.toStringAsFixed(0)}',
                            icon: Icons.attach_money_rounded,
                            color: AppColors.accent,
                            change: null,
                          ),
                          StatCard(
                            label: AppStrings.inventory,
                            value: '$_inventoryCount items',
                            icon: Icons.inventory_2_rounded,
                            color: const Color(0xFF7C3AED),
                            change: null,
                          ),
                          StatCard(
                            label: AppStrings.lowStock,
                            value: '$_lowStockCount products',
                            icon: Icons.warning_amber_rounded,
                            color: AppColors.warning,
                            change: null,
                            isPositiveChange: false,
                          ),
                        ],
                      ),
                const SizedBox(height: 20),

                // Quick actions
                Text(AppStrings.quickActions, style: textTheme.titleMedium),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _QuickAction(
                      label: 'New Sale',
                      icon: Icons.add_shopping_cart_rounded,
                      color: AppColors.primary,
                      onTap: () => context.push('/sales'),
                    ),
                    const SizedBox(width: 12),
                    _QuickAction(
                      label: 'Scan Product',
                      icon: Icons.qr_code_scanner_rounded,
                      color: const Color(0xFF7C3AED),
                      onTap: () => context.push('/scanner'),
                    ),
                    const SizedBox(width: 12),
                    _QuickAction(
                      label: 'AI Assistant',
                      icon: Icons.psychology_rounded,
                      color: AppColors.accentOrange,
                      onTap: () => context.push('/ai-assistant'),
                    ),
                    const SizedBox(width: 12),
                    _QuickAction(
                      label: 'Add Debt',
                      icon: Icons.person_add_rounded,
                      color: AppColors.error,
                      onTap: () => context.push('/debts'),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // AI Recommendations
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(AppStrings.aiRecommendations, style: textTheme.titleMedium),
                    TextButton(
                      onPressed: () => context.push('/ai-assistant'),
                      child: const Text(AppStrings.viewAll),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const _AiRecommendationCard(
                  message: '📦 Rice (5kg) is running low (8 units). Consider ordering at least 50 bags before the weekend rush.',
                ),
                const SizedBox(height: 8),
                const _AiRecommendationCard(
                  message: '📈 Cooking Oil sales are up 24% this week. You could increase the price slightly for better margins.',
                ),
                const SizedBox(height: 20),

                // Recent transactions
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(AppStrings.recentTransactions, style: textTheme.titleMedium),
                    TextButton(onPressed: () => context.push('/sales'), child: const Text(AppStrings.viewAll)),
                  ],
                ),
                const SizedBox(height: 8),
                if (_recentSales.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No transactions yet',
                      style: textTheme.bodySmall,
                    ),
                  )
                else
                  ..._recentSales.map((s) => _TransactionTile(data: {
                        'label': 'Sale — ${s.items.length} item${s.items.length == 1 ? '' : 's'}',
                        'time': AppDateUtils.relativeTime(s.createdAt),
                        'amount': '+YER ${s.total.toStringAsFixed(0)}',
                      })),
                const SizedBox(height: 24),
              ]),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/ai-assistant'),
        backgroundColor: AppColors.primary,
        icon: const Icon(Icons.psychology_rounded, color: Colors.white),
        label: const Text('AI Assistant', style: TextStyle(color: Colors.white)),
      ),
    );
  }

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }
}

class _PlaceholderTab extends StatelessWidget {
  const _PlaceholderTab({required this.label, required this.icon, required this.route});
  final String label;
  final IconData icon;
  final String route;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(label)),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 64, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => context.push(route),
                child: Text('Open $label'),
              ),
            ],
          ),
        ),
      );
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
            border: Border.all(color: color.withOpacity(0.2)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(height: 4),
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AiRecommendationCard extends StatelessWidget {
  const _AiRecommendationCard({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: AppColors.accentOrange.withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.psychology_rounded, color: AppColors.accentOrange, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _TransactionTile extends StatelessWidget {
  const _TransactionTile({required this.data});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.receipt_rounded, color: AppColors.primary, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(data['label'] as String, style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                  Text(data['time'] as String, style: textTheme.bodySmall),
                ],
              ),
            ),
            Text(
              data['amount'] as String,
              style: textTheme.titleSmall?.copyWith(
                color: AppColors.success,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

