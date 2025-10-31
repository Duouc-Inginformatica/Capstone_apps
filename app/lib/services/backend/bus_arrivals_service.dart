import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'server_config.dart';
import '../debug_logger.dart';

class BusArrival {
  final String routeNumber;
  final double distanceKm;
  final bool justPassed; // Nuevo: si el bus acaba de pasar

  BusArrival({
    required this.routeNumber,
    required this.distanceKm,
    this.justPassed = false,
  });

  factory BusArrival.fromJson(Map<String, dynamic> json) {
    return BusArrival(
      routeNumber: json['route_number'] ?? '',
      distanceKm: (json['distance_km'] ?? 0.0).toDouble(),
      justPassed: json['just_passed'] ?? false,
    );
  }

  /// Calcula minutos estimados basado en distancia
  /// Asume velocidad promedio de 15 km/h en ciudad (conservador)
  int get estimatedMinutes {
    if (distanceKm <= 0) return 0;
    // 15 km/h = 0.25 km/min → minutos = km / 0.25
    final minutes = (distanceKm / 0.25).ceil();
    return minutes.clamp(0, 60); // Max 60 minutos mostrados
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
    if (justPassed) {
      return 'Bus $routeNumber acaba de pasar';
    }
    return 'Bus $routeNumber a $formattedDistance, llegará en $formattedTime';
  }
}

class StopArrivals {
  final String stopCode;
  final String stopName;
  final List<BusArrival> arrivals;
  final List<String> bussesPassed; // Nuevo: buses que pasaron recientemente
  final DateTime lastUpdated;

  StopArrivals({
    required this.stopCode,
    required this.stopName,
    required this.arrivals,
    this.bussesPassed = const [],
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
      bussesPassed:
          (json['busses_passed'] as List<dynamic>?)
              ?.map((e) => e.toString())
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
      return 'Hay 1 bus próximo: ${arrivals[0].announcement}';
    }

    return 'Hay ${arrivals.length} buses próximos en paradero $stopCode';
  }

  /// Encuentra el bus específico en las llegadas
  BusArrival? findBus(String routeNumber) {
    try {
      return arrivals.firstWhere(
        (arrival) =>
            arrival.routeNumber.toUpperCase() == routeNumber.toUpperCase(),
      );
    } catch (e) {
      return null;
    }
  }

  /// Verifica si un bus específico ya pasó
  bool hasBusPassed(String routeNumber) {
    return bussesPassed.any(
      (bus) => bus.toUpperCase() == routeNumber.toUpperCase(),
    );
  }
}

// ============================================================================
// SERVICIO DE POLLING EN TIEMPO REAL
// ============================================================================
/// Gestiona polling automático de llegadas de buses con callbacks para UI
class BusArrivalsService {
  static final BusArrivalsService instance = BusArrivalsService._();
  BusArrivalsService._();

  String get baseUrl => '${ServerConfig.instance.baseUrl}/api';
  static const Duration timeout = Duration(seconds: 10);
  static const Duration pollingInterval = Duration(
    seconds: 30,
  ); // Polling cada 30s

  // Estado de tracking activo
  Timer? _pollingTimer;
  String? _currentStopCode;
  String? _currentRouteNumber;
  StopArrivals? _lastArrivals;

  // Callbacks
  Function(StopArrivals)? onArrivalsUpdated;
  Function(String routeNumber)? onBusPassed; // Bus ya pasó - recalcular ruta
  Function(BusArrival)? onBusApproaching; // Bus a menos de 2 min

  /// Obtiene las llegadas de buses para un paradero específico (llamada única)
  Future<StopArrivals?> getBusArrivals(String stopCode) async {
    DebugLogger.network(
      '🚌 [ARRIVALS] Obteniendo llegadas para paradero: $stopCode',
    );

    try {
      final url = Uri.parse('$baseUrl/bus-arrivals/$stopCode');
      DebugLogger.network('🌐 [ARRIVALS] URL: $url');

      final response = await http.get(url).timeout(timeout);

      DebugLogger.network('📡 [ARRIVALS] Status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final jsonData = json.decode(response.body) as Map<String, dynamic>;
        final arrivals = StopArrivals.fromJson(jsonData);

        DebugLogger.network(
          '✅ [ARRIVALS] ${arrivals.arrivals.length} buses encontrados para ${arrivals.stopCode}',
        );

        return arrivals;
      } else if (response.statusCode == 404) {
        DebugLogger.network(
          '⚠️ [ARRIVALS] No se encontraron llegadas para paradero $stopCode',
        );
        return null;
      } else {
        DebugLogger.network(
          '❌ [ARRIVALS] Error del servidor: ${response.statusCode} - ${response.body}',
        );
        return null;
      }
    } catch (e) {
      DebugLogger.network('❌ [ARRIVALS] Error obteniendo llegadas: $e');
      return null;
    }
  }

