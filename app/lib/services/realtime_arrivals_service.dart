import 'dart:developer' as developer;
// ============================================================================
// REALTIME ARRIVALS SERVICE - Sprint 4 CAP-27
// ============================================================================
// Consulta tiempos de llegada de buses en tiempo real
// Integración con API de transporte público de Santiago
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

enum ArrivalStatus { onTime, delayed, early, approaching, arrived, unknown }

class BusArrival {
  BusArrival({
    required this.routeName,
    required this.stopName,
    required this.estimatedArrivalTime,
    required this.status,
    this.vehicleId,
    this.distanceMeters,
    this.occupancyLevel,
    this.isRealtime,
  });

  final String routeName;
  final String stopName;
  final DateTime estimatedArrivalTime;
  final ArrivalStatus status;
  final String? vehicleId;
  final double? distanceMeters;
  final String? occupancyLevel; // "empty", "normal", "crowded", "full"
  final bool? isRealtime;

  Duration get timeUntilArrival =>
      estimatedArrivalTime.difference(DateTime.now());
  int get minutesUntilArrival => timeUntilArrival.inMinutes;

  String get statusText {
    switch (status) {
      case ArrivalStatus.onTime:
        return 'A tiempo';
      case ArrivalStatus.delayed:
        return 'Retrasado';
      case ArrivalStatus.early:
        return 'Adelantado';
      case ArrivalStatus.approaching:
        return 'Acercándose';
      case ArrivalStatus.arrived:
        return 'En parada';
      case ArrivalStatus.unknown:
        return 'Desconocido';
    }
  }

  String get occupancyText {
    switch (occupancyLevel) {
      case 'empty':
        return 'Vacío';
      case 'normal':
        return 'Normal';
      case 'crowded':
        return 'Lleno';
      case 'full':
        return 'Completo';
      default:
        return 'Desconocido';
    }
  }

  String getReadableAnnouncement() {
    final buffer = StringBuffer();

    if (minutesUntilArrival <= 0) {
      buffer.write('El bus $routeName está llegando AHORA a $stopName');
    } else if (minutesUntilArrival == 1) {
      buffer.write('El bus $routeName llega en 1 minuto a $stopName');
    } else {
      buffer.write(
        'El bus $routeName llega en $minutesUntilArrival minutos a $stopName',
      );
    }

    if (status != ArrivalStatus.onTime) {
      buffer.write(' ($statusText)');
    }

    if (occupancyLevel != null && occupancyLevel != 'normal') {
      buffer.write('. Estado: $occupancyText');
    }

    if (isRealtime == true) {
      buffer.write(' [Tiempo real]');
    }

    return buffer.toString();
  }

  Map<String, dynamic> toJson() {
    return {
      'routeName': routeName,
      'stopName': stopName,
      'estimatedArrivalTime': estimatedArrivalTime.toIso8601String(),
      'status': status.name,
      'statusText': statusText,
      'vehicleId': vehicleId,
      'distanceMeters': distanceMeters,
      'occupancyLevel': occupancyLevel,
      'occupancyText': occupancyText,
      'isRealtime': isRealtime,
      'minutesUntilArrival': minutesUntilArrival,
    };
  }
}

class RealtimeArrivalsService {
  static final RealtimeArrivalsService instance = RealtimeArrivalsService._();
  RealtimeArrivalsService._();

  // API endpoints (pueden ser configurables)
  static const String redApiUrl = 'https://api.red.cl'; // Ejemplo
  static const Duration timeout = Duration(seconds: 10);
  static const Duration cacheExpiration = Duration(seconds: 30);

  // Caché de llegadas
  final Map<String, List<BusArrival>> _arrivalsCache = {};
  final Map<String, DateTime> _cacheTimestamps = {};

  // Stream para actualizaciones en tiempo real
  final _arrivalsController = StreamController<List<BusArrival>>.broadcast();
  Stream<List<BusArrival>> get arrivalsStream => _arrivalsController.stream;

