import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'server_config.dart';

@Deprecated('Usar GeometryService de geometry_service.dart')
class GraphHopperService {
  GraphHopperService._();
  static final GraphHopperService instance = GraphHopperService._();

  // ============================================================================
  // RUTAS PEATONALES (reemplaza OSRM foot)
  // ============================================================================

  /// Obtiene una ruta peatonal entre dos puntos
  Future<GraphHopperRoute?> getFootRoute(
    LatLng origin,
    LatLng destination,
  ) async {
    try {
      final baseUrl = ServerConfig.instance.baseUrl;
      final url = Uri.parse(
        '$baseUrl/api/route/walking'
        '?origin_lat=${origin.latitude}&origin_lon=${origin.longitude}'
        '&dest_lat=${destination.latitude}&dest_lon=${destination.longitude}',
      );

      print('🚶 [GraphHopper] Solicitando ruta peatonal');
      print('🚶 De: ${origin.latitude},${origin.longitude}');
      print('🚶 A: ${destination.latitude},${destination.longitude}');

      final response = await http
          .get(url)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException('GraphHopper timeout'),
          );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['geometry'] != null) {
          return GraphHopperRoute.fromJson(data);
        }
      }

      print('⚠️ [GraphHopper] Error HTTP: ${response.statusCode}');
    } catch (e) {
      print('❌ [GraphHopper] Error: $e');
    }

    return null;
  }

  // ============================================================================
  // TRANSPORTE PÚBLICO (GTFS completo - 400+ líneas Santiago)
  // ============================================================================

  /// Obtiene rutas con transporte público (GTFS completo)
  Future<List<GraphHopperTransitRoute>> getPublicTransitRoutes(
    LatLng origin,
    LatLng destination, {
    DateTime? departureTime,
    int maxWalkDistance = 1000,
  }) async {
    try {
      final baseUrl = ServerConfig.instance.baseUrl;
      final url = Uri.parse('$baseUrl/api/route/transit');

      final departure =
          departureTime ?? DateTime.now().add(const Duration(minutes: 2));

      final body = json.encode({
        'origin': {'lat': origin.latitude, 'lon': origin.longitude},
        'destination': {
          'lat': destination.latitude,
          'lon': destination.longitude,
        },
        'departure_time': departure.toIso8601String(),
        'max_walk_distance': maxWalkDistance,
      });

      print('🚌 [GraphHopper] Solicitando rutas de transporte público');

      final response = await http
          .post(url, headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['alternatives'] != null) {
          final alternatives = data['alternatives'] as List;
          return alternatives
              .map((alt) => GraphHopperTransitRoute.fromJson(alt))
              .toList();
        }
      }

      print('⚠️ [GraphHopper] Error HTTP: ${response.statusCode}');
    } catch (e) {
      print('❌ [GraphHopper] Error: $e');
    }

    return [];
  }

  // ============================================================================
  // OPCIONES DE RUTA (LIGERO - Sin geometría)
  // ============================================================================

  /// Obtiene opciones de ruta SIN geometría completa
  /// Ideal para presentar opciones al usuario por voz ANTES de cargar geometría
  Future<List<RouteOption>> getRouteOptions(
    LatLng origin,
    LatLng destination,
  ) async {
    try {
      final baseUrl = ServerConfig.instance.baseUrl;
      final url = Uri.parse('$baseUrl/api/route/options');

      final body = json.encode({
        'origin': {'lat': origin.latitude, 'lon': origin.longitude},
        'destination': {
          'lat': destination.latitude,
          'lon': destination.longitude,
        },
      });

      print('� [GraphHopper] Solicitando opciones de ruta (ligero)');

      final response = await http
          .post(url, headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['options'] != null) {
          final options = data['options'] as List;
          return options.map((opt) => RouteOption.fromJson(opt)).toList();
        }
      }

      print('⚠️ [GraphHopper] Error HTTP: ${response.statusCode}');
    } catch (e) {
      print('❌ [GraphHopper] Error: $e');
    }

    return [];
  }
}

// ============================================================================
// MODELOS DE DATOS
// ============================================================================

/// Opción de ruta ligera (sin geometría completa)
/// Para presentar opciones al usuario por voz
class RouteOption {
  final String type; // 'walking' o 'transit'
  final double distanceMeters;
  final int durationSeconds;
  final int? transfers;
  final List<String>? routes; // Números de bus/metro
  final String description; // Descripción legible por voz

  RouteOption({
    required this.type,
    required this.distanceMeters,
    required this.durationSeconds,
    this.transfers,
    this.routes,
    required this.description,
  });

  factory RouteOption.fromJson(Map<String, dynamic> json) {
    List<String>? routes;
    if (json['routes'] != null) {
      routes = (json['routes'] as List).map((r) => r.toString()).toList();
    }

    return RouteOption(
      type: json['type'] as String,
      distanceMeters: (json['distance_meters'] as num).toDouble(),
      durationSeconds: (json['duration_seconds'] as num).toInt(),
      transfers: (json['transfers'] as num?)?.toInt(),
      routes: routes,
      description: json['description'] as String,
    );
  }

  String get durationText {
    final minutes = (durationSeconds / 60).round();
    return '$minutes min';
  }

