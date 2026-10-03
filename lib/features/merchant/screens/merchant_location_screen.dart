import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../market/services/market_location_service.dart';
import '../../market/widgets/osm_map_view.dart';

class MerchantLocationScreen extends StatefulWidget {
  const MerchantLocationScreen({super.key});

  @override
  State<MerchantLocationScreen> createState() => _MerchantLocationScreenState();
}

class _MerchantLocationScreenState extends State<MerchantLocationScreen> {
  static const latKey = 'market.merchant.latitude';
  static const lonKey = 'market.merchant.longitude';
  final location = MarketLocationService();

  double? lat;
  double? lon;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      lat = p.getDouble(latKey);
      lon = p.getDouble(lonKey);
      loading = false;
    });
  }

  Future<void> _capture() async {
    final position = await location.currentPosition();
    if (!mounted) return;
    if (position == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر الحصول على موقع الجهاز.')),
      );
      return;
    }

    final p = await SharedPreferences.getInstance();
    await p.setDouble(latKey, position.latitude);
    await p.setDouble(lonKey, position.longitude);
    if (!mounted) return;
    setState(() {
      lat = position.latitude;
      lon = position.longitude;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final mapLat = lat ?? 13.9667;
    final mapLon = lon ?? 44.1833;

    return Scaffold(
      appBar: AppBar(title: const Text('موقع المتجر')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'حدد موقع الفرع بدقة ليظهر في نتائج المتاجر القريبة.',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 360,
            child: OsmMapView(
              latitude: mapLat,
              longitude: mapLon,
              stores: const [],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            lat == null
                ? 'لم يُحفظ موقع.'
                : lat!.toStringAsFixed(6) +
                    ', ' +
                    lon!.toStringAsFixed(6),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _capture,
            icon: const Icon(Icons.gps_fixed_rounded),
            label: const Text('استخدم موقعي الحالي'),
          ),
        ],
      ),
    );
  }
}
