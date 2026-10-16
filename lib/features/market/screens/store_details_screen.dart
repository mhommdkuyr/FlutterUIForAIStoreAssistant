import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/market_models.dart';

class StoreDetailsScreen extends StatelessWidget {
  const StoreDetailsScreen({
    super.key,
    required this.store,
    required this.offers,
  });

  final MarketStore store;
  final List<MarketOffer> offers;

  Future<void> _open(BuildContext context, Uri uri) async {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر فتح الرابط.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final phone = store.phone ?? store.whatsapp;
    return Scaffold(
      appBar: AppBar(title: Text(store.nameAr)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            leading: const CircleAvatar(
              radius: 28,
              child: Icon(Icons.store_rounded),
            ),
            title: Text(store.nameAr),
            subtitle: Text(store.address ?? store.city),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (phone != null)
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _open(
                      context,
                      Uri(scheme: 'tel', path: phone),
                    ),
                    icon: const Icon(Icons.call_rounded),
                    label: const Text('اتصال'),
                  ),
                ),
              if (phone != null && store.whatsapp != null)
                const SizedBox(width: 8),
              if (store.whatsapp != null)
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _open(
                      context,
                      Uri.parse(
                        'https://wa.me/' + store.whatsapp!,
                      ),
                    ),
                    icon: const Icon(Icons.chat_rounded),
                    label: const Text('واتساب'),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: () => _open(
              context,
              Uri.parse(
                'https://www.google.com/maps/dir/?api=1&destination=' +
                    store.latitude.toString() +
                    ',' +
                    store.longitude.toString(),
              ),
            ),
            icon: const Icon(Icons.directions_rounded),
            label: const Text('الاتجاهات'),
          ),
          const SizedBox(height: 20),
          Text(
            'المنتجات والأسعار',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          ...offers.map(
            (offer) => Card(
              child: ListTile(
                title: Text(offer.product.nameAr),
                subtitle: Text(offer.available ? 'متوفر' : 'غير متوفر'),
                trailing: Text(
                  offer.price.toStringAsFixed(0) +
                      ' ' +
                      offer.currency,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