  String get distanceText {
    if (distanceMeters < 1000) {
      return '${distanceMeters.round()} m';
    }
    return '${(distanceMeters / 1000).toStringAsFixed(1)} km';
  }
}

/// Ruta peatonal simple de GraphHopper
class GraphHopperRoute {
  final double distanceMeters;
  final int durationSeconds;
  final List<LatLng> geometry;
  final List<RouteInstruction> instructions;

  GraphHopperRoute({
    required this.distanceMeters,
    required this.durationSeconds,
    required this.geometry,
    required this.instructions,
  });

  factory GraphHopperRoute.fromJson(Map<String, dynamic> json) {
    // Parsear geometría
    final geometryData = json['geometry'] as List;
    final geometry = geometryData
        .map((coord) => LatLng(coord[1] as double, coord[0] as double))
        .toList();

    // Parsear instrucciones
    final instructionsData = json['instructions'] as List?;
    final instructions =
        instructionsData
            ?.map((inst) => RouteInstruction.fromJson(inst))
            .toList() ??
        [];

    return GraphHopperRoute(
      distanceMeters: (json['distance_meters'] as num).toDouble(),
      durationSeconds: (json['duration_seconds'] as num).toInt(),
      geometry: geometry,
      instructions: instructions,
    );
  }
}

/// Instrucción de navegación
class RouteInstruction {
  final String text;
  final double distance;
  final int time;
  final String? streetName;

  RouteInstruction({
    required this.text,
    required this.distance,
    required this.time,
    this.streetName,
  });

  factory RouteInstruction.fromJson(Map<String, dynamic> json) {
    return RouteInstruction(
      text: json['text'] as String,
      distance: (json['distance'] as num).toDouble(),
      time: (json['time'] as num).toInt(),
      streetName: json['street_name'] as String?,
    );
  }
}

/// Ruta con transporte público (GTFS)
class GraphHopperTransitRoute {
  final double distanceMeters;
  final int durationSeconds;
  final int transfers;
  final List<TransitLeg> legs;

  GraphHopperTransitRoute({
    required this.distanceMeters,
    required this.durationSeconds,
    required this.transfers,
    required this.legs,
  });

  factory GraphHopperTransitRoute.fromJson(Map<String, dynamic> json) {
    final legsData = json['legs'] as List;
    final legs = legsData.map((leg) => TransitLeg.fromJson(leg)).toList();

    return GraphHopperTransitRoute(
      distanceMeters: (json['distance_meters'] as num).toDouble(),
      durationSeconds: (json['duration_seconds'] as num).toInt(),
      transfers: (json['transfers'] as num?)?.toInt() ?? 0,
      legs: legs,
    );
  }
}

/// Segmento del viaje (caminata o transporte público)
class TransitLeg {
  final String type; // 'walk' o 'pt'
  final double distance;
  final List<LatLng> geometry;

  // Para PT
  final String? routeShortName;
  final String? routeLongName;
  final String? headsign;
  final DateTime? departureTime;
  final DateTime? arrivalTime;
  final int? numStops;
  final List<TransitStop>? stops;

  // Para walk
  final List<RouteInstruction>? instructions;

  TransitLeg({
    required this.type,
    required this.distance,
    required this.geometry,
    this.routeShortName,
    this.routeLongName,
    this.headsign,
    this.departureTime,
    this.arrivalTime,
    this.numStops,
    this.stops,
    this.instructions,
  });

  factory TransitLeg.fromJson(Map<String, dynamic> json) {
    // Parsear geometría
    final geometryData = json['geometry'] as List;
    final geometry = geometryData
        .map((coord) => LatLng(coord[1] as double, coord[0] as double))
        .toList();

    // Parsear paradas (si es PT)
    List<TransitStop>? stops;
    if (json['stops'] != null) {
      final stopsData = json['stops'] as List;
      stops = stopsData.map((s) => TransitStop.fromJson(s)).toList();
    }

    // Parsear instrucciones (si es walk)
    List<RouteInstruction>? instructions;
    if (json['instructions'] != null) {
      final instData = json['instructions'] as List;
      instructions = instData.map((i) => RouteInstruction.fromJson(i)).toList();
    }

    return TransitLeg(
      type: json['type'] as String,
      distance: (json['distance'] as num).toDouble(),
      geometry: geometry,
      routeShortName: json['route_short_name'] as String?,
      routeLongName: json['route_long_name'] as String?,
      headsign: json['headsign'] as String?,
      departureTime: json['departure_time'] != null
          ? DateTime.parse(json['departure_time'] as String)
          : null,
      arrivalTime: json['arrival_time'] != null
          ? DateTime.parse(json['arrival_time'] as String)
          : null,
      numStops: (json['num_stops'] as num?)?.toInt(),
      stops: stops,
      instructions: instructions,
    );
  }
}

/// Parada de transporte público
class TransitStop {
  final String name;
  final double lat;
  final double lon;
  final int sequence;

  TransitStop({
    required this.name,
    required this.lat,
    required this.lon,
    required this.sequence,
  });

  factory TransitStop.fromJson(Map<String, dynamic> json) {
    return TransitStop(
      name: json['name'] as String,
      lat: (json['lat'] as num).toDouble(),
      lon: (json['lon'] as num).toDouble(),
      sequence: (json['sequence'] as num).toInt(),
    );
  }
}
