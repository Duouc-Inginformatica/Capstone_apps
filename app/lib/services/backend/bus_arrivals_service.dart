import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;

class BusArrival {
  final String routeNumber;
  final String direction;
  final double distanceKm;
  final int estimatedMinutes;
  final String estimatedTime;
  final String status;

  BusArrival({
    required this.routeNumber,
    required this.direction,
    required this.distanceKm,
    required this.estimatedMinutes,
    required this.estimatedTime,
    required this.status,
  });

  factory BusArrival.fromJson(Map<String, dynamic> json) {
    return BusArrival(
      routeNumber: json['route_number'] ?? '',
      direction: json['direction'] ?? '',
      distanceKm: (json['distance_km'] ?? 0.0).toDouble(),
      estimatedMinutes: json['estimated_minutes'] ?? 0,
      estimatedTime: json['estimated_time'] ?? '',
      status: json['status'] ?? '',
    );
  }

  String get formattedTime {
    if (estimatedMinutes <= 0) return 'Llegando ahora';
    if (estimatedMinutes == 1) return '1 minuto';
    if (estimatedMinutes < 60) return '$estimatedMinutes minutos';

    final hours = estimatedMinutes ~/ 60;
    final mins = estimatedMinutes % 60;
    if (mins == 0) return '$hours ${hours == 1 ? "hora" : "horas"}';
    return '$hours ${hours == 1 ? "hora" : "horas"} y $mins minutos';
  }

  String get formattedDistance {
    if (distanceKm < 0.1) return '${(distanceKm * 1000).round()} metros';
    if (distanceKm < 1.0) return '${(distanceKm * 1000).round()} metros';
    return '${distanceKm.toStringAsFixed(1)} km';
  }

  String get announcement {
    String announcement = 'Bus $routeNumber';
    if (direction.isNotEmpty) {
      announcement += ' hacia $direction';
    }
    announcement += ', a $formattedDistance';
    announcement += ', llegará en $formattedTime';
    return announcement;
  }
}

class StopArrivals {
  final String stopCode;
  final String stopName;
  final List<BusArrival> arrivals;
  final DateTime lastUpdated;

  StopArrivals({
    required this.stopCode,
    required this.stopName,
    required this.arrivals,
    required this.lastUpdated,
  });

  factory StopArrivals.fromJson(Map<String, dynamic> json) {
    return StopArrivals(
      stopCode: json['stop_code'] ?? '',
      stopName: json['stop_name'] ?? '',
      arrivals:
          (json['arrivals'] as List<dynamic>?)
              ?.map((e) => BusArrival.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      lastUpdated:
          DateTime.tryParse(json['last_updated'] ?? '') ?? DateTime.now(),
    );
  }

  String get arrivalsSummary {
    if (arrivals.isEmpty) {
      return 'No hay buses próximos en paradero $stopCode';
    }

    if (arrivals.length == 1) {
      return 'Hay 1 bus próximo en paradero $stopCode: ${arrivals[0].announcement}';
    }

    String summary =
        'Hay ${arrivals.length} buses próximos en paradero $stopCode. ';

    // Anunciar los 3 más cercanos
    final topArrivals = arrivals.take(3).toList();
    for (int i = 0; i < topArrivals.length; i++) {
      summary += '${i + 1}. ${topArrivals[i].announcement}. ';
    }

    if (arrivals.length > 3) {
      summary += 'Y ${arrivals.length - 3} buses más.';
    }

    return summary;
  }
}

class BusArrivalsService {
  static final BusArrivalsService instance = BusArrivalsService._();
  BusArrivalsService._();

  static const String baseUrl = 'http://192.168.1.156:8080/api';
  static const Duration timeout = Duration(seconds: 10);

  /// Obtiene las llegadas de buses para un paradero específico
  Future<StopArrivals?> getBusArrivals(String stopCode) async {
    developer.log('🚌 [ARRIVALS] Obteniendo llegadas para paradero: $stopCode');

    try {
      final url = Uri.parse('$baseUrl/bus-arrivals/$stopCode');
      developer.log('🌐 [ARRIVALS] URL: $url');

      final response = await http.get(url).timeout(timeout);

      developer.log('📡 [ARRIVALS] Status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final jsonData = json.decode(response.body) as Map<String, dynamic>;
        final arrivals = StopArrivals.fromJson(jsonData);

        developer.log(
          '✅ [ARRIVALS] ${arrivals.arrivals.length} buses encontrados para ${arrivals.stopCode}',
        );

        return arrivals;
      } else if (response.statusCode == 404) {
        developer.log(
          '⚠️ [ARRIVALS] No se encontraron llegadas para paradero $stopCode',
        );
        return null;
      } else {
        developer.log(
          '❌ [ARRIVALS] Error del servidor: ${response.statusCode} - ${response.body}',
        );
        return null;
      }
    } catch (e) {
      developer.log('❌ [ARRIVALS] Error obteniendo llegadas: $e');
      return null;
    }
  }

  /// Obtiene las llegadas para el paradero más cercano a una ubicación
  Future<StopArrivals?> getBusArrivalsByLocation(
    double latitude,
    double longitude, {
    int radius = 200,
  }) async {
    developer.log('🚌 [ARRIVALS] Obteniendo llegadas cerca de ($latitude, $longitude)');

    try {
      final url = Uri.parse('$baseUrl/bus-arrivals/nearby');
      developer.log('🌐 [ARRIVALS] URL: $url');

      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'latitude': latitude,
              'longitude': longitude,
              'radius': radius,
            }),
          )
          .timeout(timeout);

      developer.log('📡 [ARRIVALS] Status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final jsonData = json.decode(response.body) as Map<String, dynamic>;
        final arrivals = StopArrivals.fromJson(jsonData);

        developer.log('✅ [ARRIVALS] ${arrivals.arrivals.length} buses encontrados');

        return arrivals;
      } else if (response.statusCode == 501) {
        developer.log('⚠️ [ARRIVALS] Endpoint no implementado aún');
        return null;
      } else {
        developer.log('❌ [ARRIVALS] Error: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      developer.log('❌ [ARRIVALS] Error: $e');
      return null;
    }
  }
}
