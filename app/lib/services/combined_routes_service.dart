// ============================================================================
// COMBINED ROUTES SERVICE - Sprint 3 CAP-21
// ============================================================================
// Calcula rutas multimodales: caminata + bus + metro + caminata
// Maneja transferencias entre diferentes modos de transporte
// ============================================================================

import 'package:latlong2/latlong.dart';
import 'api_client.dart';

enum TransportMode { walk, bus, metro, train }

class RouteSegment {
  RouteSegment({
    required this.mode,
    required this.startPoint,
    required this.endPoint,
    required this.distanceMeters,
    required this.durationSeconds,
    this.routeName,
    this.instructions,
    this.geometry,
    this.stopName,
    this.nextStopName,
  });

  final TransportMode mode;
  final LatLng startPoint;
  final LatLng endPoint;
  final double distanceMeters;
  final int durationSeconds;
  final String? routeName; // Ej: "506", "Línea 1"
  final String? instructions;
  final List<LatLng>? geometry;
  final String? stopName;
  final String? nextStopName;

  String get modeIcon {
    switch (mode) {
      case TransportMode.walk:
        return '🚶';
      case TransportMode.bus:
        return '🚌';
      case TransportMode.metro:
        return '🚇';
      case TransportMode.train:
        return '🚂';
    }
  }

  String get modeText {
    switch (mode) {
      case TransportMode.walk:
        return 'Caminar';
      case TransportMode.bus:
        return 'Bus';
      case TransportMode.metro:
        return 'Metro';
      case TransportMode.train:
        return 'Tren';
    }
  }

  String getReadableInstruction() {
    final duration = Duration(seconds: durationSeconds);
    final minutes = duration.inMinutes;
    final distance = distanceMeters < 1000
        ? '${distanceMeters.round()} metros'
        : '${(distanceMeters / 1000).toStringAsFixed(1)} kilómetros';

    switch (mode) {
      case TransportMode.walk:
        return 'Camina $distance durante $minutes minutos. $instructions';
      case TransportMode.bus:
        return 'Toma el bus $routeName en $stopName. '
            'Viaja durante $minutes minutos hasta $nextStopName.';
      case TransportMode.metro:
        return 'Toma la $routeName en estación $stopName. '
            'Viaja durante $minutes minutos hasta $nextStopName.';
      case TransportMode.train:
        return 'Toma el tren en $stopName hasta $nextStopName.';
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'mode': mode.name,
      'modeText': modeText,
      'startPoint': {'lat': startPoint.latitude, 'lon': startPoint.longitude},
      'endPoint': {'lat': endPoint.latitude, 'lon': endPoint.longitude},
      'distanceMeters': distanceMeters,
      'durationSeconds': durationSeconds,
      'routeName': routeName,
      'instructions': instructions,
      'stopName': stopName,
      'nextStopName': nextStopName,
      'geometry': geometry
          ?.map((p) => {'lat': p.latitude, 'lon': p.longitude})
          .toList(),
    };
  }
}

class CombinedRoute {
  CombinedRoute({
    required this.segments,
    required this.totalDistanceMeters,
    required this.totalDurationSeconds,
    required this.transferCount,
  });

  final List<RouteSegment> segments;
  final double totalDistanceMeters;
  final int totalDurationSeconds;
  final int transferCount;

  Duration get totalDuration => Duration(seconds: totalDurationSeconds);

  String get totalDistanceText {
    return totalDistanceMeters < 1000
        ? '${totalDistanceMeters.round()} metros'
        : '${(totalDistanceMeters / 1000).toStringAsFixed(1)} km';
  }

  String get summary {
    final modes = <TransportMode>{};
    for (var segment in segments) {
      modes.add(segment.mode);
    }

    final modeNames = modes
        .map((m) {
          switch (m) {
            case TransportMode.walk:
              return 'caminata';
            case TransportMode.bus:
              return 'bus';
            case TransportMode.metro:
              return 'metro';
            case TransportMode.train:
              return 'tren';
          }
        })
        .join(', ');

    final duration = Duration(seconds: totalDurationSeconds);
    return '$totalDistanceText, ${duration.inMinutes} minutos, '
        '$transferCount transbordos ($modeNames)';
  }

  List<String> getVoiceInstructions() {
    final instructions = <String>[];

    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final isLast = i == segments.length - 1;

      var instruction = segment.getReadableInstruction();

      if (!isLast && segments[i + 1].mode != TransportMode.walk) {
        instruction += ' Luego realizarás un transbordo.';
      }

      instructions.add(instruction);
    }

