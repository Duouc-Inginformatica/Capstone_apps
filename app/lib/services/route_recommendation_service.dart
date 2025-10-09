// ============================================================================
// ROUTE RECOMMENDATION SERVICE - Sprint 4 CAP-26
// ============================================================================
// Sistema inteligente de recomendación de rutas basado en:
// - Tiempo de viaje
// - Número de transferencias
// - Histórico de datos GTFS
// - Preferencias del usuario
// ============================================================================

import 'dart:math';
import 'package:latlong2/latlong.dart';
import 'combined_routes_service.dart';

enum RecommendationCriteria { fastest, fewerTransfers, shortest, balanced }

class RouteRecommendation {
  RouteRecommendation({
    required this.route,
    required this.score,
    required this.ranking,
    required this.strengths,
    required this.weaknesses,
    this.estimatedCost,
  });

  final CombinedRoute route;
  final double score; // 0.0 - 1.0
  final int ranking;
  final List<String> strengths;
  final List<String> weaknesses;
  final double? estimatedCost;

  String get recommendation {
    final buffer = StringBuffer();
    buffer.writeln('Opción #$ranking (${(score * 100).toInt()}% recomendada)');
    buffer.writeln(route.summary);

    if (strengths.isNotEmpty) {
      buffer.writeln('✅ Ventajas: ${strengths.join(", ")}');
    }

    if (weaknesses.isNotEmpty) {
      buffer.writeln('⚠️ Desventajas: ${weaknesses.join(", ")}');
    }

    if (estimatedCost != null) {
      buffer.writeln(
        '💰 Costo estimado: \$${estimatedCost!.toStringAsFixed(0)}',
      );
    }

    return buffer.toString();
  }

  Map<String, dynamic> toJson() {
    return {
      'route': route.toJson(),
      'score': score,
      'ranking': ranking,
      'strengths': strengths,
      'weaknesses': weaknesses,
      'estimatedCost': estimatedCost,
    };
  }
}

class RouteRecommendationService {
  static final RouteRecommendationService instance =
      RouteRecommendationService._();
  RouteRecommendationService._();

  // Pesos para criterios de evaluación
  static const Map<RecommendationCriteria, Map<String, double>> _weights = {
    RecommendationCriteria.fastest: {
      'time': 0.70,
      'transfers': 0.15,
      'distance': 0.10,
      'cost': 0.05,
    },
    RecommendationCriteria.fewerTransfers: {
      'time': 0.20,
      'transfers': 0.60,
      'distance': 0.10,
      'cost': 0.10,
    },
    RecommendationCriteria.shortest: {
      'time': 0.15,
      'transfers': 0.15,
      'distance': 0.60,
      'cost': 0.10,
    },
    RecommendationCriteria.balanced: {
      'time': 0.35,
      'transfers': 0.30,
      'distance': 0.20,
      'cost': 0.15,
    },
  };

  /// Recomienda la mejor ruta según criterio especificado
  RouteRecommendation recommendBestRoute({
    required List<CombinedRoute> routes,
    RecommendationCriteria criteria = RecommendationCriteria.balanced,
  }) {
    if (routes.isEmpty) {
      throw ArgumentError('No routes provided for recommendation');
    }

    final recommendations = recommendRoutes(routes: routes, criteria: criteria);
    return recommendations.first;
  }

  /// Recomienda y rankea múltiples rutas
  List<RouteRecommendation> recommendRoutes({
    required List<CombinedRoute> routes,
    RecommendationCriteria criteria = RecommendationCriteria.balanced,
    int? limit,
  }) {
    if (routes.isEmpty) return [];

    // Normalizar métricas
    final normalizedMetrics = _normalizeMetrics(routes);

    // Calcular scores
    final recommendations = <RouteRecommendation>[];
    final weights = _weights[criteria]!;

    for (var i = 0; i < routes.length; i++) {
      final route = routes[i];
      final metrics = normalizedMetrics[i];

      // Calcular score ponderado (invertir tiempo/distancia ya que menor es mejor)
      final score =
          (1 - metrics['time']!) * weights['time']! +
          (1 - metrics['transfers']!) * weights['transfers']! +
          (1 - metrics['distance']!) * weights['distance']! +
          (1 - metrics['cost']!) * weights['cost']!;

      // Identificar fortalezas y debilidades
      final strengths = _identifyStrengths(route, routes);
      final weaknesses = _identifyWeaknesses(route, routes);

      // Estimar costo
      final cost = _estimateCost(route);

      recommendations.add(
        RouteRecommendation(
          route: route,
          score: score,
          ranking: 0, // Se asignará después de ordenar
          strengths: strengths,
          weaknesses: weaknesses,
          estimatedCost: cost,
        ),
      );
    }

    // Ordenar por score descendente
    recommendations.sort((a, b) => b.score.compareTo(a.score));

    // Asignar ranking
    for (var i = 0; i < recommendations.length; i++) {
      recommendations[i] = RouteRecommendation(
        route: recommendations[i].route,
        score: recommendations[i].score,
        ranking: i + 1,
        strengths: recommendations[i].strengths,
        weaknesses: recommendations[i].weaknesses,
        estimatedCost: recommendations[i].estimatedCost,
      );
    }

    return limit != null && limit < recommendations.length
        ? recommendations.sublist(0, limit)
        : recommendations;
  }