  Timer? _pollingTimer;

  /// Obtiene tiempos de llegada para una parada específica
  Future<List<BusArrival>> getArrivalsForStop({
    required String stopId,
    String? routeFilter,
    bool forceRefresh = false,
  }) async {
    // Verificar caché
    if (!forceRefresh && _isCacheValid(stopId)) {
      return _arrivalsCache[stopId]!;
    }

    try {
      // Consultar API real (ejemplo con RED API de Santiago)
      final arrivals = await _fetchArrivalsFromAPI(
        stopId: stopId,
        routeFilter: routeFilter,
      );

      // Actualizar caché
      _arrivalsCache[stopId] = arrivals;
      _cacheTimestamps[stopId] = DateTime.now();

      // Emitir actualización
      _arrivalsController.add(arrivals);

      return arrivals;
    } catch (e) {
      developer.log('Error fetching arrivals: $e');

      // Retornar datos cacheados si existen
      if (_arrivalsCache.containsKey(stopId)) {
        return _arrivalsCache[stopId]!;
      }

      // Generar datos simulados como fallback
      return _generateMockArrivals(stopId, routeFilter);
    }
  }

  /// Obtiene llegadas para múltiples paradas cercanas
  Future<Map<String, List<BusArrival>>> getArrivalsForNearbyStops({
    required List<String> stopIds,
    String? routeFilter,
  }) async {
    final results = <String, List<BusArrival>>{};

    for (var stopId in stopIds) {
      try {
        final arrivals = await getArrivalsForStop(
          stopId: stopId,
          routeFilter: routeFilter,
        );
        results[stopId] = arrivals;
      } catch (e) {
        developer.log('Error fetching arrivals for stop $stopId: $e');
        results[stopId] = [];
      }
    }

    return results;
  }

  /// Inicia polling automático de actualizaciones
  void startPolling({
    required String stopId,
    String? routeFilter,
    Duration interval = const Duration(seconds: 30),
  }) {
    stopPolling(); // Detener polling anterior

    _pollingTimer = Timer.periodic(interval, (_) async {
      try {
        await getArrivalsForStop(
          stopId: stopId,
          routeFilter: routeFilter,
          forceRefresh: true,
        );
      } catch (e) {
        developer.log('Error during polling: $e');
      }
    });
  }

