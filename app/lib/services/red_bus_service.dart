// ============================================================================
// RED BUS SERVICE - Servicio para buses Red de Santiago
// ============================================================================
// Integra con Moovit scraping del backend para obtener:
// - Información de rutas de buses Red
// - Itinerarios con buses Red
// - Paradas y geometrías de rutas
// ============================================================================

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'api_client.dart';

class RedBusStop {
  final String name;
  final double latitude;
  final double longitude;
  final int sequence;

  RedBusStop({
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.sequence,
  });

  factory RedBusStop.fromJson(Map<String, dynamic> json) {
    return RedBusStop(
      name: json['name'] as String? ?? '',
      latitude: (json['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 0.0,
      sequence: json['sequence'] as int? ?? 0,
    );
  }

  LatLng get location => LatLng(latitude, longitude);
}

class RedBusRoute {
  final String routeNumber;
  final String routeName;
  final String direction;
  final List<RedBusStop> stops;
  final List<LatLng> geometry;
  final int durationMinutes;
  final double distanceKm;
  final String? firstService;
  final String? lastService;

  RedBusRoute({
    required this.routeNumber,
    required this.routeName,
    required this.direction,
    required this.stops,
    required this.geometry,
    required this.durationMinutes,
    required this.distanceKm,
    this.firstService,
    this.lastService,
  });

  factory RedBusRoute.fromJson(Map<String, dynamic> json) {
    final stopsData = json['stops'] as List<dynamic>? ?? [];
    final stops = stopsData
        .map((s) => RedBusStop.fromJson(s as Map<String, dynamic>))
        .toList();

    final geometryData = json['geometry'] as List<dynamic>? ?? [];
    final geometry = geometryData
        .map((coords) {
          final coordsList = coords as List<dynamic>;
          return LatLng(
            (coordsList[1] as num).toDouble(), // lat
            (coordsList[0] as num).toDouble(), // lon
          );
        })
        .toList();

    return RedBusRoute(
      routeNumber: json['route_number'] as String? ?? '',
      routeName: json['route_name'] as String? ?? '',
      direction: json['direction'] as String? ?? '',
      stops: stops,
      geometry: geometry,
      durationMinutes: json['duration_minutes'] as int? ?? 0,
      distanceKm: (json['distance_km'] as num?)?.toDouble() ?? 0.0,
      firstService: json['first_service'] as String?,
      lastService: json['last_service'] as String?,
    );
  }

  String get displayName => 'Red $routeNumber - $routeName';
  
  String get scheduleInfo {
    if (firstService != null && lastService != null) {
      return 'Horario: $firstService - $lastService';
    }
    return 'Horario: Consultar en paradero';
  }
}

class RedBusLeg {
  final String type; // "walk", "bus", "metro"
  final String mode; // "Red", "Metro", "walk"
  final String? routeNumber;
  final String from;
  final String to;
  final int durationMinutes;
  final double distanceKm;
  final String instruction;
  final List<LatLng>? geometry;
  final RedBusStop? departStop;
  final RedBusStop? arriveStop;

  RedBusLeg({
    required this.type,
    required this.mode,
    this.routeNumber,
    required this.from,
    required this.to,
    required this.durationMinutes,
    required this.distanceKm,
    required this.instruction,
    this.geometry,
    this.departStop,
    this.arriveStop,
  });

  factory RedBusLeg.fromJson(Map<String, dynamic> json) {
    List<LatLng>? geometry;
    if (json['geometry'] != null) {
      final geometryData = json['geometry'] as List<dynamic>;
      geometry = geometryData
          .map((coords) {
            final coordsList = coords as List<dynamic>;
            return LatLng(
              (coordsList[1] as num).toDouble(),
              (coordsList[0] as num).toDouble(),
            );
          })
          .toList();
    }

    RedBusStop? departStop;
    if (json['depart_stop'] != null) {
      departStop = RedBusStop.fromJson(json['depart_stop'] as Map<String, dynamic>);
    }

    RedBusStop? arriveStop;
    if (json['arrive_stop'] != null) {
      arriveStop = RedBusStop.fromJson(json['arrive_stop'] as Map<String, dynamic>);
    }

    return RedBusLeg(
      type: json['type'] as String? ?? 'walk',
      mode: json['mode'] as String? ?? 'walk',
      routeNumber: json['route_number'] as String?,
      from: json['from'] as String? ?? '',
      to: json['to'] as String? ?? '',
      durationMinutes: json['duration_minutes'] as int? ?? 0,
      distanceKm: (json['distance_km'] as num?)?.toDouble() ?? 0.0,
      instruction: json['instruction'] as String? ?? '',
      geometry: geometry,
      departStop: departStop,
      arriveStop: arriveStop,
    );
  }

  String get modeIcon {
    switch (type) {
      case 'walk':
        return '🚶';
      case 'bus':
        return '🚌';
      case 'metro':
        return '🚇';
      default:
        return '➡️';
    }
  }

  bool get isRedBus => mode == 'Red' && routeNumber != null;
}

class RedBusItinerary {
  final LatLng origin;
  final LatLng destination;
  final String departureTime;
  final String arrivalTime;
  final int totalDurationMinutes;
  final double totalDistanceKm;
  final List<RedBusLeg> legs;
  final List<String> redBusRoutes;

  RedBusItinerary({
    required this.origin,
    required this.destination,
    required this.departureTime,
    required this.arrivalTime,
    required this.totalDurationMinutes,
    required this.totalDistanceKm,
    required this.legs,
    required this.redBusRoutes,
  });

  factory RedBusItinerary.fromJson(Map<String, dynamic> json) {
    final originData = json['origin'] as Map<String, dynamic>;
    final destData = json['destination'] as Map<String, dynamic>;

    final legsData = json['legs'] as List<dynamic>? ?? [];
    final legs = legsData
        .map((l) => RedBusLeg.fromJson(l as Map<String, dynamic>))
        .toList();

    final routesData = json['red_bus_routes'] as List<dynamic>? ?? [];
    final routes = routesData.map((r) => r.toString()).toList();

    return RedBusItinerary(
      origin: LatLng(
        (originData['latitude'] as num).toDouble(),
        (originData['longitude'] as num).toDouble(),
      ),
      destination: LatLng(
        (destData['latitude'] as num).toDouble(),
        (destData['longitude'] as num).toDouble(),
      ),
      departureTime: json['departure_time'] as String? ?? '',
      arrivalTime: json['arrival_time'] as String? ?? '',
      totalDurationMinutes: json['total_duration_minutes'] as int? ?? 0,
      totalDistanceKm: (json['total_distance_km'] as num?)?.toDouble() ?? 0.0,
      legs: legs,
      redBusRoutes: routes,
    );
  }

  String get summary {
    final busCount = redBusRoutes.length;
    if (busCount == 0) {
      return 'Ruta a pie - $totalDurationMinutes min';
    } else if (busCount == 1) {
      return 'Bus Red ${redBusRoutes[0]} - $totalDurationMinutes min';
    } else {
      return '$busCount buses - $totalDurationMinutes min';
    }
  }

  List<String> getVoiceInstructions() {
    return legs.map((leg) {
      if (leg.isRedBus) {
        return '${leg.instruction}. Duración aproximada: ${leg.durationMinutes} minutos.';
      }
      return '${leg.instruction}. ${leg.durationMinutes} minutos caminando.';
    }).toList();
  }
}

class RedBusService {
  static final RedBusService instance = RedBusService._();
  RedBusService._();

  /// Obtiene información detallada de una ruta Red específica
  Future<RedBusRoute> getRedBusRoute(String routeNumber) async {
    try {
      final apiClient = ApiClient();
      final uri = Uri.parse('${apiClient.baseUrl}/api/red/route/$routeNumber');
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return RedBusRoute.fromJson(data);
      } else {
        throw Exception('Error al obtener ruta Red $routeNumber: ${response.statusCode}');
      }
    } catch (e) {
      print('Error en getRedBusRoute: $e');
      rethrow;
    }
  }

  /// Obtiene un itinerario completo usando buses Red
  Future<RedBusItinerary> getRedBusItinerary({
    required double originLat,
    required double originLon,
    required double destLat,
    required double destLon,
  }) async {
    try {
      final apiClient = ApiClient();
      final uri = Uri.parse('${apiClient.baseUrl}/api/red/itinerary');
      final body = {
        'origin_lat': originLat,
        'origin_lon': originLon,
        'dest_lat': destLat,
        'dest_lon': destLon,
      };

      print('🚌 Solicitando itinerario Red: origen($originLat, $originLon) -> destino($destLat, $destLon)');

      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final itinerary = RedBusItinerary.fromJson(data);
        print('✅ Itinerario Red obtenido: ${itinerary.summary}');
        return itinerary;
      } else {
        throw Exception('Error al obtener itinerario: ${response.statusCode}');
      }
    } catch (e) {
      print('❌ Error en getRedBusItinerary: $e');
      rethrow;
    }
  }

