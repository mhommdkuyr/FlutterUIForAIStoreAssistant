import 'package:flutter/material.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/models/product_model.dart';
import '../../../shared/repositories/product_repository.dart';
import '../../../shared/repositories/repository_exceptions.dart';
import '../../../shared/repositories/sale_repository.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/custom_button.dart';

class SalesScreen extends StatefulWidget {
  const SalesScreen({super.key});

  @override
  State<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends State<SalesScreen> {
  final List<_CartItem> _cart = [];
  final _searchCtrl = TextEditingController();
  final ProductRepository _productRepository = ProductRepository();
  final SaleRepository _saleRepository = SaleRepository();
  List<ProductModel> _products = [];
  String _query = '';
  double _discount = 0;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  Future<void> _loadProducts() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final products = await _productRepository.getAllProducts(query: _query);
      setState(() => _products = products);
    } on RepositoryException catch (e) {
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  double get _subtotal => _cart.fold(0, (s, i) => s + i.totalPrice);
  double get _total => (_subtotal - _discount).clamp(0, double.infinity);

  void _addToCart(ProductModel product) {
    final idx = _cart.indexWhere((c) => c.id == product.id);
    if (idx >= 0) {
      setState(() => _cart[idx] = _cart[idx].increment());
    } else {
      setState(() => _cart.add(_CartItem(
            id: product.id,
            name: product.name,
            unitPrice: product.sellingPrice,
            quantity: 1,
          )));
    }
  }

  void _removeFromCart(String id) {
    setState(() => _cart.removeWhere((c) => c.id == id));
  }

  Future<void> _checkout() async {
    if (_cart.isEmpty) return;
    try {
      await _saleRepository.createSale(
        items: _cart.map((item) => ProductModel(
              id: item.id,
              name: item.name,
              category: 'Sale',
              purchasePrice: 0,
              sellingPrice: item.unitPrice,
              quantity: item.quantity,
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            )).toList(),
        discount: _discount,
        workerId: 'local-worker',
        paymentMethod: 'cash',
      );
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Sale Complete! 🎉'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${_cart.fold(0, (s, i) => s + i.quantity)} items sold'),
              const SizedBox(height: 8),
              Text('Total: ${_fmtAmount(_total)}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Print Receipt')),
            ElevatedButton(
              onPressed: () {
                setState(() { _cart.clear(); _discount = 0; });
                Navigator.pop(ctx);
              },
              child: const Text('New Sale'),
            ),
          ],
        ),
      );
    } on RepositoryException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppColors.error));
    }
  }

  String _fmtAmount(double v) => 'YER ${v.toStringAsFixed(0).replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',')}';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final filtered = _products.where((p) =>
        _query.isEmpty || p.name.toLowerCase().contains(_query.toLowerCase())).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('New Sale')),
      body: Column(
        children: [
          // Product search
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                hintText: 'Search products to add...',
                prefixIcon: Icon(Icons.search_rounded),
              ),
              onChanged: (v) {
                setState(() => _query = v);
                _loadProducts();
              },
            ),
          ),

          // Product grid
          SizedBox(
            height: 160,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(AppConstants.paddingMD),
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (ctx, i) => _ProductChip(product: filtered[i], onAdd: _addToCart),
            ),
          ),

          // Cart
          Expanded(
            child: _cart.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.shopping_cart_outlined, size: 56, color: Theme.of(context).colorScheme.outline),
                        const SizedBox(height: 12),
                        Text('Add products to start a sale', style: textTheme.bodyLarge),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _cart.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (ctx, i) => _CartTile(
                      item: _cart[i],
                      onIncrement: () => setState(() => _cart[i] = _cart[i].increment()),
                      onDecrement: () {
                        if (_cart[i].quantity <= 1) {
                          _removeFromCart(_cart[i].id);
                        } else {
                          setState(() => _cart[i] = _cart[i].decrement());
                        }
                      },
                      onRemove: () => _removeFromCart(_cart[i].id),
                    ),
                  ),
          ),

          // Summary + checkout
          if (_cart.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outline)),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Subtotal', style: textTheme.bodyMedium),
                      Text(_fmtAmount(_subtotal), style: textTheme.bodyMedium),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Discount', style: textTheme.bodySmall),
                      Text(_fmtAmount(_discount), style: textTheme.bodySmall?.copyWith(color: AppColors.error)),
                    ],
                  ),
                  const Divider(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Total', style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      Text(
                        _fmtAmount(_total),
                        style: textTheme.titleMedium?.copyWith(color: AppColors.primary, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  CustomButton(label: 'Checkout — ${_fmtAmount(_total)}', onPressed: _checkout),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ProductChip extends StatelessWidget {
  const _ProductChip({required this.product, required this.onAdd});
  final ProductModel product;
  final void Function(ProductModel) onAdd;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: () => onAdd(product),
      child: Container(
        width: 110,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Theme.of(context).cardTheme.color,
          borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
          border: Border.all(color: Theme.of(context).colorScheme.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.shopping_bag_outlined, color: AppColors.primary, size: 22),
            ),
            const Spacer(),
            Text(product.name, style: textTheme.labelSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text(
              'YER ${product.sellingPrice.toStringAsFixed(0)}',
              style: textTheme.labelSmall?.copyWith(color: AppColors.primary, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class _CartTile extends StatelessWidget {
  const _CartTile({required this.item, required this.onIncrement, required this.onDecrement, required this.onRemove});
  final _CartItem item;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return AppCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.name, style: textTheme.titleSmall),
                Text('YER ${item.unitPrice.toStringAsFixed(0)} each', style: textTheme.bodySmall),
              ],
            ),
          ),
          Row(
            children: [
              _CountBtn(icon: Icons.remove_rounded, onTap: onDecrement),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text('${item.quantity}', style: textTheme.titleSmall),
              ),
              _CountBtn(icon: Icons.add_rounded, onTap: onIncrement),
            ],
          ),
          const SizedBox(width: 16),
          Text(
            'YER ${item.totalPrice.toStringAsFixed(0)}',
            style: textTheme.titleSmall?.copyWith(color: AppColors.primary, fontWeight: FontWeight.w700),
          ),
          IconButton(icon: const Icon(Icons.close_rounded, size: 18), onPressed: onRemove),
        ],
      ),
    );
  }
}

class _CountBtn extends StatelessWidget {
  const _CountBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).colorScheme.outline),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(icon, size: 16),
      ),
    );
  }
}

class _CartItem {
  final String id;
  final String name;
  final double unitPrice;
  final int quantity;

  const _CartItem({required this.id, required this.name, required this.unitPrice, required this.quantity});
  double get totalPrice => unitPrice * quantity;
  _CartItem increment() => _CartItem(id: id, name: name, unitPrice: unitPrice, quantity: quantity + 1);
  _CartItem decrement() => _CartItem(id: id, name: name, unitPrice: unitPrice, quantity: quantity - 1);
}

