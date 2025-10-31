import 'package:latlong2/latlong.dart';

/// Modelo simple de paradero usado por la UI
class BusStop {
  final String name;
  final LatLng location;
  final String? code;

  BusStop({required this.name, required this.location, this.code});

  factory BusStop.fromMap(Map<String, dynamic> json) {
    final lat =
        (json['latitude'] as num?)?.toDouble() ??
        (json['lat'] as num?)?.toDouble() ??
        0.0;
    final lng =
        (json['longitude'] as num?)?.toDouble() ??
        (json['lng'] as num?)?.toDouble() ??
        0.0;
    return BusStop(
      name: json['name'] as String? ?? json['stop_name'] as String? ?? '',
      location: LatLng(lat, lng),
      code: json['code'] as String? ?? json['stop_code'] as String?,
    );
  }
}