  /// Sugiere paradas alternativas cercanas
  List<Map<String, dynamic>> suggestAlternativeStops({
    required LatLng currentLocation,
    required List<Map<String, dynamic>> nearbyStops,
    required String targetRoute,
    int limit = 3,
  }) {
    final Distance distance = const Distance();
    final alternatives = <Map<String, dynamic>>[];

    for (var stop in nearbyStops) {
      final stopLat = (stop['stop_lat'] as num?)?.toDouble();
      final stopLon = (stop['stop_lon'] as num?)?.toDouble();

      if (stopLat == null || stopLon == null) continue;

      final stopLocation = LatLng(stopLat, stopLon);
      final distanceMeters = distance.as(
        LengthUnit.Meter,
        currentLocation,
        stopLocation,
      );

      // Verificar si la parada tiene la ruta buscada
      final routes = (stop['routes'] as List<dynamic>?)?.cast<String>() ?? [];
      final hasTargetRoute = routes.contains(targetRoute);

      alternatives.add({
        'stop': stop,
        'distanceMeters': distanceMeters,
        'walkTimeMinutes': (distanceMeters / 1.4 / 60).ceil(), // ~1.4 m/s
        'hasTargetRoute': hasTargetRoute,
        'routesAvailable': routes,
        'score': _calculateStopScore(
          distanceMeters,
          hasTargetRoute,
          routes.length,
        ),
      });
    }

    // Ordenar por score
    alternatives.sort((a, b) {
      final scoreA = a['score'] as double;
      final scoreB = b['score'] as double;
      return scoreB.compareTo(scoreA);
    });

    return alternatives.take(limit).toList();
  }

  /// Recomienda el mejor bus basándose en frecuencia y tiempo de llegada
  Map<String, dynamic> recommendBestBus({
    required List<Map<String, dynamic>> availableBuses,
    required DateTime currentTime,
  }) {
    if (availableBuses.isEmpty) {
      throw ArgumentError('No buses available');
    }

    var bestBus = availableBuses.first;
    var bestScore = 0.0;

    for (var bus in availableBuses) {
      final score = _calculateBusScore(bus, currentTime);
      if (score > bestScore) {
        bestScore = score;
        bestBus = bus;
      }
    }

    return {
      'bus': bestBus,
      'score': bestScore,
      'reason': _getBusRecommendationReason(bestBus, availableBuses),
    };
  }

  // ============================================================================
  // MÉTODOS PRIVADOS
  // ============================================================================

  List<Map<String, double>> _normalizeMetrics(List<CombinedRoute> routes) {
    if (routes.isEmpty) return [];

    // Encontrar min/max de cada métrica
    var minTime = routes.first.totalDurationSeconds.toDouble();
    var maxTime = minTime;
    var minTransfers = routes.first.transferCount.toDouble();
    var maxTransfers = minTransfers;
    var minDistance = routes.first.totalDistanceMeters;
    var maxDistance = minDistance;

    for (var route in routes) {
      final time = route.totalDurationSeconds.toDouble();
      final transfers = route.transferCount.toDouble();
      final distance = route.totalDistanceMeters;

      minTime = min(minTime, time);
      maxTime = max(maxTime, time);
      minTransfers = min(minTransfers, transfers);
      maxTransfers = max(maxTransfers, transfers);
      minDistance = min(minDistance, distance);
      maxDistance = max(maxDistance, distance);
    }

    // Normalizar (0-1) cada ruta
    return routes.map((route) {
      return {
        'time': maxTime > minTime
            ? (route.totalDurationSeconds - minTime) / (maxTime - minTime)
            : 0.0,
        'transfers': maxTransfers > minTransfers
            ? (route.transferCount - minTransfers) /
                  (maxTransfers - minTransfers)
            : 0.0,
        'distance': maxDistance > minDistance
            ? (route.totalDistanceMeters - minDistance) /
                  (maxDistance - minDistance)
            : 0.0,
        'cost': 0.5, // Placeholder, se puede calcular con tarifas reales
      };
    }).toList();
  }

