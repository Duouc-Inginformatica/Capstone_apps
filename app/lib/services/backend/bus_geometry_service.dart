// ============================================================================
// Bus Geometry Service - WayFindCL Frontend
// ============================================================================
// Servicio para obtener geometría exacta de segmentos de rutas de bus
// Usa el nuevo endpoint del backend que consulta GTFS shapes
// ============================================================================

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../backend/api_client.dart';
import '../debug_logger.dart';

class BusGeometryService {
  static final BusGeometryService instance = BusGeometryService._();
  BusGeometryService._();

  final ApiClient _apiClient = ApiClient();

  /// Obtiene geometría exacta entre dos paraderos en una ruta de bus
  ///
  /// Usa GTFS shapes cuando están disponibles, con fallback a GraphHopper
  ///
  /// [routeNumber]: Número de ruta (ej: "506", "D09")
  /// [fromStopCode]: Código del paradero de origen (ej: "PC1237")
  /// [toStopCode]: Código del paradero de destino (ej: "PC615")
  /// [fromLat], [fromLon]: Coordenadas del origen (fallback si no hay código)
  /// [toLat], [toLon]: Coordenadas del destino (fallback si no hay código)
  Future<BusGeometryResult?> getBusSegmentGeometry({
    required String routeNumber,
    String? fromStopCode,
    String? toStopCode,
    double? fromLat,
    double? fromLon,
    double? toLat,
    double? toLon,
  }) async {
    try {
      DebugLogger.info(
        '🚌 [BUS-GEOMETRY] Solicitando geometría: Ruta $routeNumber',
        context: 'BusGeometryService',
      );
      DebugLogger.info(
        '   Desde: ${fromStopCode ?? "($fromLat, $fromLon)"}',
        context: 'BusGeometryService',
      );
      DebugLogger.info(
        '   Hasta: ${toStopCode ?? "($toLat, $toLon)"}',
        context: 'BusGeometryService',
      );

      final uri = Uri.parse('${_apiClient.baseUrl}/api/bus/geometry/segment');

      final body = {
        'route_number': routeNumber,
        if (fromStopCode != null) 'from_stop_code': fromStopCode,
        if (toStopCode != null) 'to_stop_code': toStopCode,
        if (fromLat != null) 'from_lat': fromLat,
        if (fromLon != null) 'from_lon': fromLon,
        if (toLat != null) 'to_lat': toLat,
        if (toLon != null) 'to_lon': toLon,
      };

      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );

      if (response.statusCode != 200) {
        DebugLogger.error(
          'Error del backend: ${response.statusCode}',
          context: 'BusGeometryService',
        );
        DebugLogger.error(
          'Response: ${response.body}',
          context: 'BusGeometryService',
        );
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final result = BusGeometryResult.fromJson(data);

      DebugLogger.success(
        '✅ Geometría obtenida desde ${result.source}',
        context: 'BusGeometryService',
      );
      DebugLogger.info(
        '   Puntos: ${result.geometry.length}',
        context: 'BusGeometryService',
      );
      DebugLogger.info(
        '   Distancia: ${result.distanceMeters.toStringAsFixed(0)}m',
        context: 'BusGeometryService',
      );
      DebugLogger.info(
        '   Paradas intermedias: ${result.numStops}',
        context: 'BusGeometryService',
      );

      return result;
    } catch (e, stackTrace) {
      DebugLogger.error(
        'Error obteniendo geometría de bus: $e',
        context: 'BusGeometryService',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// Valida que la geometría recibida sea válida
  bool isValidGeometry(List<LatLng> geometry) {
    if (geometry.isEmpty) {
      DebugLogger.warning('Geometría vacía', context: 'BusGeometryService');
      return false;
    }

    if (geometry.length < 2) {
      DebugLogger.warning(
        'Geometría con menos de 2 puntos: ${geometry.length}',
        context: 'BusGeometryService',
      );
      return false;
    }

    // Verificar que no todos los puntos sean iguales
    final first = geometry.first;
    final allSame = geometry.every(
      (p) => p.latitude == first.latitude && p.longitude == first.longitude,
    );

    if (allSame) {
      DebugLogger.warning(
        'Todos los puntos de la geometría son iguales',
        context: 'BusGeometryService',
      );
      return false;
    }

    return true;
  }
}

/// Resultado de la consulta de geometría de bus
class BusGeometryResult {
  final List<LatLng> geometry;
  final double distanceMeters;
  final int durationSeconds;
  final String source; // "gtfs_shape", "graphhopper", "fallback_straight_line"
  final BusStopInfo? fromStop;
  final BusStopInfo? toStop;
  final int numStops;

  BusGeometryResult({
    required this.geometry,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.source,
    this.fromStop,
    this.toStop,
    required this.numStops,
  });

  factory BusGeometryResult.fromJson(Map<String, dynamic> json) {
    final geometryRaw = json['geometry'] as List;
    final geometry = geometryRaw.map((point) {
      final coords = point as List;
      // Backend envía [lon, lat] (formato GeoJSON)
      return LatLng(
        (coords[1] as num).toDouble(), // lat
        (coords[0] as num).toDouble(), // lon
      );
    }).toList();

    return BusGeometryResult(
      geometry: geometry,
      distanceMeters: (json['distance_meters'] as num).toDouble(),
      durationSeconds: json['duration_seconds'] as int,
      source: json['source'] as String,
      fromStop: json['from_stop'] != null
          ? BusStopInfo.fromJson(json['from_stop'] as Map<String, dynamic>)
          : null,
      toStop: json['to_stop'] != null
          ? BusStopInfo.fromJson(json['to_stop'] as Map<String, dynamic>)
          : null,
      numStops: json['num_stops'] as int? ?? 0,
    );
  }

  /// Indica si la geometría viene de GTFS (más confiable)
  bool get isFromGTFS => source.startsWith('gtfs');

  /// Indica si es un fallback menos preciso
  bool get isFallback => source.contains('fallback');
}

class BusStopInfo {
  final String? code;
  final String? name;
  final double lat;
  final double lon;

  BusStopInfo({this.code, this.name, required this.lat, required this.lon});

  factory BusStopInfo.fromJson(Map<String, dynamic> json) {
    return BusStopInfo(
      code: json['code'] as String?,
      name: json['name'] as String?,
      lat: (json['lat'] as num).toDouble(),
      lon: (json['lon'] as num).toDouble(),
    );
  }

  LatLng get location => LatLng(lat, lon);
}