  /// Inicia polling automático de llegadas para un paradero y bus específico
  /// Se usa cuando el usuario está esperando el bus en el paradero
  void startTracking({
    required String stopCode,
    required String routeNumber,
    required Function(StopArrivals) onUpdate,
    required Function(String) onBusPassed,
    Function(BusArrival)? onApproaching,
  }) {
    DebugLogger.navigation(
      '🚌 [TRACKING] Iniciando seguimiento: Bus $routeNumber en $stopCode',
    );

    // Detener tracking previo
    stopTracking();

    // Configurar callbacks
    _currentStopCode = stopCode;
    _currentRouteNumber = routeNumber;
    onArrivalsUpdated = onUpdate;
    this.onBusPassed = onBusPassed;
    onBusApproaching = onApproaching;

    // Primera consulta inmediata
    _pollArrivals();

    // Polling periódico cada 30 segundos
    _pollingTimer = Timer.periodic(pollingInterval, (timer) {
      _pollArrivals();
    });
  }

  /// Detiene el polling activo
  void stopTracking() {
    if (_pollingTimer != null) {
      DebugLogger.navigation('� [TRACKING] Deteniendo seguimiento de llegadas');
      _pollingTimer?.cancel();
      _pollingTimer = null;
      _currentStopCode = null;
      _currentRouteNumber = null;
      _lastArrivals = null;
      onArrivalsUpdated = null;
      onBusPassed = null;
      onBusApproaching = null;
    }
  }

  /// Realiza polling de llegadas
  Future<void> _pollArrivals() async {
    if (_currentStopCode == null || _currentRouteNumber == null) return;

    final arrivals = await getBusArrivals(_currentStopCode!);

    if (arrivals == null) {
      DebugLogger.navigation('⚠️ [TRACKING] No se pudieron obtener llegadas');
      return;
    }

    // Notificar actualización
    onArrivalsUpdated?.call(arrivals);

    // Verificar si el bus esperado ya pasó
    if (arrivals.hasBusPassed(_currentRouteNumber!)) {
      DebugLogger.navigation('🚨 [TRACKING] Bus $_currentRouteNumber ya pasó');
      onBusPassed?.call(_currentRouteNumber!);
      stopTracking(); // Detener tracking
      return;
    }

    // Buscar el bus específico que estamos esperando
    final targetBus = arrivals.findBus(_currentRouteNumber!);

    if (targetBus != null) {
      DebugLogger.navigation(
        '🚌 [TRACKING] Bus $_currentRouteNumber: ${targetBus.formattedDistance} (${targetBus.estimatedMinutes} min)',
      );

      // Alertar si el bus está muy cerca (< 2 minutos)
      if (targetBus.estimatedMinutes <= 2 && targetBus.estimatedMinutes > 0) {
        onBusApproaching?.call(targetBus);
      }
    } else {
      DebugLogger.navigation(
        '⚠️ [TRACKING] Bus $_currentRouteNumber no encontrado en llegadas',
      );

      // Si teníamos datos previos y ahora desapareció, posiblemente pasó
      if (_lastArrivals != null &&
          _lastArrivals!.findBus(_currentRouteNumber!) != null) {
        DebugLogger.navigation(
          '� [TRACKING] Bus $_currentRouteNumber desapareció - probablemente pasó',
        );
        onBusPassed?.call(_currentRouteNumber!);
        stopTracking();
        return;
      }
    }

    _lastArrivals = arrivals;
  }

  /// Obtiene el estado actual de tracking
  bool get isTracking => _pollingTimer != null && _pollingTimer!.isActive;

  String? get trackingStopCode => _currentStopCode;
  String? get trackingRouteNumber => _currentRouteNumber;
  StopArrivals? get lastArrivals => _lastArrivals;
}
