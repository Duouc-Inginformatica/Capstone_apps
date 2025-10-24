import 'dart:developer' as developer;
// ============================================================================
// Geometry Service - WayFindCL Flutter
// ============================================================================
// Servicio para cálculos geométricos usando endpoints del backend
// Proporciona: rutas peatonales, distancias, paradas cercanas
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:wayfindcl/services/backend/server_config.dart';

class GeometryService {
  GeometryService._();
  static final GeometryService instance = GeometryService._();

  // ============================================================================
  // GEOMETRÍA PEATONAL
  // ============================================================================

  /// Obtiene geometría de ruta peatonal (perfil foot)
  Future<WalkingGeometry?> getWalkingGeometry(
    LatLng origin,
    LatLng destination,
  ) async {
    try {
      final baseUrl = ServerConfig.instance.baseUrl;
      final url = Uri.parse(
        '$baseUrl/api/geometry/walking'
        '?origin_lat=${origin.latitude}'
        '&origin_lon=${origin.longitude}'
        '&dest_lat=${destination.latitude}'
        '&dest_lon=${destination.longitude}',
      );

      developer.log('🚶 [Geometry] Solicitando geometría peatonal');

      final response = await http
          .get(url)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException('Timeout'),
          );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return WalkingGeometry.fromJson(data);
      }

      developer.log('⚠️ [Geometry] Error HTTP: ${response.statusCode}');
    } catch (e) {
      developer.log('❌ [Geometry] Error: $e');
    }

    return null;
  }

  // ============================================================================
  // GEOMETRÍA VEHICULAR
  // ============================================================================

  /// Obtiene geometría de ruta vehicular (perfil car)
  Future<DrivingGeometry?> getDrivingGeometry(
    LatLng origin,
    LatLng destination,
  ) async {
    try {
      final baseUrl = ServerConfig.instance.baseUrl;
      final url = Uri.parse(
        '$baseUrl/api/geometry/driving'
        '?origin_lat=${origin.latitude}'
        '&origin_lon=${origin.longitude}'
        '&dest_lat=${destination.latitude}'
        '&dest_lon=${destination.longitude}',
      );

      developer.log('🚗 [Geometry] Solicitando geometría vehicular');

      final response = await http.get(url).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return DrivingGeometry.fromJson(data);
      }

      developer.log('⚠️ [Geometry] Error HTTP: ${response.statusCode}');
    } catch (e) {
      developer.log('❌ [Geometry] Error: $e');
    }

    return null;
  }

  // ============================================================================
  // GEOMETRÍA TRANSPORTE PÚBLICO
  // ============================================================================

  /// Obtiene geometría de transporte público (perfil PT + GTFS)
  Future<TransitGeometry?> getTransitGeometry(
    LatLng origin,
    LatLng destination, {
    DateTime? departureTime,
  }) async {
    try {
      final baseUrl = ServerConfig.instance.baseUrl;
      final url = Uri.parse('$baseUrl/api/geometry/transit');

      final departure =
          departureTime ?? DateTime.now().add(const Duration(minutes: 2));

      final body = json.encode({
        'origin_lat': origin.latitude,
        'origin_lon': origin.longitude,
        'dest_lat': destination.latitude,
        'dest_lon': destination.longitude,
        'departure_time': departure.toIso8601String(),
      });

      developer.log('🚌 [Geometry] Solicitando geometría de transporte público');

      final response = await http
          .post(url, headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return TransitGeometry.fromJson(data);
      }

      developer.log('⚠️ [Geometry] Error HTTP: ${response.statusCode}');
    } catch (e) {
      developer.log('❌ [Geometry] Error: $e');
    }

    return null;
  }

  // ============================================================================
  // PARADAS CERCANAS
  // ============================================================================

  /// Obtiene paradas cercanas con distancia REAL (cálculo geométrico)
  Future<List<NearbyStop>> getNearbyStops(
    LatLng location, {
    double radiusMeters = 500,
    int limit = 10,
  }) async {
    try {
      final baseUrl = ServerConfig.instance.baseUrl;
      final url = Uri.parse(
        '$baseUrl/api/geometry/stops/nearby'
        '?lat=${location.latitude}'
        '&lon=${location.longitude}'
        '&radius_meters=$radiusMeters'
        '&limit=$limit',
      );

      developer.log('📍 [Geometry] Buscando paradas cercanas');

      final response = await http.get(url).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final stops = data['stops'] as List;
        return stops.map((s) => NearbyStop.fromJson(s)).toList();
      }

      developer.log('⚠️ [Geometry] Error HTTP: ${response.statusCode}');
    } catch (e) {
      developer.log('❌ [Geometry] Error: $e');
    }

    return [];
  }

  // ============================================================================
  // CÁLCULO BATCH DE TIEMPOS
  // ============================================================================

  /// Calcula tiempos de caminata a múltiples destinos (optimizado)
  Future<Map<String, WalkingTime>> getBatchWalkingTimes(
    LatLng origin,
    List<LatLng> destinations,
  ) async {
    try {
      final baseUrl = ServerConfig.instance.baseUrl;
      final url = Uri.parse('$baseUrl/api/geometry/batch/walking-times');

      final body = json.encode({
        'origin_lat': origin.latitude,
        'origin_lon': origin.longitude,
        'destinations': destinations
            .map((d) => {'lat': d.latitude, 'lon': d.longitude})
            .toList(),
      });

      developer.log(
        '⏱️ [Geometry] Calculando tiempos batch (${destinations.length} destinos)',
      );

      final response = await http
          .post(url, headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(const Duration(seconds: 20));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final results = data['results'] as Map<String, dynamic>;

        return results.map(
          (key, value) => MapEntry(key, WalkingTime.fromJson(value)),
        );
      }

      developer.log('⚠️ [Geometry] Error HTTP: ${response.statusCode}');
    } catch (e) {
      developer.log('❌ [Geometry] Error: $e');
    }

    return {};
  }

  // ============================================================================
  // ISÓCRONA (ÁREA ALCANZABLE)
  // ============================================================================

  /// Obtiene polígono de área alcanzable en X minutos
  Future<IsochroneArea?> getIsochroneArea(
    LatLng origin, {
    int timeMinutes = 10,
    String profile = 'foot',
  }) async {
    try {
      final baseUrl = ServerConfig.instance.baseUrl;
      final url = Uri.parse(
        '$baseUrl/api/geometry/isochrone'
        '?lat=${origin.latitude}'
        '&lon=${origin.longitude}'
        '&time_minutes=$timeMinutes'
        '&profile=$profile',
      );

      developer.log('🗺️ [Geometry] Calculando isócrona ($timeMinutes min)');

      final response = await http.get(url).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return IsochroneArea.fromJson(data);
      }

      developer.log('⚠️ [Geometry] Error HTTP: ${response.statusCode}');
    } catch (e) {
      developer.log('❌ [Geometry] Error: $e');
    }

    return null;
  }
}

