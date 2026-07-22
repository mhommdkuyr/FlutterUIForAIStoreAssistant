import 'package:flutter/material.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/repositories/debt_repository.dart';
import '../../../shared/repositories/repository_exceptions.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/custom_button.dart';
import '../../../shared/widgets/custom_text_field.dart';
import '../../../shared/widgets/loading_overlay.dart';

class DebtsScreen extends StatefulWidget {
  const DebtsScreen({super.key});

  @override
  State<DebtsScreen> createState() => _DebtsScreenState();
}

class _DebtsScreenState extends State<DebtsScreen> {
  final DebtRepository _repository = DebtRepository();
  final List<_DebtEntry> _debts = [];
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadDebts();
  }

  Future<void> _loadDebts() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final debts = await _repository.getDebts();
      setState(() {
        _debts.clear();
        _debts.addAll(debts.map((debt) => _DebtEntry(
              id: debt.id,
              customerName: debt.customerName,
              originalAmount: debt.originalAmount,
              paidAmount: debt.totalPaid,
              date: debt.createdAt,
              note: debt.note,
            )));
      });
    } on RepositoryException catch (e) {
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  double get _totalDebt => _debts.fold(0, (s, d) => s + d.remaining);

  void _showAddDebtDialog() {
    final nameCtrl = TextEditingController();
    final amountCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.viewInsetsOf(ctx).bottom + 20),
        child: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Add Debt', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              CustomTextField(
                label: 'Customer Name',
                hint: 'Full name',
                controller: nameCtrl,
                validator: (v) => (v?.isEmpty ?? true) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              CustomTextField(
                label: 'Amount (YER)',
                hint: '0',
                controller: amountCtrl,
                keyboardType: TextInputType.number,
                validator: (v) {
                  if (v?.isEmpty ?? true) return 'Required';
                  if (double.tryParse(v!) == null) return 'Must be a number';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              CustomTextField(
                label: 'Note (optional)',
                hint: 'e.g. Grocery purchase',
                controller: noteCtrl,
              ),
              const SizedBox(height: 20),
              CustomButton(
                label: 'Add Debt',
                onPressed: () async {
                  if (formKey.currentState?.validate() ?? false) {
                    try {
                      await _repository.createDebt(
                        customerName: nameCtrl.text.trim(),
                        amount: double.parse(amountCtrl.text),
                        note: noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim(),
                      );
                      if (!mounted) return;
                      Navigator.pop(ctx);
                      await _loadDebts();
                    } on RepositoryException catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppColors.error));
                    }
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _recordPayment(_DebtEntry debt) {
    final amountCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Record Payment for ${debt.customerName}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Remaining: YER ${debt.remaining.toStringAsFixed(0)}'),
            const SizedBox(height: 12),
            TextField(
              controller: amountCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Payment amount (YER)'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final amount = double.tryParse(amountCtrl.text);
              if (amount != null && amount > 0) {
                try {
                  await _repository.recordPayment(debt.id, amount);
                  if (!mounted) return;
                  Navigator.pop(ctx);
                  await _loadDebts();
                } on RepositoryException catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppColors.error));
                }
              }
            },
            child: const Text('Record'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Debt Management')),
      body: Column(
        children: [
          // Summary banner
          Container(
            margin: const EdgeInsets.all(AppConstants.paddingMD),
            padding: const EdgeInsets.all(AppConstants.paddingMD),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppColors.error, Color(0xFFDC2626)],
              ),
              borderRadius: BorderRadius.circular(AppConstants.radiusLarge),
            ),
            child: Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Total Outstanding Debt', style: textTheme.bodySmall?.copyWith(color: Colors.white70)),
                    Text(
                      'YER ${_totalDebt.toStringAsFixed(0).replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',')}',
                      style: textTheme.headlineMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                    Text('${_debts.where((d) => d.remaining > 0).length} customers with debt', style: textTheme.bodySmall?.copyWith(color: Colors.white70)),
                  ],
                ),
                const Spacer(),
                const Icon(Icons.account_balance_wallet_rounded, color: Colors.white54, size: 48),
              ],
            ),
          ),

          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppConstants.paddingMD),
              child: Text(_errorMessage!, style: const TextStyle(color: AppColors.error)),
            ),
          // Debt list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _debts.isEmpty
                    ? EmptyState(icon: Icons.people_outline_rounded, title: 'No debts recorded', subtitle: 'All customers are paid up.')
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: AppConstants.paddingMD),
                        itemCount: _debts.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (ctx, i) => _DebtTile(debt: _debts[i], onPay: () => _recordPayment(_debts[i])),
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddDebtDialog,
        backgroundColor: AppColors.error,
        icon: const Icon(Icons.person_add_rounded, color: Colors.white),
        label: const Text('Add Debt', style: TextStyle(color: Colors.white)),
      ),
    );
  }
}

