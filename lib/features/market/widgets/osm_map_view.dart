import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../models/market_models.dart';

class OsmMapView extends StatelessWidget {
  const OsmMapView({
    super.key,
    required this.latitude,
    required this.longitude,
    required this.stores,
    this.onStoreTap,
  });

  final double latitude;
  final double longitude;
  final List<MarketStore> stores;
  final ValueChanged<MarketStore>? onStoreTap;

  @override
  Widget build(BuildContext context) {
    final center = LatLng(latitude, longitude);
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: FlutterMap(
        options: MapOptions(
          initialCenter: center,
          initialZoom: 14,
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
          ),
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.yemeni.market.engine',
            maxZoom: 19,
          ),
          MarkerLayer(
            markers: [
              Marker(
                point: center,
                width: 42,
                height: 42,
                child: const Icon(
                  Icons.my_location_rounded,
                  color: Colors.blue,
                ),
              ),
              ...stores.map(
                (store) => Marker(
                  point: LatLng(store.latitude, store.longitude),
                  width: 44,
                  height: 44,
                  child: GestureDetector(
                    onTap: () => onStoreTap?.call(store),
                    child: const Icon(
                      Icons.location_on_rounded,
                      color: Colors.red,
                      size: 36,
                    ),
                  ),
                ),
              ),
            ],
          ),
          Positioned(
            left: 8,
            bottom: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface.withOpacity(.94),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                child: Text(
                  '© OpenStreetMap contributors',
                  style: TextStyle(fontSize: 10),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