// ============================================================================
// MODELOS DE DATOS
// ============================================================================

/// Geometría de ruta peatonal
class WalkingGeometry {
  final List<LatLng> geometry;
  final double distanceMeters;
  final int durationSeconds;
  final List<Instruction> instructions;

  WalkingGeometry({
    required this.geometry,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.instructions,
  });

  factory WalkingGeometry.fromJson(Map<String, dynamic> json) {
    final geomData = json['geometry'] as List;
    final geometry = geomData
        .map((coord) => LatLng(coord[1] as double, coord[0] as double))
        .toList();

    final instData = json['instructions'] as List? ?? [];
    final instructions = instData.map((i) => Instruction.fromJson(i)).toList();

    return WalkingGeometry(
      geometry: geometry,
      distanceMeters: (json['distance_meters'] as num).toDouble(),
      durationSeconds: (json['duration_seconds'] as num).toInt(),
      instructions: instructions,
    );
  }

  String get durationText {
    final minutes = (durationSeconds / 60).ceil();
    return '$minutes min';
  }

  String get distanceText {
    if (distanceMeters < 1000) {
      return '${distanceMeters.round()} m';
    }
    return '${(distanceMeters / 1000).toStringAsFixed(1)} km';
  }
}

/// Geometría de ruta vehicular
class DrivingGeometry {
  final List<LatLng> geometry;
  final double distanceMeters;
  final int durationSeconds;

  DrivingGeometry({
    required this.geometry,
    required this.distanceMeters,
    required this.durationSeconds,
  });

  factory DrivingGeometry.fromJson(Map<String, dynamic> json) {
    final geomData = json['geometry'] as List;
    final geometry = geomData
        .map((coord) => LatLng(coord[1] as double, coord[0] as double))
        .toList();

    return DrivingGeometry(
      geometry: geometry,
      distanceMeters: (json['distance_meters'] as num).toDouble(),
      durationSeconds: (json['duration_seconds'] as num).toInt(),
    );
  }
}

/// Geometría de transporte público
class TransitGeometry {
  final List<TransitLeg> legs;
  final double totalDistanceMeters;
  final int totalDurationSeconds;
  final int transfers;

  TransitGeometry({
    required this.legs,
    required this.totalDistanceMeters,
    required this.totalDurationSeconds,
    required this.transfers,
  });