class _DebtTile extends StatelessWidget {
  const _DebtTile({required this.debt, required this.onPay});
  final _DebtEntry debt;
  final VoidCallback onPay;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final isPaid = debt.remaining <= 0;

    return AppCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: (isPaid ? AppColors.success : AppColors.error).withOpacity(0.12),
                child: Text(
                  debt.customerName.substring(0, 1).toUpperCase(),
                  style: textTheme.titleSmall?.copyWith(color: isPaid ? AppColors.success : AppColors.error),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(debt.customerName, style: textTheme.titleSmall),
                    if (debt.note != null) Text(debt.note!, style: textTheme.bodySmall),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: (isPaid ? AppColors.success : AppColors.error).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(AppConstants.radiusFull),
                    ),
                    child: Text(
                      isPaid ? 'Paid' : 'Unpaid',
                      style: textTheme.labelSmall?.copyWith(color: isPaid ? AppColors.success : AppColors.error),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'YER ${debt.remaining.toStringAsFixed(0)}',
                    style: textTheme.titleSmall?.copyWith(
                      color: isPaid ? AppColors.success : AppColors.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (!isPaid) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: debt.paidAmount / debt.originalAmount,
              backgroundColor: AppColors.error.withOpacity(0.12),
              valueColor: const AlwaysStoppedAnimation(AppColors.success),
              borderRadius: BorderRadius.circular(AppConstants.radiusFull),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Paid: YER ${debt.paidAmount.toStringAsFixed(0)}', style: textTheme.bodySmall),
                Text('Original: YER ${debt.originalAmount.toStringAsFixed(0)}', style: textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 36,
              child: ElevatedButton(
                onPressed: onPay,
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 36),
                  backgroundColor: AppColors.success,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Record Payment'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DebtEntry {
  final String id;
  final String customerName;
  final double originalAmount;
  final double paidAmount;
  final DateTime date;
  final String? note;

  const _DebtEntry({
    required this.id, required this.customerName, required this.originalAmount,
    required this.paidAmount, required this.date, this.note,
  });

  double get remaining => (originalAmount - paidAmount).clamp(0, double.infinity);

  _DebtEntry withPayment(double amount) => _DebtEntry(
        id: id, customerName: customerName, originalAmount: originalAmount,
        paidAmount: (paidAmount + amount).clamp(0, originalAmount),
        date: date, note: note,
      );
}

final _demoDebts = [
  _DebtEntry(id: '1', customerName: 'Ahmed Al-Mansoori', originalAmount: 5400, paidAmount: 2000, date: DateTime.now().subtract(const Duration(days: 5))),
  _DebtEntry(id: '2', customerName: 'Fatima Hassan', originalAmount: 1200, paidAmount: 0, date: DateTime.now().subtract(const Duration(days: 2))),
  _DebtEntry(id: '3', customerName: 'Mohammed Al-Yemeni', originalAmount: 3000, paidAmount: 3000, date: DateTime.now().subtract(const Duration(days: 10))),
  _DebtEntry(id: '4', customerName: 'Sara Nasser', originalAmount: 800, paidAmount: 500, date: DateTime.now().subtract(const Duration(days: 1)), note: 'Groceries purchase'),
];