  /// Detiene polling automático
  void stopPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
  }

  /// Encuentra el próximo bus de una ruta específica
  BusArrival? findNextBus({
    required List<BusArrival> arrivals,
    required String routeName,
  }) {
    final filtered = arrivals.where((a) => a.routeName == routeName).toList()
      ..sort(
        (a, b) => a.estimatedArrivalTime.compareTo(b.estimatedArrivalTime),
      );

    return filtered.isNotEmpty ? filtered.first : null;
  }

  /// Obtiene estadísticas de frecuencia de una ruta
  Map<String, dynamic> getRouteFrequencyStats({
    required List<BusArrival> arrivals,
    required String routeName,
  }) {
    final filtered = arrivals.where((a) => a.routeName == routeName).toList()
      ..sort(
        (a, b) => a.estimatedArrivalTime.compareTo(b.estimatedArrivalTime),
      );

    if (filtered.length < 2) {
      return {
        'count': filtered.length,
        'averageIntervalMinutes': null,
        'nextArrivalMinutes': filtered.isNotEmpty
            ? filtered.first.minutesUntilArrival
            : null,
      };
    }

    // Calcular intervalo promedio entre buses
    var totalInterval = 0;
    for (var i = 0; i < filtered.length - 1; i++) {
      final interval = filtered[i + 1].estimatedArrivalTime
          .difference(filtered[i].estimatedArrivalTime)
          .inMinutes;
      totalInterval += interval;
    }

    return {
      'count': filtered.length,
      'averageIntervalMinutes': totalInterval / (filtered.length - 1),
      'nextArrivalMinutes': filtered.first.minutesUntilArrival,
      'frequency': '${(totalInterval / (filtered.length - 1)).round()} min',
    };
  }

  // ============================================================================
  // MÉTODOS PRIVADOS
  // ============================================================================

  Future<List<BusArrival>> _fetchArrivalsFromAPI({
    required String stopId,
    String? routeFilter,
  }) async {
    // NOTA: Esta es una implementación de ejemplo
    // En producción, integrar con API real de RED o GTFS Realtime

    try {
      // Ejemplo de endpoint (ajustar según API real)
      final uri = Uri.parse('$redApiUrl/stops/$stopId/arrivals');

      final response = await http
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(timeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final arrivalsData = data['arrivals'] as List<dynamic>? ?? [];

        return arrivalsData
            .map((arrivalJson) {
              return _parseArrivalFromJson(arrivalJson as Map<String, dynamic>);
            })
            .where((arrival) {
              // Filtrar por ruta si se especifica
              return routeFilter == null || arrival.routeName == routeFilter;
            })
            .toList();
      }

      throw Exception('API returned ${response.statusCode}');
    } catch (e) {
      developer.log('API fetch failed: $e');
      rethrow;
    }
  }

  BusArrival _parseArrivalFromJson(Map<String, dynamic> json) {
    final minutesUntil = json['minutes'] as int? ?? 0;
    final arrivalTime = DateTime.now().add(Duration(minutes: minutesUntil));

    ArrivalStatus status = ArrivalStatus.unknown;
    if (minutesUntil <= 0) {
      status = ArrivalStatus.arrived;
    } else if (minutesUntil <= 2) {
      status = ArrivalStatus.approaching;
    } else {
      status = ArrivalStatus.onTime;
    }

    return BusArrival(
      routeName: json['route'] as String? ?? 'Desconocido',
      stopName: json['stopName'] as String? ?? 'Parada',
      estimatedArrivalTime: arrivalTime,
      status: status,
      vehicleId: json['vehicleId'] as String?,
      distanceMeters: (json['distance'] as num?)?.toDouble(),
      occupancyLevel: json['occupancy'] as String?,
      isRealtime: json['realtime'] as bool? ?? false,
    );
  }

  List<BusArrival> _generateMockArrivals(String stopId, String? routeFilter) {
    // Generar datos simulados para testing
    final routes = routeFilter != null
        ? [routeFilter]
        : ['506', '507', 'D01', 'Línea 1'];

    final arrivals = <BusArrival>[];
    final now = DateTime.now();

    for (var i = 0; i < routes.length; i++) {
      // Generar 2-3 llegadas por ruta
      for (var j = 0; j < 2; j++) {
        final minutesUntil = (i * 10) + (j * 5) + 3;
        arrivals.add(
          BusArrival(
            routeName: routes[i],
            stopName: 'Parada $stopId',
            estimatedArrivalTime: now.add(Duration(minutes: minutesUntil)),
            status: minutesUntil <= 2
                ? ArrivalStatus.approaching
                : ArrivalStatus.onTime,
            vehicleId: 'VEH-${1000 + i * 100 + j}',
            distanceMeters: minutesUntil * 300.0, // ~300m/min
            occupancyLevel: j == 0 ? 'normal' : 'crowded',
            isRealtime: false,
          ),
        );
      }
    }

    return arrivals..sort(
      (a, b) => a.estimatedArrivalTime.compareTo(b.estimatedArrivalTime),
    );
  }

  bool _isCacheValid(String stopId) {
    if (!_arrivalsCache.containsKey(stopId)) return false;
    if (!_cacheTimestamps.containsKey(stopId)) return false;

    final cacheAge = DateTime.now().difference(_cacheTimestamps[stopId]!);
    return cacheAge < cacheExpiration;
  }

  void clearCache() {
    _arrivalsCache.clear();
    _cacheTimestamps.clear();
  }

  void dispose() {
    stopPolling();
    _arrivalsController.close();
  }
}