    return instructions;
  }

  Map<String, dynamic> toJson() {
    return {
      'segments': segments.map((s) => s.toJson()).toList(),
      'totalDistanceMeters': totalDistanceMeters,
      'totalDurationSeconds': totalDurationSeconds,
      'transferCount': transferCount,
      'summary': summary,
    };
  }
}

class CombinedRoutesService {
  static final CombinedRoutesService instance = CombinedRoutesService._();
  CombinedRoutesService._();

  final Distance _distance = const Distance();

  /// Calcula ruta combinada usando el nuevo endpoint de transporte público GTFS
  Future<CombinedRoute> calculatePublicTransitRoute({
    required LatLng origin,
    required LatLng destination,
    DateTime? departureTime,
  }) async {
    try {
      print('🚌 Calculando ruta de transporte público con datos GTFS');
      
      // Llamar al nuevo endpoint de transporte público
      final apiClient = ApiClient();
      final transitData = await apiClient.getPublicTransitRoute(
        originLat: origin.latitude,
        originLon: origin.longitude,
        destLat: destination.latitude,
        destLon: destination.longitude,
        departureTime: departureTime,
        includeGeometry: true,
        useCache: true,
      );

      return await calculateCombinedRoute(
        origin: origin,
        destination: destination,
        transitData: transitData,
      );
    } catch (e) {
      print('❌ Error en ruta de transporte público: $e');
      
      // Si falla, crear una ruta de caminata directa
      print('� Creando ruta de caminata directa como fallback');
      
      final walkDistance = _distance.as(LengthUnit.Meter, origin, destination);
      final walkDuration = (walkDistance / 1.4).round(); // ~1.4 m/s velocidad caminata
      
      final fallbackData = {
        'paths': [
          {
            'legs': [
              {
                'type': 'walk',
                'distance': walkDistance,
                'time': walkDuration * 1000, // convertir a milisegundos
                'geometry': [
                  [origin.longitude, origin.latitude],
                  [destination.longitude, destination.latitude],
                ],
                'instructions': 'Dirígete caminando hacia el destino',
              }
            ]
          }
        ]
      };
      
      return await calculateCombinedRoute(
        origin: origin,
        destination: destination,
        transitData: fallbackData,
      );
    }
  }

  /// Calcula ruta combinada multimodal (método original)
  Future<CombinedRoute> calculateCombinedRoute({
    required LatLng origin,
    required LatLng destination,
    required Map<String, dynamic> transitData,
  }) async {
    final segments = <RouteSegment>[];
    var totalDistance = 0.0;
    var totalDuration = 0;
    var transferCount = 0;

    // Analizar datos de tránsito de GraphHopper
    if (transitData['paths'] != null && transitData['paths'] is List) {
      final paths = transitData['paths'] as List;

      if (paths.isNotEmpty) {
        final bestPath = paths.first as Map<String, dynamic>;
        final legs = bestPath['legs'] as List<dynamic>?;

        if (legs != null) {
          for (var i = 0; i < legs.length; i++) {
            final leg = legs[i] as Map<String, dynamic>;
            final segment = _parseLegToSegment(leg);

            if (segment != null) {
              segments.add(segment);
              totalDistance += segment.distanceMeters;
              totalDuration += segment.durationSeconds;

              // Contar transferencias (cambio de modo que no sea caminata)
              if (i > 0 &&
                  segment.mode != TransportMode.walk &&
                  segments[i - 1].mode != TransportMode.walk &&
                  segment.mode != segments[i - 1].mode) {
                transferCount++;
              }
            }
          }
        }
      }
    }

    // Si no hay segmentos, crear una ruta de caminata directa
    if (segments.isEmpty) {
      final walkDistance = _distance.as(LengthUnit.Meter, origin, destination);

      segments.add(
        RouteSegment(
          mode: TransportMode.walk,
          startPoint: origin,
          endPoint: destination,
          distanceMeters: walkDistance,
          durationSeconds: (walkDistance / 1.4)
              .round(), // ~1.4 m/s velocidad caminata
          instructions: 'Dirígete hacia el destino',
          geometry: [origin, destination],
        ),
      );

      totalDistance = walkDistance;
      totalDuration = segments.first.durationSeconds;
    }

    return CombinedRoute(
      segments: segments,
      totalDistanceMeters: totalDistance,
      totalDurationSeconds: totalDuration,
      transferCount: transferCount,
    );
  }

  /// Genera rutas alternativas combinadas
  Future<List<CombinedRoute>> generateAlternativeRoutes({
    required LatLng origin,
    required LatLng destination,
    required List<Map<String, dynamic>> transitDataList,
  }) async {
    final routes = <CombinedRoute>[];

    for (var transitData in transitDataList) {
      try {
        final route = await calculateCombinedRoute(
          origin: origin,
          destination: destination,
          transitData: transitData,
        );
        routes.add(route);
      } catch (e) {
        print('Error generating alternative route: $e');
      }
    }

    // Ordenar por tiempo total
    routes.sort(
      (a, b) => a.totalDurationSeconds.compareTo(b.totalDurationSeconds),
    );

    return routes;
  }

