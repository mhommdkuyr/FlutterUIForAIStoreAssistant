import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/repositories/sale_repository.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/stat_card.dart';

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  _Period _period = _Period.week;
  final _saleRepo = SaleRepository();

  bool _isLoading = true;
  double _revenue = 0;
  double _profit = 0;
  double _expenses = 0;
  int _transactions = 0;
  List<Map<String, dynamic>> _dailySeries = [];
  List<Map<String, dynamic>> _bestSellers = [];
  List<Map<String, dynamic>> _categoryData = [];

  @override
  void initState() {
    super.initState();
    _loadAnalytics();
  }

  Future<void> _loadAnalytics() async {
    setState(() => _isLoading = true);
    try {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final DateTime from;
      switch (_period) {
        case _Period.week:
          from = today.subtract(const Duration(days: 6));
        case _Period.month:
          from = today.subtract(const Duration(days: 29));
        case _Period.year:
          from = today.subtract(const Duration(days: 364));
      }
      final to = today.add(const Duration(days: 1));

      final results = await Future.wait([
        _saleRepo.getRevenueForPeriod(from, to),
        _saleRepo.getProfitForPeriod(from, to),
        _saleRepo.getTransactionCountForPeriod(from, to),
        _saleRepo.getDailyRevenueSeries(7),
        _saleRepo.getBestSellersForPeriod(from, to),
        _saleRepo.getCategoryBreakdownForPeriod(from, to),
      ]);

      if (!mounted) return;
      final revenue = results[0] as double;
      final profit = results[1] as double;
      setState(() {
        _revenue = revenue;
        _profit = profit;
        _expenses = (revenue - profit).clamp(0, double.infinity);
        _transactions = results[2] as int;
        _dailySeries = results[3] as List<Map<String, dynamic>>;
        _bestSellers = results[4] as List<Map<String, dynamic>>;
        _categoryData = results[5] as List<Map<String, dynamic>>;
      });
    } catch (_) {
      // keep previous values on error; user will see zeros on first load
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _fmt(double amount) {
    if (amount >= 1000000) {
      return 'YER ${(amount / 1000000).toStringAsFixed(1)}M';
    } else if (amount >= 1000) {
      return 'YER ${(amount / 1000).toStringAsFixed(0)}K';
    }
    return 'YER ${amount.toStringAsFixed(0)}';
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Analytics')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(AppConstants.paddingMD),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Period selector
                  Row(
                    children: _Period.values.map((p) {
                      final active = _period == p;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(p.label),
                          selected: active,
                          selectedColor: AppColors.primary,
                          labelStyle:
                              TextStyle(color: active ? Colors.white : null),
                          onSelected: (_) {
                            setState(() => _period = p);
                            _loadAnalytics();
                          },
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),

                  // KPI cards
                  GridView.count(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 1.4,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      StatCard(
                        label: 'Revenue',
                        value: _fmt(_revenue),
                        icon: Icons.payments_rounded,
                        color: AppColors.primary,
                        change: null,
                      ),
                      StatCard(
                        label: 'Profit',
                        value: _fmt(_profit),
                        icon: Icons.trending_up_rounded,
                        color: AppColors.accent,
                        change: null,
                      ),
                      StatCard(
                        label: 'Expenses',
                        value: _fmt(_expenses),
                        icon: Icons.receipt_rounded,
                        color: AppColors.error,
                        change: null,
                        isPositiveChange: false,
                      ),
                      StatCard(
                        label: 'Transactions',
                        value: '$_transactions',
                        icon: Icons.swap_horiz_rounded,
                        color: const Color(0xFF7C3AED),
                        change: null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // Revenue chart — always last 7 days
                  Text('Revenue vs Profit (Last 7 Days)',
                      style: textTheme.titleMedium),
                  const SizedBox(height: 12),
                  AppCard(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      height: 200,
                      child: _dailySeries.isEmpty
                          ? const Center(child: Text('No sales data yet'))
                          : LineChart(
                              LineChartData(
                                gridData: FlGridData(
                                  show: true,
                                  drawVerticalLine: false,
                                  getDrawingHorizontalLine: (v) => FlLine(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .outline
                                        .withOpacity(0.5),
                                    strokeWidth: 1,
                                  ),
                                ),
                                titlesData: FlTitlesData(
                                  bottomTitles: AxisTitles(
                                    sideTitles: SideTitles(
                                      showTitles: true,
                                      getTitlesWidget: (v, meta) {
                                        const days = [
                                          'M',
                                          'T',
                                          'W',
                                          'T',
                                          'F',
                                          'S',
                                          'S'
                                        ];
                                        final idx = v.toInt();
                                        if (idx < 0 || idx >= days.length) {
                                          return const SizedBox.shrink();
                                        }
                                        return Text(days[idx],
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelSmall);
                                      },
                                      reservedSize: 20,
                                    ),
                                  ),
                                  leftTitles: const AxisTitles(
                                      sideTitles:
                                          SideTitles(showTitles: false)),
                                  topTitles: const AxisTitles(
                                      sideTitles:
                                          SideTitles(showTitles: false)),
                                  rightTitles: const AxisTitles(
                                      sideTitles:
                                          SideTitles(showTitles: false)),
                                ),
                                borderData: FlBorderData(show: false),
                                lineBarsData: [
                                  LineChartBarData(
                                    spots: _dailySeries
                                        .map((d) => FlSpot(
                                              d['day'] as double,
                                              d['revenue'] as double,
                                            ))
                                        .toList(),
                                    isCurved: true,
                                    color: AppColors.primary,
                                    barWidth: 2.5,
                                    dotData: const FlDotData(show: false),
                                    belowBarData: BarAreaData(
                                      show: true,
                                      color:
                                          AppColors.primary.withOpacity(0.08),
                                    ),
                                  ),
                                  LineChartBarData(
                                    spots: _dailySeries
                                        .map((d) => FlSpot(
                                              d['day'] as double,
                                              d['profit'] as double,
                                            ))
                                        .toList(),
                                    isCurved: true,
                                    color: AppColors.accent,
                                    barWidth: 2.5,
                                    dotData: const FlDotData(show: false),
                                    belowBarData: BarAreaData(
                                      show: true,
                                      color:
                                          AppColors.accent.withOpacity(0.08),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Best sellers
                  Text('Best Sellers', style: textTheme.titleMedium),
                  const SizedBox(height: 12),
                  _bestSellers.isEmpty
                      ? AppCard(
                          padding: const EdgeInsets.all(16),
                          child: const Center(
                              child: Text('No sales data for this period')),
                        )
                      : Column(
                          children: _bestSellers
                              .asMap()
                              .entries
                              .map((e) => Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: _BestSellerRow(
                                        rank: e.key + 1, data: e.value),
                                  ))
                              .toList(),
                        ),
                  const SizedBox(height: 20),

                  // Category breakdown (pie chart)
                  Text('Sales by Category', style: textTheme.titleMedium),
                  const SizedBox(height: 12),
                  AppCard(
                    padding: const EdgeInsets.all(16),
                    child: _categoryData.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(16),
                            child: Center(
                                child:
                                    Text('No sales data for this period')),
                          )
                        : Row(
                            children: [
                              SizedBox(
                                width: 140,
                                height: 140,
                                child: PieChart(
                                  PieChartData(
                                    sections: _categoryData
                                        .asMap()
                                        .entries
                                        .map((e) => PieChartSectionData(
                                              value:
                                                  e.value['pct'] as double,
                                              color: AppColors.chartColors[
                                                  e.key %
                                                      AppColors
                                                          .chartColors.length],
                                              radius: 50,
                                              title:
                                                  '${(e.value['pct'] as double).toStringAsFixed(0)}%',
                                              titleStyle: const TextStyle(
                                                  fontSize: 11,
                                                  color: Colors.white,
                                                  fontWeight:
                                                      FontWeight.w700),
                                            ))
                                        .toList(),
                                    centerSpaceRadius: 20,
                                    sectionsSpace: 2,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: _categoryData
                                      .asMap()
                                      .entries
                                      .map((e) => Padding(
                                            padding: const EdgeInsets.only(
                                                bottom: 6),
                                            child: Row(
                                              children: [
                                                Container(
                                                  width: 10,
                                                  height: 10,
                                                  decoration: BoxDecoration(
                                                    color: AppColors
                                                            .chartColors[
                                                        e.key %
                                                            AppColors
                                                                .chartColors
                                                                .length],
                                                    shape: BoxShape.circle,
                                                  ),
                                                ),
                                                const SizedBox(width: 6),
                                                Expanded(
                                                    child: Text(
                                                        e.value['label']
                                                            as String,
                                                        style: textTheme
                                                            .bodySmall)),
                                                Text(
                                                    '${(e.value['pct'] as double).toStringAsFixed(0)}%',
                                                    style: textTheme
                                                        .labelSmall),
                                              ],
                                            ),
                                          ))
                                      .toList(),
                                ),
                              ),
                            ],
                          ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
    );
  }
}

class _BestSellerRow extends StatelessWidget {
  const _BestSellerRow({required this.rank, required this.data});
  final int rank;
  final Map<String, dynamic> data;

  String _fmtRevenue(double amount) {
    if (amount >= 1000000) {
      return 'YER ${(amount / 1000000).toStringAsFixed(1)}M';
    } else if (amount >= 1000) {
      return 'YER ${(amount / 1000).toStringAsFixed(0)}K';
    }
    return 'YER ${amount.toStringAsFixed(0)}';
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final revenue = data['revenue'] as double;
    final units = data['units'] as int;
    return AppCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: rank == 1
                  ? const Color(0xFFFFD700).withOpacity(0.15)
                  : rank == 2
                      ? const Color(0xFFC0C0C0).withOpacity(0.15)
                      : rank == 3
                          ? const Color(0xFFCD7F32).withOpacity(0.15)
                          : AppColors.primary.withOpacity(0.08),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                '#$rank',
                style: textTheme.labelSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
              child: Text(data['name'] as String,
                  style: textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w500))),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _fmtRevenue(revenue),
                style: textTheme.titleSmall?.copyWith(
                    color: AppColors.primary, fontWeight: FontWeight.w700),
              ),
              Text('$units units', style: textTheme.bodySmall),
            ],
          ),
        ],
      ),
    );
  }
}

enum _Period {
  week,
  month,
  year;

  String get label {
    switch (this) {
      case week:
        return 'This Week';
      case month:
        return 'This Month';
      case year:
        return 'This Year';
    }
  }
}