  List<String> _identifyStrengths(
    CombinedRoute route,
    List<CombinedRoute> allRoutes,
  ) {
    final strengths = <String>[];

    // Verificar si es la más rápida
    final isFastest = allRoutes.every(
      (r) => route.totalDurationSeconds <= r.totalDurationSeconds,
    );
    if (isFastest) {
      strengths.add('Ruta más rápida');
    }

    // Verificar menos transferencias
    final fewestTransfers = allRoutes.every(
      (r) => route.transferCount <= r.transferCount,
    );
    if (fewestTransfers && route.transferCount == 0) {
      strengths.add('Sin transferencias');
    } else if (fewestTransfers) {
      strengths.add('Menos transferencias');
    }

    // Verificar distancia más corta
    final isShortest = allRoutes.every(
      (r) => route.totalDistanceMeters <= r.totalDistanceMeters,
    );
    if (isShortest) {
      strengths.add('Distancia más corta');
    }

    // Verificar poca caminata
    final walkDistance = route.segments
        .where((s) => s.mode == TransportMode.walk)
        .fold(0.0, (sum, s) => sum + s.distanceMeters);
    if (walkDistance < 200) {
      strengths.add('Poca caminata requerida');
    }

    return strengths;
  }

  List<String> _identifyWeaknesses(
    CombinedRoute route,
    List<CombinedRoute> allRoutes,
  ) {
    final weaknesses = <String>[];

    // Verificar si es la más lenta
    final isSlowest = allRoutes.every(
      (r) => route.totalDurationSeconds >= r.totalDurationSeconds,
    );
    if (isSlowest && allRoutes.length > 1) {
      weaknesses.add('Tiempo de viaje largo');
    }

    // Verificar muchas transferencias
    if (route.transferCount >= 2) {
      weaknesses.add('Requiere ${route.transferCount} transferencias');
    }

    // Verificar mucha caminata
    final walkDistance = route.segments
        .where((s) => s.mode == TransportMode.walk)
        .fold(0.0, (sum, s) => sum + s.distanceMeters);
    if (walkDistance > 500) {
      weaknesses.add(
        'Requiere ${(walkDistance / 1000).toStringAsFixed(1)}km de caminata',
      );
    }

    return weaknesses;
  }

  double _estimateCost(CombinedRoute route) {
    // Costo base por viaje en Santiago (aproximado)
    const baseFare = 800.0;

    // Contar número de viajes en transporte público
    final publicTransportSegments = route.segments
        .where((s) => s.mode != TransportMode.walk)
        .length;

    // En Santiago, con tarjeta Bip! hay descuentos en combinaciones
    if (publicTransportSegments <= 1) {
      return baseFare;
    } else if (publicTransportSegments == 2) {
      return baseFare + 100; // Descuento en combinación
    } else {
      return baseFare + (publicTransportSegments - 1) * 200;
    }
  }

  double _calculateStopScore(
    double distanceMeters,
    bool hasTargetRoute,
    int totalRoutes,
  ) {
    var score = 0.0;

    // Penalizar distancia (max 500m)
    score += (1 - min(distanceMeters / 500, 1.0)) * 0.5;

    // Bonus si tiene la ruta buscada
    if (hasTargetRoute) {
      score += 0.4;
    }

    // Bonus por número de rutas disponibles
    score += min(totalRoutes / 10, 1.0) * 0.1;

    return score;
  }

  double _calculateBusScore(Map<String, dynamic> bus, DateTime currentTime) {
    var score = 0.0;

    // Verificar tiempo de espera
    final arrivalTime = bus['arrivalTime'] as DateTime?;
    if (arrivalTime != null) {
      final waitMinutes = arrivalTime.difference(currentTime).inMinutes;

      // Óptimo: 2-5 minutos de espera
      if (waitMinutes >= 2 && waitMinutes <= 5) {
        score += 1.0;
      } else if (waitMinutes < 2) {
        score += 0.7; // Muy pronto
      } else if (waitMinutes <= 10) {
        score += 0.5;
      } else {
        score += 0.2; // Mucha espera
      }
    }

    // Verificar frecuencia
    final frequency = bus['frequency'] as int? ?? 0;
    if (frequency > 0) {
      score += min(frequency / 20, 1.0) * 0.3; // Más frecuente es mejor
    }

    return score;
  }

  String _getBusRecommendationReason(
    Map<String, dynamic> bus,
    List<Map<String, dynamic>> allBuses,
  ) {
    final routeName = bus['routeName'] as String? ?? 'Bus';
    final arrivalTime = bus['arrivalTime'] as DateTime?;

    if (arrivalTime != null) {
      final minutes = arrivalTime.difference(DateTime.now()).inMinutes;
      return 'El $routeName llega en $minutes minutos, tiempo óptimo de espera';
    }

    return 'Recomendado basándose en frecuencia y disponibilidad';
  }
}