  factory TransitGeometry.fromJson(Map<String, dynamic> json) {
    final legsData = json['legs'] as List;
    final legs = legsData.map((l) => TransitLeg.fromJson(l)).toList();

    return TransitGeometry(
      legs: legs,
      totalDistanceMeters: (json['total_distance_meters'] as num).toDouble(),
      totalDurationSeconds: (json['total_duration_seconds'] as num).toInt(),
      transfers: (json['transfers'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Segmento de transporte público
class TransitLeg {
  final String type; // 'walk' o 'pt'
  final List<LatLng> geometry;
  final double distanceMeters;
  final int durationSeconds;

  // Para PT
  final String? routeShortName;
  final String? routeLongName;
  final String? headsign;
  final int? numStops;

  // Para walk
  final List<Instruction>? instructions;

  TransitLeg({
    required this.type,
    required this.geometry,
    required this.distanceMeters,
    required this.durationSeconds,
    this.routeShortName,
    this.routeLongName,
    this.headsign,
    this.numStops,
    this.instructions,
  });

  factory TransitLeg.fromJson(Map<String, dynamic> json) {
    final geomData = json['geometry'] as List;
    final geometry = geomData
        .map((coord) => LatLng(coord[1] as double, coord[0] as double))
        .toList();

    List<Instruction>? instructions;
    if (json['instructions'] != null) {
      final instData = json['instructions'] as List;
      instructions = instData.map((i) => Instruction.fromJson(i)).toList();
    }

    return TransitLeg(
      type: json['type'] as String,
      geometry: geometry,
      distanceMeters: (json['distance_meters'] as num).toDouble(),
      durationSeconds: (json['duration_seconds'] as num).toInt(),
      routeShortName: json['route_short_name'] as String?,
      routeLongName: json['route_long_name'] as String?,
      headsign: json['headsign'] as String?,
      numStops: (json['num_stops'] as num?)?.toInt(),
      instructions: instructions,
    );
  }
}

/// Instrucción de navegación
class Instruction {
  final String text;
  final double distanceMeters;
  final int durationSeconds;

  Instruction({
    required this.text,
    required this.distanceMeters,
    required this.durationSeconds,
  });

  factory Instruction.fromJson(Map<String, dynamic> json) {
    return Instruction(
      text: json['text'] as String,
      distanceMeters: (json['distance_meters'] as num).toDouble(),
      durationSeconds: (json['duration_seconds'] as num).toInt(),
    );
  }
}

/// Parada cercana con distancia real
class NearbyStop {
  final String stopId;
  final String stopName;
  final double lat;
  final double lon;
  final double distanceMeters;
  final int walkingTimeSeconds;

  NearbyStop({
    required this.stopId,
    required this.stopName,
    required this.lat,
    required this.lon,
    required this.distanceMeters,
    required this.walkingTimeSeconds,
  });

  factory NearbyStop.fromJson(Map<String, dynamic> json) {
    return NearbyStop(
      stopId: json['stop_id'] as String,
      stopName: json['stop_name'] as String,
      lat: (json['lat'] as num).toDouble(),
      lon: (json['lon'] as num).toDouble(),
      distanceMeters: (json['distance_meters'] as num).toDouble(),
      walkingTimeSeconds: (json['walking_time_seconds'] as num).toInt(),
    );
  }

  String get distanceText {
    if (distanceMeters < 1000) {
      return '${distanceMeters.round()} m';
    }
    return '${(distanceMeters / 1000).toStringAsFixed(1)} km';
  }

  String get walkingTimeText {
    final minutes = (walkingTimeSeconds / 60).ceil();
    return '$minutes min';
  }
}

/// Tiempo de caminata a un destino
class WalkingTime {
  final double distanceMeters;
  final int durationSeconds;

  WalkingTime({required this.distanceMeters, required this.durationSeconds});

  factory WalkingTime.fromJson(Map<String, dynamic> json) {
    return WalkingTime(
      distanceMeters: (json['distance_meters'] as num).toDouble(),
      durationSeconds: (json['duration_seconds'] as num).toInt(),
    );
  }
}

/// Área de isócrona (alcanzable en X minutos)
class IsochroneArea {
  final List<List<LatLng>> polygons;
  final int timeMinutes;
  final String profile;

  IsochroneArea({
    required this.polygons,
    required this.timeMinutes,
    required this.profile,
  });

  factory IsochroneArea.fromJson(Map<String, dynamic> json) {
    final polysData = json['polygons'] as List;
    final polygons = polysData.map((poly) {
      final coordsData = poly as List;
      return coordsData
          .map((coord) => LatLng(coord[1] as double, coord[0] as double))
          .toList();
    }).toList();

    return IsochroneArea(
      polygons: polygons,
      timeMinutes: (json['time_minutes'] as num).toInt(),
      profile: json['profile'] as String,
    );
  }
}