  /// Optimiza ruta minimizando transferencias
  CombinedRoute optimizeRoute(CombinedRoute route) {
    // Combinar segmentos de caminata consecutivos
    final optimizedSegments = <RouteSegment>[];
    RouteSegment? pendingWalk;

    for (var segment in route.segments) {
      if (segment.mode == TransportMode.walk) {
        if (pendingWalk == null) {
          pendingWalk = segment;
        } else {
          // Combinar con caminata anterior
          pendingWalk = RouteSegment(
            mode: TransportMode.walk,
            startPoint: pendingWalk.startPoint,
            endPoint: segment.endPoint,
            distanceMeters: pendingWalk.distanceMeters + segment.distanceMeters,
            durationSeconds:
                pendingWalk.durationSeconds + segment.durationSeconds,
            instructions: '${pendingWalk.instructions} ${segment.instructions}',
          );
        }
      } else {
        if (pendingWalk != null) {
          optimizedSegments.add(pendingWalk);
          pendingWalk = null;
        }
        optimizedSegments.add(segment);
      }
    }

    if (pendingWalk != null) {
      optimizedSegments.add(pendingWalk);
    }

    // Recalcular transferencias
    var transfers = 0;
    for (var i = 1; i < optimizedSegments.length; i++) {
      if (optimizedSegments[i].mode != TransportMode.walk &&
          optimizedSegments[i - 1].mode != TransportMode.walk) {
        transfers++;
      }
    }

    return CombinedRoute(
      segments: optimizedSegments,
      totalDistanceMeters: route.totalDistanceMeters,
      totalDurationSeconds: route.totalDurationSeconds,
      transferCount: transfers,
    );
  }

  // ============================================================================
  // MÉTODOS PRIVADOS
  // ============================================================================

  RouteSegment? _parseLegToSegment(Map<String, dynamic> leg) {
    try {
      final type = leg['type'] as String?;
      final distance = (leg['distance'] as num?)?.toDouble() ?? 0.0;
      final duration = (leg['time'] as num?)?.toInt() ?? 0;

      // Determinar modo de transporte
      TransportMode mode;
      String? routeName;
      String? stopName;
      String? nextStopName;

      if (type == 'walk' || type == 'pt') {
        mode = TransportMode.walk;
      } else if (type == 'pt' || type == 'transit') {
        final routeType = leg['route_type'] as String?;

        if (routeType?.contains('metro') ?? false) {
          mode = TransportMode.metro;
          routeName = leg['route_id'] as String? ?? 'Metro';
        } else if (routeType?.contains('train') ?? false) {
          mode = TransportMode.train;
          routeName = leg['route_id'] as String? ?? 'Tren';
        } else {
          mode = TransportMode.bus;
          routeName =
              leg['route_short_name'] as String? ??
              leg['route_id'] as String? ??
              'Bus';
        }

        stopName = leg['departureLocation'] as String?;
        nextStopName = leg['arrivalLocation'] as String?;
      } else {
        mode = TransportMode.walk;
      }

      // Extraer geometría
      List<LatLng>? geometry;
      if (leg['geometry'] != null) {
        geometry = _parseGeometry(leg['geometry']);
      }

      final startPoint = geometry?.first ?? LatLng(0, 0);
      final endPoint = geometry?.last ?? LatLng(0, 0);

      return RouteSegment(
        mode: mode,
        startPoint: startPoint,
        endPoint: endPoint,
        distanceMeters: distance,
        durationSeconds: (duration / 1000).round(), // milliseconds to seconds
        routeName: routeName,
        instructions: leg['instructions'] as String?,
        geometry: geometry,
        stopName: stopName,
        nextStopName: nextStopName,
      );
    } catch (e) {
      print('Error parsing leg to segment: $e');
      return null;
    }
  }

  List<LatLng> _parseGeometry(dynamic geometry) {
    final points = <LatLng>[];

    if (geometry is Map && geometry['coordinates'] is List) {
      final coords = geometry['coordinates'] as List;
      for (var coord in coords) {
        if (coord is List && coord.length >= 2) {
          points.add(
            LatLng((coord[1] as num).toDouble(), (coord[0] as num).toDouble()),
          );
        }
      }
    } else if (geometry is List) {
      for (var coord in geometry) {
        if (coord is List && coord.length >= 2) {
          points.add(
            LatLng((coord[0] as num).toDouble(), (coord[1] as num).toDouble()),
          );
        }
      }
    }

    return points;
  }
}
