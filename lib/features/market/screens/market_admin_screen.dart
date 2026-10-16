import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../services/market_backend.dart';

class MarketAdminScreen extends StatefulWidget {
  const MarketAdminScreen({super.key});

  @override
  State<MarketAdminScreen> createState() => _MarketAdminScreenState();
}

class _MarketAdminScreenState extends State<MarketAdminScreen> {
  final _backend = MarketBackend.instance;
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _stats;
  List<Map<String, dynamic>> _claims = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    if (!_backend.isConfigured) {
      setState(() {
        _loading = false;
        _error =
            'لم يتم ربط Supabase. هذه الصفحة تحتاج قاعدة بيانات السوق.';
      });
      return;
    }

    try {
      final statsRows = await _backend.callRpc('admin_market_stats', {});
      final claims = await _backend.callRpc('admin_pending_claims', {});
      if (!mounted) return;
      setState(() {
        _stats = statsRows.isEmpty ? null : statsRows.first;
        _claims = claims;
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error =
              'تم رفض صلاحيات الإدارة أو تعذر الاتصال: ' + error.toString();
        });
      }
    }
  }

  Future<void> _setClaimStatus(String id, String status) async {
    try {
      await _backend.callRpc('admin_set_claim_status', {
        'p_claim_id': id,
        'p_status': status,
      });
      await _load();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تحديث الطلب: ' + error.toString())),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    return Scaffold(
      appBar: AppBar(
        title: const Text('إدارة محرك السوق'),
        actions: [
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(AppConstants.paddingMD),
                children: [
                  if (_error != null)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.lock_outline_rounded),
                        title: const Text('صلاحيات الإدارة'),
                        subtitle: Text(
                          _error! +
                              '\nيجب ضبط app_metadata.role = admin للمستخدم الإداري.',
                        ),
                      ),
                    ),
                  if (stats != null) ...[
                    Text(
                      'حالة قاعدة بيانات السوق',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    GridView.count(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisCount: 2,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1.45,
                      children: [
                        _Stat(
                          label: 'المتاجر النشطة',
                          value: (stats['active_stores'] ?? 0).toString(),
                        ),
                        _Stat(
                          label: 'المنتجات',
                          value: (stats['active_products'] ?? 0).toString(),
                        ),
                        _Stat(
                          label: 'العروض',
                          value: (stats['active_offers'] ?? 0).toString(),
                        ),
                        _Stat(
                          label: 'أسعار محدثة ≤ 7 أيام',
                          value:
                              (stats['fresh_offers_7d'] ?? 0).toString(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Card(
                      child: ListTile(
                        leading: Icon(Icons.map_outlined),
                        title: Text('التغطية الجغرافية'),
                        subtitle: Text(
                          'التغطية الفعلية تُقاس عبر أدوات OSM/Google وملفات التدقيق؛ '
                          'خلايا التغطية لا تعني اكتمال كل المحلات.',
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    'طلبات إثبات ملكية المتاجر (' +
                        _claims.length.toString() +
                        ')',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  if (_claims.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('لا توجد طلبات معلقة.'),
                      ),
                    )
                  else
                    ..._claims.map(
                      (claim) => Card(
                        child: ListTile(
                          title: Text(
                            (claim['store_name_ar'] ?? 'متجر بدون اسم')
                                .toString(),
                          ),
                          subtitle: Text(
                            'المستخدم: ' +
                                (claim['user_id'] ?? '—').toString(),
                          ),
                          trailing: Wrap(
                            children: [
                              IconButton(
                                tooltip: 'اعتماد',
                                onPressed: () => _setClaimStatus(
                                  claim['id'].toString(),
                                  'approved',
                                ),
                                icon:
                                    const Icon(Icons.check_circle_outline),
                              ),
                              IconButton(
                                tooltip: 'رفض',
                                onPressed: () => _setClaimStatus(
                                  claim['id'].toString(),
                                  'rejected',
                                ),
                                icon: const Icon(Icons.cancel_outlined),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              value,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 4),
            Text(label, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
