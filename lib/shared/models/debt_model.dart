enum DebtStatus { unpaid, partiallyPaid, paid }

class DebtPayment {
  final String id;
  final double amount;
  final DateTime paidAt;
  final String? note;

  const DebtPayment({
    required this.id,
    required this.amount,
    required this.paidAt,
    this.note,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'amount': amount,
        'paidAt': paidAt.toIso8601String(),
        'note': note,
      };
}

class DebtModel {
  final String id;
  final String customerId;
  final String customerName;
  final String? customerPhone;
  final double originalAmount;
  final List<DebtPayment> payments;
  final DateTime createdAt;
  final DateTime? dueDate;
  final String? note;
  final String? branchId;

  const DebtModel({
    required this.id,
    required this.customerId,
    required this.customerName,
    this.customerPhone,
    required this.originalAmount,
    this.payments = const [],
    required this.createdAt,
    this.dueDate,
    this.note,
    this.branchId,
  });

  double get totalPaid => payments.fold(0, (sum, p) => sum + p.amount);
  double get remaining => originalAmount - totalPaid;

  DebtStatus get status {
    if (remaining <= 0) return DebtStatus.paid;
    if (totalPaid > 0) return DebtStatus.partiallyPaid;
    return DebtStatus.unpaid;
  }

  bool get isOverdue =>
      dueDate != null &&
      dueDate!.isBefore(DateTime.now()) &&
      status != DebtStatus.paid;
}