  /// Lista rutas Red comunes
  Future<List<Map<String, dynamic>>> getCommonRedRoutes() async {
    try {
      final apiClient = ApiClient();
      final uri = Uri.parse('${apiClient.baseUrl}/api/red/routes/common');
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final routes = data['routes'] as List<dynamic>;
        return routes.map((r) => r as Map<String, dynamic>).toList();
      } else {
        throw Exception('Error al obtener rutas comunes: ${response.statusCode}');
      }
    } catch (e) {
      print('Error en getCommonRedRoutes: $e');
      return [];
    }
  }

  /// Obtiene las paradas de una ruta Red
  Future<List<RedBusStop>> getRedBusStops(String routeNumber) async {
    try {
      final apiClient = ApiClient();
      final uri = Uri.parse('${apiClient.baseUrl}/api/red/route/$routeNumber/stops');
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final stopsData = data['stops'] as List<dynamic>;
        return stopsData
            .map((s) => RedBusStop.fromJson(s as Map<String, dynamic>))
            .toList();
      } else {
        throw Exception('Error al obtener paradas: ${response.statusCode}');
      }
    } catch (e) {
      print('Error en getRedBusStops: $e');
      return [];
    }
  }

  /// Obtiene la geometría de una ruta Red para visualización en mapa
  Future<Map<String, dynamic>> getRedBusGeometry(String routeNumber) async {
    try {
      final apiClient = ApiClient();
      final uri = Uri.parse('${apiClient.baseUrl}/api/red/route/$routeNumber/geometry');
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      } else {
        throw Exception('Error al obtener geometría: ${response.statusCode}');
      }
    } catch (e) {
      print('Error en getRedBusGeometry: $e');
      return {};
    }
  }

  /// Busca rutas Red por query
  Future<List<Map<String, dynamic>>> searchRedRoutes(String query) async {
    try {
      final apiClient = ApiClient();
      final uri = Uri.parse('${apiClient.baseUrl}/api/red/routes/search?q=$query');
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final results = data['results'] as List<dynamic>;
        return results.map((r) => r as Map<String, dynamic>).toList();
      } else {
        return [];
      }
    } catch (e) {
      print('Error en searchRedRoutes: $e');
      return [];
    }
  }
}
