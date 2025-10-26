// ============================================================================
// INTEGRATED NAVIGATION SERVICE
// ============================================================================
// Combina Moovit scraping + GTFS data para navegación completa
// Detecta llegada a paraderos y guía al usuario en tiempo real
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import '../backend/api_client.dart';
import '../device/tts_service.dart';
import '../device/vibration_service.dart';
import '../backend/bus_arrivals_service.dart';
import '../debug_logger.dart';

// DEBUG MODE - Habilita logs detallados de JSON y geometrías
// ⚠️ IMPORTANTE: Cambiar a false en producción para optimizar rendimiento
const bool kDebugNavigation = true; // HABILITADO para debugging - ver todos los logs

// Helper function para logging que se muestra en consola
void _navLog(String message, {String? name}) {
  // No agregar prefijo extra - DebugLogger.navigation ya lo hace
  DebugLogger.navigation(message);
}

// =============================================================================
// MODELOS DE DATOS DEL BACKEND (de /api/red/itinerary)
// =============================================================================

class RedBusStop {
  final String name;
  final double latitude;
  final double longitude;
  final String? code;

  RedBusStop({
    required this.name,
    required this.latitude,
    required this.longitude,
    this.code,
  });

  factory RedBusStop.fromJson(Map<String, dynamic> json) {
    return RedBusStop(
      name: json['name'] as String? ?? '',
      latitude: (json['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 0.0,
      code: json['code'] as String?,
    );
  }

  LatLng get location => LatLng(latitude, longitude);
}

class RedBusLeg {
  final String type; // 'walk', 'bus'
  final String instruction;
  final bool isRedBus;
  final String? routeNumber;
  final RedBusStop? departStop;
  final RedBusStop? arriveStop;
  final List<RedBusStop>? stops;
  final double distanceKm;
  final int durationMinutes;
  final List<String>? streetInstructions;
  final List<LatLng>? geometry;

  RedBusLeg({
    required this.type,
    required this.instruction,
    required this.isRedBus,
    this.routeNumber,
    this.departStop,
    this.arriveStop,
    this.stops,
    required this.distanceKm,
    required this.durationMinutes,
    this.streetInstructions,
    this.geometry,
  });

  factory RedBusLeg.fromJson(Map<String, dynamic> json) {
    List<RedBusStop>? stops;
    if (json['stops'] != null) {
      stops = (json['stops'] as List)
          .map((s) => RedBusStop.fromJson(s as Map<String, dynamic>))
          .toList();
    }

    List<LatLng>? geometry;
    if (json['geometry'] != null) {
      geometry = (json['geometry'] as List)
          .map((g) {
            // Soportar dos formatos:
            // 1. Array: [longitude, latitude]
            // 2. Objeto: {"lat": ..., "lng": ...} o {"latitude": ..., "longitude": ...}
            if (g is List && g.length >= 2) {
              // Formato array [lng, lat] - estándar GeoJSON
              final lng = g[0];
              final lat = g[1];
              return LatLng(
                (lat is num) ? lat.toDouble() : (lat is String ? double.tryParse(lat) ?? 0.0 : 0.0),
                (lng is num) ? lng.toDouble() : (lng is String ? double.tryParse(lng) ?? 0.0 : 0.0),
              );
            } else if (g is Map<String, dynamic>) {
              // Formato objeto
              final lat = g['latitude'] ?? g['lat'];
              final lng = g['longitude'] ?? g['lng'];
              return LatLng(
                (lat is num) ? lat.toDouble() : (lat is String ? double.tryParse(lat) ?? 0.0 : 0.0),
                (lng is num) ? lng.toDouble() : (lng is String ? double.tryParse(lng) ?? 0.0 : 0.0),
              );
            } else {
              return const LatLng(0.0, 0.0);
            }
          })
          .toList();
    }

    // Determinar si es bus de la Red: el backend envía mode: "Red"
    final mode = json['mode'] as String? ?? '';
    final backendIsRedBus = json['is_red_bus'] as bool? ?? false;
    final isRedBus = (mode == 'Red' || backendIsRedBus);

    return RedBusLeg(
      type: json['type'] as String? ?? 'walk',
      instruction: json['instruction'] as String? ?? '',
      isRedBus: isRedBus,
      routeNumber: json['route_number'] as String?,
      departStop: json['depart_stop'] != null
          ? RedBusStop.fromJson(json['depart_stop'] as Map<String, dynamic>)
          : null,
      arriveStop: json['arrive_stop'] != null
          ? RedBusStop.fromJson(json['arrive_stop'] as Map<String, dynamic>)
          : null,
      stops: stops,
      distanceKm: (json['distance_km'] as num?)?.toDouble() ?? 0.0,
      durationMinutes: json['duration_minutes'] as int? ?? 0,
      streetInstructions: json['street_instructions'] != null
          ? List<String>.from(json['street_instructions'] as List)
          : null,
      geometry: geometry,
    );
  }
}

class RedBusItinerary {
  final String summary;
  final int totalDuration;
  final List<String> redBusRoutes;
  final List<RedBusLeg> legs;
  final LatLng origin;
  final LatLng destination;

  RedBusItinerary({
    required this.summary,
    required this.totalDuration,
    required this.redBusRoutes,
    required this.legs,
    required this.origin,
    required this.destination,
  });

  factory RedBusItinerary.fromJson(Map<String, dynamic> json) {
    // El backend puede envolver la respuesta en "options"[0] o directamente
    final data = json['options'] != null && (json['options'] as List).isNotEmpty
        ? (json['options'] as List)[0] as Map<String, dynamic>
        : json;

    return RedBusItinerary(
      summary: data['summary'] as String? ?? '',
      totalDuration: data['total_duration_minutes'] as int? ?? 
                     data['total_duration'] as int? ?? 0,
      redBusRoutes: data['red_bus_routes'] != null
          ? List<String>.from(data['red_bus_routes'] as List)
          : [],
      legs: (data['legs'] as List?)
              ?.map((l) => RedBusLeg.fromJson(l as Map<String, dynamic>))
              .toList() ??
          [],
      origin: LatLng(
        (data['origin']['latitude'] as num?)?.toDouble() ?? 
        (data['origin']['lat'] as num?)?.toDouble() ?? 0.0,
        (data['origin']['longitude'] as num?)?.toDouble() ?? 
        (data['origin']['lng'] as num?)?.toDouble() ?? 0.0,
      ),
      destination: LatLng(
        (data['destination']['latitude'] as num?)?.toDouble() ?? 
        (data['destination']['lat'] as num?)?.toDouble() ?? 0.0,
        (data['destination']['longitude'] as num?)?.toDouble() ?? 
        (data['destination']['lng'] as num?)?.toDouble() ?? 0.0,
      ),
    );
  }
}

// =============================================================================
// MODELOS INTERNOS DEL SERVICIO DE NAVEGACIÓN
// =============================================================================

class NavigationStep {
  final String type; // 'walk', 'bus', 'transfer', 'arrival'
  final String instruction;
  final LatLng? location;
  final String? stopId;
  final String? stopName;
  final String? busRoute;
  final List<String>? busOptions; // Para paraderos con múltiples buses
  final int estimatedDuration;
  final bool isCompleted;
  final int? totalStops; // Número total de paradas en el viaje
  final int? currentStop; // Parada actual (para contar progreso)
  final double?
  realDistanceMeters; // Distancia real calculada por el servicio de geometría
  final int? realDurationSeconds; // Duración real en segundos
  final List<String>?
  streetInstructions; // Instrucciones detalladas de navegación por calles
  final List<Map<String, dynamic>>? busStops; // Paradas completas del bus (del backend)

  NavigationStep({
    required this.type,
    required this.instruction,
    this.location,
    this.stopId,
    this.stopName,
    this.busRoute,
    this.busOptions,
    required this.estimatedDuration,
    this.isCompleted = false,
    this.totalStops,
    this.currentStop,
    this.realDistanceMeters,
    this.realDurationSeconds,
    this.streetInstructions,
    this.busStops,
  });

  NavigationStep copyWith({
    bool? isCompleted,
    int? currentStop,
    double? realDistanceMeters,
    int? realDurationSeconds,
    List<String>? streetInstructions,
  }) {
    return NavigationStep(
      type: type,
      instruction: instruction,
      location: location,
      stopId: stopId,
      stopName: stopName,
      busRoute: busRoute,
      busOptions: busOptions,
      estimatedDuration: estimatedDuration,
      isCompleted: isCompleted ?? this.isCompleted,
      totalStops: totalStops,
      currentStop: currentStop ?? this.currentStop,
      realDistanceMeters: realDistanceMeters ?? this.realDistanceMeters,
      realDurationSeconds: realDurationSeconds ?? this.realDurationSeconds,
      streetInstructions: streetInstructions ?? this.streetInstructions,
      busStops: busStops,
    );
  }
}

class ActiveNavigation {
  final String destination;
  final List<NavigationStep> steps;
  final List<LatLng> routeGeometry; // Geometría completa (para referencia)
  final Map<int, List<LatLng>> stepGeometries; // Geometría por cada paso
  final RedBusItinerary itinerary;
  final int estimatedDuration; // Duración total estimada en minutos
  int currentStepIndex;
  DateTime? startTime; // Hora de inicio de navegación
  DateTime? stepStartTime; // Hora de inicio del paso actual
  double? distanceToNextPoint; // Distancia al siguiente punto (metros)
  int? remainingTimeSeconds; // Tiempo restante estimado (segundos)

  ActiveNavigation({
    required this.destination,
    required this.steps,
    required this.routeGeometry,
    required this.stepGeometries,
    required this.itinerary,
    required this.estimatedDuration,
    this.currentStepIndex = 0,
    this.startTime,
    this.stepStartTime,
    this.distanceToNextPoint,
    this.remainingTimeSeconds,
  });

  NavigationStep? get currentStep =>
      currentStepIndex < steps.length ? steps[currentStepIndex] : null;

  // Obtener descripción del estado actual para TTS
  String getStatusDescription() {
    final step = currentStep;
    if (step == null) return 'Has llegado a tu destino';

    switch (step.type) {
      case 'walk':
        return 'Caminando hacia ${step.stopName ?? "el siguiente punto"}';
      case 'bus':
        return 'Viajando en el bus ${step.busRoute}';
      case 'arrival':
        return 'Llegando a tu destino';
      default:
        return 'En tránsito';
    }
  }

  // Obtener tiempo restante estimado del paso actual
  int? getCurrentStepRemainingTime() {
    final step = currentStep;
    if (step == null || stepStartTime == null) return null;

    final elapsed = DateTime.now().difference(stepStartTime!).inMinutes;
    final remaining = step.estimatedDuration - elapsed;
    return remaining > 0 ? remaining : 0;
  }

  // Geometría solo del paso ACTUAL usando el mapa de geometrías
  List<LatLng> getCurrentStepGeometry(LatLng currentPosition) {
    final step = currentStep;
    if (step == null) {
      _navLog('🔍 getCurrentStepGeometry: step es null');
      return [];
    }

    _navLog('🔍 getCurrentStepGeometry: Paso actual = ${step.type} (índice $currentStepIndex)');
    _navLog('🔍 Geometrías disponibles: ${stepGeometries.keys.toList()}');

    // Si tenemos geometría pre-calculada para este paso, usarla
    if (stepGeometries.containsKey(currentStepIndex)) {
      final geometry = stepGeometries[currentStepIndex]!;
      _navLog('🔍 Geometría encontrada para paso $currentStepIndex: ${geometry.length} puntos');

      // Si es paso de walk o bus, recortar geometría desde el punto más cercano al usuario
      if ((step.type == 'walk' || step.type == 'bus') &&
          geometry.length >= 2) {
        _navLog('🔍 Paso ${step.type.toUpperCase()}: Recortando geometría desde posición actual');

        // Encontrar el punto más cercano en la ruta al usuario
        int closestIndex = 0;
        double minDistance = double.infinity;

        for (int i = 0; i < geometry.length; i++) {
          final point = geometry[i];
          final distance = _calculateDistance(
            currentPosition.latitude,
            currentPosition.longitude,
            point.latitude,
            point.longitude,
          );

          if (distance < minDistance) {
            minDistance = distance;
            closestIndex = i;
          }
        }

        _navLog('🔍 Punto más cercano: índice $closestIndex (${minDistance.toStringAsFixed(0)}m)');

        // Si el usuario está muy cerca del punto más cercano (< 10m), usar ese punto
        // Si no, agregar la posición actual como primer punto
        if (minDistance < 10) {
          // Usuario muy cerca de la ruta, usar desde el punto más cercano
          return geometry.sublist(closestIndex);
        } else {
          // Usuario lejos de la ruta, agregar su posición y continuar desde el punto más cercano
          return [currentPosition, ...geometry.sublist(closestIndex)];
        }
      }

      _navLog('🔍 Retornando geometría pre-calculada');
      return geometry;
    }

    _navLog('⚠️ No hay geometría pre-calculada para paso $currentStepIndex');

    // Fallback: generar geometría básica
    if (step.location != null) {
      if (step.type == 'walk') {
        _navLog('🔍 Fallback: Creando geometría básica para WALK');
        return [currentPosition, step.location!];
      }
    }

    _navLog('⚠️ Sin geometría para este paso');
    return []; // Sin geometría
  }

  /// Calcula distancia en metros entre dos coordenadas
  double _calculateDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const double earthRadius = 6371000; // Radio de la Tierra en metros
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);

    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRadians(lat1)) *
            math.cos(_toRadians(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);

    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadius * c;
  }

  double _toRadians(double degrees) {
    return degrees * math.pi / 180;
  }

  bool get isComplete => currentStepIndex >= steps.length;

  void advanceToNextStep() {
    if (!isComplete) {
      // Guardar la ubicación del paso actual antes de avanzar
      final previousStep = currentStep;
      
      currentStepIndex++;
      stepStartTime = DateTime.now(); // Reiniciar tiempo del paso
      
      _navLog('➡️ Avanzando al paso $currentStepIndex');
      
      // CRÍTICO: Si el paso anterior tenía una ubicación (ej: paradero de bus),
      // actualizar _lastPosition para que la geometría del siguiente paso 
      // se dibuje desde ahí y no desde el origen inicial
      if (previousStep?.location != null) {
        _navLog('📍 Actualizando posición base a: ${previousStep!.location}');
        // Esta será la nueva posición de referencia para getCurrentStepGeometry
      }
    }
  }

  // Actualizar distancia al siguiente punto
  void updateDistanceToNext(double meters) {
    distanceToNextPoint = meters;

    // Estimar tiempo restante basado en velocidad promedio
    if (currentStep != null) {
      // Velocidad: 1.4 m/s caminando, bus variable
      final speedMps = currentStep!.type == 'walk' ? 1.4 : 5.0;
      remainingTimeSeconds = (meters / speedMps).round();
    }
  }

  // Inicializar tiempos cuando comienza la navegación
  void start() {
    startTime = DateTime.now();
    stepStartTime = DateTime.now();
  }
}

class IntegratedNavigationService {
  static final IntegratedNavigationService instance =
      IntegratedNavigationService._();
  IntegratedNavigationService._();

  final Distance _distance = const Distance();

  ActiveNavigation? _activeNavigation;
  StreamSubscription<Position>? _positionStream;
  Position? _lastPosition; // Última posición GPS recibida

  // Callbacks
  Function(NavigationStep)? onStepChanged;
  Function(String)? onArrivalAtStop;
  Function()? onDestinationReached;
  Function(String)? onBusDetected;
  Function()? onGeometryUpdated; // Nuevo: se llama cuando la geometría cambia
  Function(StopArrivals)? onBusArrivalsUpdated; // Nuevo: actualización de llegadas en tiempo real
  Function(String routeNumber)? onBusMissed; // Nuevo: bus ya pasó - recalcular ruta

  // Configuración de umbrales adaptativos
  static const double arrivalThresholdMeters =
      30.0; // 30m para considerar "llegada" (más estricto)
  static const double proximityAlertMeters =
      150.0; // 150m para alertar proximidad
  static const double gpsAccuracyThreshold =
      20.0; // Precisión GPS mínima aceptable (metros)
  static const double maxArrivalThreshold =
      50.0; // Umbral máximo incluso con GPS impreciso

  // Histórico de posiciones para suavizar detección
  final List<Position> _positionHistory = [];
  static const int maxPositionHistory = 5;

  // Control de anuncios duplicados
  int? _lastProximityAnnouncedStepIndex;
  int? _lastArrivalAnnouncedStepIndex;

  // Control de anuncios periódicos de progreso
  DateTime? _lastProgressAnnouncement;
  double? _lastAnnouncedDistance;

  // Control de paradas visitadas durante viaje en bus
  final Set<String> _announcedStops = {}; // IDs de paradas ya anunciadas
  int _currentBusStopIndex = 0; // Índice de la parada actual en el viaje

  // Detección de desviación de ruta
  static const double maxDistanceFromRoute = 50.0; // 50m máximo de desviación
  static const int deviationConfirmationCount = 3; // 3 muestras GPS consecutivas
  int _deviationCount = 0;
  bool _isOffRoute = false;
  DateTime? _lastDeviationAlert;
  static const Duration deviationAlertCooldown = Duration(seconds: 30); // Cooldown entre alertas

  /// Inicia navegación completa desde ubicación actual a destino
  Future<ActiveNavigation> startNavigation({
    required double originLat,
    required double originLon,
    required double destLat,
    required double destLon,
    required String destinationName,
    RedBusItinerary? existingItinerary, // Usar itinerario ya obtenido si existe
  }) async {
    _navLog('🚀 Iniciando navegación integrada a $destinationName');

    // Inicializar posición actual
    try {
      _lastPosition = await Geolocator.getCurrentPosition();
    } catch (e) {
      _navLog('⚠️ No se pudo obtener posición actual: $e');
      // Usar coordenadas del origen como fallback
      _lastPosition = Position(
        latitude: originLat,
        longitude: originLon,
        timestamp: DateTime.now(),
        accuracy: 0,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );
    }

    // 1. Usar itinerario existente o solicitar uno nuevo
    final RedBusItinerary itinerary;
    if (existingItinerary != null) {
      _navLog(
        '♻️ Usando itinerario ya obtenido (evita llamada duplicada)',
      );
      itinerary = existingItinerary;
    } else {
      _navLog('🔄 Solicitando nuevo itinerario al backend...');
      
      // Llamada directa al backend sin servicio intermedio
      final apiClient = ApiClient();
      final uri = Uri.parse('${apiClient.baseUrl}/api/red/itinerary');
      final body = {
        'origin_lat': originLat,
        'origin_lon': originLon,
        'dest_lat': destLat,
        'dest_lon': destLon,
      };

      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );

      if (response.statusCode != 200) {
        throw Exception('Error al obtener itinerario: ${response.statusCode}');
      }

      // 🔍 DEBUG: Mostrar resumen del backend (SIN geometrías completas)
      if (kDebugNavigation) {
        _navLog('═' * 80);
        _navLog('📥 [DEBUG] RESPUESTA DEL BACKEND (RESUMEN)');
        _navLog('═' * 80);
        _navLog('🔗 URL: ${uri.toString()}');
        _navLog('📤 Request: Origen=($originLat,$originLon), Destino=($destLat,$destLon)');
        _navLog('─' * 80);
        _navLog('📥 Response Status: ${response.statusCode}');
        _navLog('📦 Response Size: ${response.body.length} caracteres');
        _navLog('═' * 80);
      }

      try {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        _navLog('✅ JSON parseado correctamente');
        itinerary = RedBusItinerary.fromJson(data);
        _navLog('✅ Itinerario creado: ${itinerary.legs.length} legs');
      } catch (parseError, stackTrace) {
        _navLog('❌ ERROR parseando respuesta del backend:');
        _navLog('   Error: $parseError');
        _navLog('   Stack: ${stackTrace.toString().split('\n').take(5).join('\n')}');
        _navLog('   Response body (primeros 500 chars): ${response.body.substring(0, response.body.length > 500 ? 500 : response.body.length)}');
        rethrow;
      }
      
      // 🔍 DEBUG: Mostrar estructura del itinerario parseado
      if (kDebugNavigation) {
        _navLog('', name: 'Navigation');
        _navLog('📊 [DEBUG] ITINERARIO PARSEADO');
        _navLog('═' * 80, name: 'Navigation');
        _navLog('📍 Origen: (${itinerary.origin.latitude}, ${itinerary.origin.longitude})');
        _navLog('📍 Destino: (${itinerary.destination.latitude}, ${itinerary.destination.longitude})');
        _navLog('🚌 Buses Red: ${itinerary.redBusRoutes.join(", ")}');
        _navLog('⏱️  Duración total: ${itinerary.totalDuration} min');
        _navLog('️  Legs: ${itinerary.legs.length}');
        _navLog('─' * 80, name: 'Navigation');
        
        for (int i = 0; i < itinerary.legs.length; i++) {
          final leg = itinerary.legs[i];
          _navLog('  Leg ${i + 1}/${itinerary.legs.length}:');
          _navLog('    Tipo: ${leg.type}');
          _navLog('    Modo: ${leg.isRedBus ? "Red Bus" : "Normal"}');
          if (leg.routeNumber != null) {
            _navLog('    Ruta: ${leg.routeNumber}');
          }
          _navLog('    Desde: ${leg.departStop?.name ?? "N/A"}');
          _navLog('    Hasta: ${leg.arriveStop?.name ?? "N/A"}');
          _navLog('    Duración: ${leg.durationMinutes} min');
          _navLog('    Distancia: ${leg.distanceKm.toStringAsFixed(2)} km');
          _navLog('    Geometría: ${leg.geometry?.length ?? 0} puntos');
          
          if (leg.stops != null && leg.stops!.isNotEmpty) {
            _navLog('    Paradas: ${leg.stops!.length}');
            _navLog('      Primera: ${leg.stops!.first.name} [${leg.stops!.first.code ?? "sin código"}]');
            _navLog('      Última: ${leg.stops!.last.name} [${leg.stops!.last.code ?? "sin código"}]');
            if (leg.stops!.length > 2) {
              _navLog('      Intermedias: ${leg.stops!.length - 2} paradas');
            }
          }
          
          if (leg.streetInstructions != null && leg.streetInstructions!.isNotEmpty) {
            _navLog('    Instrucciones: ${leg.streetInstructions!.length}');
            for (int k = 0; k < leg.streetInstructions!.length; k++) {
              _navLog('      ${k + 1}. ${leg.streetInstructions![k]}');
            }
          }
          
          // Mostrar RESUMEN de geometría (NO iterar miles de puntos)
          if (leg.geometry != null && leg.geometry!.isNotEmpty) {
            _navLog('    📍 Geometría: ${leg.geometry!.length} puntos');
            _navLog('      Inicio: [${leg.geometry!.first.latitude.toStringAsFixed(6)}, ${leg.geometry!.first.longitude.toStringAsFixed(6)}]');
            _navLog('      Fin: [${leg.geometry!.last.latitude.toStringAsFixed(6)}, ${leg.geometry!.last.longitude.toStringAsFixed(6)}]');
          }
          
          _navLog('');
        }
        _navLog('═' * 80);
      }
    }

    _navLog('📋 Itinerario obtenido: ${itinerary.summary}');
    _navLog(
      '🚌 Buses Red recomendados: ${itinerary.redBusRoutes.join(", ")}',
    );

    // 2. Construir pasos de navegación detallados
    final steps = await _buildNavigationSteps(itinerary, originLat, originLon);

    // 3. Obtener geometría completa de la ruta
    final geometry = await _buildCompleteRouteGeometry(itinerary);

    // 4. Construir geometrías individuales para cada paso
    final stepGeometries = await _buildStepGeometries(
      steps,
      itinerary,
      LatLng(originLat, originLon),
    );

    // 5. Calcular duración total estimada
    final totalDuration = itinerary.legs.fold<int>(
      0,
      (sum, leg) => sum + leg.durationMinutes,
    );

    // 6. Crear navegación activa
    _activeNavigation = ActiveNavigation(
      destination: destinationName,
      steps: steps,
      routeGeometry: geometry,
      stepGeometries: stepGeometries,
      itinerary: itinerary,
      estimatedDuration: totalDuration,
    );

    // 6.1. Iniciar tiempos de navegación
    _activeNavigation!.start();

    // 7. Reiniciar control de anuncios
    _lastProximityAnnouncedStepIndex = null;
    _lastArrivalAnnouncedStepIndex = null;
    _announcedStops.clear(); // Limpiar paradas anunciadas
    _currentBusStopIndex = 0; // Resetear índice de parada

    // 8. Anunciar inicio de navegación
    _announceNavigationStart(destinationName, itinerary);

    // 9. Iniciar seguimiento GPS
    _startLocationTracking();

    return _activeNavigation!;
  }

  /// Construye pasos de navegación detallados desde el itinerario
  /// SIMPLIFICADO: Mapeo 1:1 con legs del backend
  Future<List<NavigationStep>> _buildNavigationSteps(
    RedBusItinerary itinerary,
    double currentLat,
    double currentLon,
  ) async {
    final steps = <NavigationStep>[];

    _navLog(
      '🚶 Construyendo pasos de navegación (1:1 con legs del backend)...',
    );
    _navLog('🚶 Legs del itinerario: ${itinerary.legs.length}');

    // Mapeo DIRECTO 1:1: cada leg del backend = 1 paso en el frontend
    for (var i = 0; i < itinerary.legs.length; i++) {
      final leg = itinerary.legs[i];

      if (leg.type == 'walk') {
        // Paso de caminata
        final walkTo = leg.arriveStop?.location;

        if (walkTo != null) {
          _navLog('🚶 Paso WALK hasta ${leg.arriveStop?.name}');

          steps.add(
            NavigationStep(
              type: 'walk',
              instruction: leg.instruction.isNotEmpty
                  ? leg.instruction
                  : 'Camina ${(leg.distanceKm * 1000).toInt()} metros hasta ${leg.arriveStop?.name}',
              location: walkTo,
              stopName: leg.arriveStop?.name,
              estimatedDuration: leg.durationMinutes,
              realDistanceMeters: leg.distanceKm * 1000,
              realDurationSeconds: leg.durationMinutes * 60,
              streetInstructions:
                  (leg.streetInstructions != null &&
                      leg.streetInstructions!.isNotEmpty)
                  ? List<String>.from(leg.streetInstructions!)
                  : <String>[leg.instruction],
            ),
          );
        }
      } else if (leg.type == 'bus' && leg.isRedBus) {
        // ═══════════════════════════════════════════════════════════════
        // PASO DE BUS: Crear DOS pasos separados
        // 1. wait_bus - Esperar el bus en el paradero
        // 2. ride_bus - Viajar en el bus
        // ═══════════════════════════════════════════════════════════════
        _navLog(
          '🚌 Paso BUS ${leg.routeNumber}: ${leg.departStop?.name} → ${leg.arriveStop?.name}',
        );
        _navLog(
          '🚌 Paradas en el bus: ${leg.stops?.length ?? 0}',
        );

        // Convertir stops a formato simple para el NavigationStep
        List<Map<String, dynamic>>? busStops;
        if (leg.stops != null && leg.stops!.isNotEmpty) {
          busStops = leg.stops!.map((stop) {
            return {
              'name': stop.name,
              'code': stop.code,
              'lat': stop.location.latitude,
              'lng': stop.location.longitude,
            };
          }).toList();

          _navLog(
            '🚌 Paradas convertidas: ${busStops.length} paradas',
          );
          _navLog(
            '   Primera: ${busStops.first['name']} [${busStops.first['code']}]',
          );
          _navLog(
            '   Última: ${busStops.last['name']} [${busStops.last['code']}]',
          );
        }

        // PASO 1: WAIT_BUS - Esperar el bus en el paradero de subida
        _navLog('🚏 Creando paso WAIT_BUS en ${leg.departStop?.name}');
        steps.add(
          NavigationStep(
            type: 'wait_bus',
            instruction:
                'Espera el bus Red ${leg.routeNumber} en ${leg.departStop?.name}',
            location: leg.departStop?.location,
            stopId: null,
            stopName: leg.departStop?.name,
            busRoute: leg.routeNumber,
            busOptions: const [],
            estimatedDuration: 5, // 5 minutos de espera estimada
            totalStops: leg.stops?.length,
            realDistanceMeters: 0, // No hay distancia en espera
            realDurationSeconds: 300, // 5 minutos
            busStops: busStops,
          ),
        );

        // PASO 2: RIDE_BUS - Viajar en el bus
        _navLog('🚌 Creando paso RIDE_BUS hasta ${leg.arriveStop?.name}');
        steps.add(
          NavigationStep(
            type: 'ride_bus',
            instruction:
                'Viaja en el bus Red ${leg.routeNumber} hasta ${leg.arriveStop?.name}',
            location: leg.arriveStop?.location,
            stopId: null,
            stopName: leg.arriveStop?.name,
            busRoute: leg.routeNumber,
            busOptions: const [],
            estimatedDuration: leg.durationMinutes,
            totalStops: leg.stops?.length,
            realDistanceMeters: leg.distanceKm * 1000,
            realDurationSeconds: leg.durationMinutes * 60,
            busStops: busStops,
          ),
        );
      }
    }

    // Log de todos los pasos generados
    _navLog('🚶 ===== PASOS DE NAVEGACIÓN GENERADOS =====');
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      _navLog('🚶 Paso $i: ${step.type} - ${step.instruction}');
      if (step.type == 'bus') {
        _navLog(
          '   └─ Bus: ${step.busRoute}, StopName: ${step.stopName}',
        );
      }
    }
    _navLog('🚶 ==========================================');

    return steps;
  }

  // /// Obtiene información del paradero desde GTFS por nombre
  // Future<Map<String, dynamic>?> _getStopInfoFromGTFS(String stopName) async {
  //   // TODO: Implementar cuando ApiClient tenga método get()
  //   // final response = await ApiClient.instance.get('/api/stops/search?name=$stopName');
  //   return null;
  // }

  // /// Obtiene lista de buses que pasan por un paradero
  // Future<List<String>> _getBusesAtStop(String stopId) async {
  //   // TODO: Implementar cuando ApiClient tenga método get()
  //   // final response = await ApiClient.instance.get('/api/stops/$stopId/routes');
  //   return [];
  // }

  /// Construye la geometría completa de la ruta
  Future<List<LatLng>> _buildCompleteRouteGeometry(
    RedBusItinerary itinerary,
  ) async {
    final geometry = <LatLng>[];

    for (var leg in itinerary.legs) {
      if (leg.geometry != null && leg.geometry!.isNotEmpty) {
        geometry.addAll(leg.geometry!);
      } else if (leg.departStop != null && leg.arriveStop != null) {
        // Si no hay geometría, crear línea recta entre puntos
        geometry.add(leg.departStop!.location);
        geometry.add(leg.arriveStop!.location);
      }
    }

    return geometry;
  }

  /// Construye geometrías individuales para cada paso de navegación
  /// SIMPLIFICADO: Mapeo directo 1:1 con legs del backend
  Future<Map<int, List<LatLng>>> _buildStepGeometries(
    List<NavigationStep> steps,
    RedBusItinerary itinerary,
    LatLng origin,
  ) async {
    final geometries = <int, List<LatLng>>{};

    // ═══════════════════════════════════════════════════════════════
    // MAPEO CORRECTO: steps vs legs
    // Ahora que wait_bus y ride_bus son pasos separados del mismo leg:
    // - walk → walk (1:1)
    // - bus → wait_bus + ride_bus (1:2)
    // - walk → walk (1:1)
    // ═══════════════════════════════════════════════════════════════
    
    int legIndex = 0;
    
    for (int stepIndex = 0; stepIndex < steps.length; stepIndex++) {
      final step = steps[stepIndex];
      
      _navLog('🗺️ [GEOMETRY] Paso $stepIndex: ${step.type}');
      
      // Determinar qué leg corresponde a este paso
      if (step.type == 'walk') {
        // Paso walk corresponde directamente a un leg walk
        if (legIndex < itinerary.legs.length) {
          final leg = itinerary.legs[legIndex];
          
          if (leg.type == 'walk' && leg.geometry != null && leg.geometry!.isNotEmpty) {
            geometries[stepIndex] = List.from(leg.geometry!);
            _navLog('   ✅ Geometría walk: ${leg.geometry!.length} puntos (leg $legIndex)');
          }
          legIndex++; // Avanzar al siguiente leg
        }
      } else if (step.type == 'wait_bus') {
        // wait_bus NO tiene geometría (es solo esperar)
        // La geometría será del paradero (punto único)
        if (step.location != null) {
          geometries[stepIndex] = [step.location!];
          _navLog('   ✅ Geometría wait_bus: Punto único en paradero');
        }
        // NO incrementar legIndex porque ride_bus usará el mismo leg
      } else if (step.type == 'ride_bus' || step.type == 'bus') {
        // ride_bus corresponde al leg de bus (mismo que wait_bus)
        if (legIndex < itinerary.legs.length) {
          final leg = itinerary.legs[legIndex];
          
          if (leg.type == 'bus' && leg.geometry != null && leg.geometry!.isNotEmpty) {
            geometries[stepIndex] = List.from(leg.geometry!);
            _navLog('   ✅ Geometría ride_bus: ${leg.geometry!.length} puntos (leg $legIndex)');
          }
          legIndex++; // Ahora sí avanzar al siguiente leg
        }
      }
    }

    _navLog(
      '🗺️ [GEOMETRY] Geometrías creadas para pasos: ${geometries.keys.toList()}',
    );
    return geometries;
  }

  /// Anuncia el inicio de navegación por voz
  void _announceNavigationStart(String destination, RedBusItinerary itinerary) {
    // Construir mensaje detallado del viaje
    final busLegs = itinerary.legs.where((leg) => leg.type == 'bus').toList();

    String busInfo = '';
    String arrivalInfo = '';
    if (busLegs.isNotEmpty) {
      final firstBusLeg = busLegs.first;
      busInfo = 'Debes tomar el bus ${firstBusLeg.routeNumber}';

      // Calcular tiempo de llegada de la micro (estimado en base al tiempo de caminata)
      int walkTimeMinutes = 0;
      if (_activeNavigation?.currentStep?.type == 'walk') {
        walkTimeMinutes = _activeNavigation!.currentStep!.estimatedDuration;
      }

      // Tiempo estimado hasta que llegue la micro (caminata + espera promedio de 5-10 min)
      final estimatedArrivalMinutes =
          walkTimeMinutes + 7; // Promedio 7 min de espera
      arrivalInfo =
          'La micro llegará en aproximadamente $estimatedArrivalMinutes minutos';

      if (busLegs.length > 1) {
        busInfo += ' y luego harás ${busLegs.length - 1} transbordo';
        if (busLegs.length > 2) busInfo += 's';
      }
      busInfo += '. ';
    }

    // SOLO construir instrucción del primer paso si es caminata
    String firstStepInstruction = '';
    if (_activeNavigation?.currentStep != null) {
      final step = _activeNavigation!.currentStep!;

      // SOLO anunciar el primer paso si es 'walk'
      if (step.type == 'walk' && step.stopName != null) {
        final distance = (step.estimatedDuration * 80).toInt();
        firstStepInstruction =
            'Dirígete caminando hacia el paradero ${step.stopName}. '
            'Distancia aproximada: $distance metros. '
            'Tiempo estimado: ${step.estimatedDuration} minuto';
        if (step.estimatedDuration > 1) firstStepInstruction += 's';
        firstStepInstruction += '. ';

        // Agregar info de la micro
        firstStepInstruction += '$busInfo$arrivalInfo. ';

        // Agregar instrucciones de calle si están disponibles CON DISTANCIAS
        if (step.streetInstructions != null &&
            step.streetInstructions!.isNotEmpty) {
          final enrichedInstructions = _enrichStreetInstructions(
            step.streetInstructions!,
            _activeNavigation!.stepGeometries[_activeNavigation!.currentStepIndex],
          );
          
          if (enrichedInstructions.isNotEmpty) {
            firstStepInstruction += 'Comienza así: ${enrichedInstructions.first}. ';
          }
        }
      }
    }

    // Mensaje inicial completo y directo
    String message;
    if (firstStepInstruction.isNotEmpty) {
      message = firstStepInstruction.trim();
    } else {
      // Caso sin caminata (raro): anunciar info completa
      message =
          '''
Ruta calculada hacia $destination. 
$busInfo$arrivalInfo
Duración total estimada: ${itinerary.totalDuration} minutos. 
Te iré guiando paso a paso.
''';
    }

    _navLog(message);

    // Una sola llamada TTS para todo el anuncio inicial
    TtsService.instance.speak(message, urgent: true);
  }

  /// Inicia seguimiento GPS en tiempo real
  void _startLocationTracking() {
    _positionStream?.cancel();

    _positionStream =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10, // Actualizar cada 10 metros
          ),
        ).listen((Position position) {
          _onLocationUpdate(position);
        });
  }

  /// Actualiza la posición simulada (para testing/simulación)
  /// Esto permite que la geometría se recorte desde la posición correcta
  void updateSimulatedPosition(Position position) {
    _lastPosition = position;
    _navLog('📍 [SIMULATED] Posición actualizada: ${position.latitude}, ${position.longitude}');
    
    // Notificar cambio de geometría para actualizar el mapa
    if (onGeometryUpdated != null) {
      onGeometryUpdated!();
    }
  }

  /// Maneja actualizaciones de ubicación
  void _onLocationUpdate(Position position) {
    if (_activeNavigation == null || _activeNavigation!.isComplete) return;

    // Guardar última posición
    _lastPosition = position;

    // Notificar cambio de geometría (para actualizar el mapa en tiempo real)
    if (onGeometryUpdated != null) {
      onGeometryUpdated!();
    }

    // Filtrar posiciones con baja precisión GPS
    if (position.accuracy > gpsAccuracyThreshold) {
      _navLog(
        '⚠️ GPS con baja precisión: ${position.accuracy.toStringAsFixed(1)}m (umbral: ${gpsAccuracyThreshold}m)',
      );
      
      return;
    }

    // Agregar al histórico de posiciones
    _positionHistory.add(position);
    if (_positionHistory.length > maxPositionHistory) {
      _positionHistory.removeAt(0);
    }

    // Usar posición promediada para mayor estabilidad
    final smoothedPosition = _getSmoothPosition();

    final currentStep = _activeNavigation!.currentStep;
    if (currentStep == null) return;

    final userLocation = LatLng(
      smoothedPosition.latitude,
      smoothedPosition.longitude,
    );

    // Verificar si llegó a la ubicación del paso actual
    if (currentStep.location != null) {
      double distanceToTarget;

      // Si el paso tiene distancia real calculada por OSRM, usarla
      // Para pasos de caminata, OSRM da la distancia real por calles
      if (currentStep.type == 'walk' &&
          currentStep.realDistanceMeters != null) {
        // Para pasos walk con OSRM: calcular distancia restante basada en geometría de ruta
        final geometry = _activeNavigation!.getCurrentStepGeometry(
          userLocation,
        );
        if (geometry.isNotEmpty) {
          // Sumar distancia punto a punto en la geometría restante
          distanceToTarget = 0;
          for (int i = 0; i < geometry.length - 1; i++) {
            distanceToTarget += _distance.as(
              LengthUnit.Meter,
              geometry[i],
              geometry[i + 1],
            );
          }
          _navLog(
            '🗺️ Distancia real restante (GraphHopper): ${distanceToTarget.toStringAsFixed(1)}m',
          );
        } else {
          // Fallback: línea recta
          distanceToTarget = _distance.as(
            LengthUnit.Meter,
            userLocation,
            currentStep.location!,
          );
          _navLog(
            '⚠️ Usando distancia línea recta (sin geometría): ${distanceToTarget.toStringAsFixed(1)}m',
          );
        }
      } else {
        // Para otros tipos de paso o sin OSRM: línea recta
        distanceToTarget = _distance.as(
          LengthUnit.Meter,
          userLocation,
          currentStep.location!,
        );
        _navLog(
          '📍 Distancia línea recta: ${distanceToTarget.toStringAsFixed(1)}m',
        );
      }

      _navLog(
        '📍 Distancia al objetivo: ${distanceToTarget.toStringAsFixed(1)}m (GPS: ${position.accuracy.toStringAsFixed(1)}m)',
      );

      // Actualizar distancia en el objeto de navegación
      _activeNavigation!.updateDistanceToNext(distanceToTarget);

      // ⚠️ DETECCIÓN DE DESVIACIÓN DE RUTA (AUTOMÁTICA CON GPS REAL)
      // ============================================================
      // Este sistema funciona AUTOMÁTICAMENTE con GPS real del usuario
      // NO requiere botón de simulación - se activa con cada update GPS
      // Detecta cuando el usuario se aleja >50m de la ruta planificada
      // Alerta: Vibración + TTS contextual con nombre de calle
      // ============================================================
      _checkRouteDeviation(userLocation, currentStep);

      // Anunciar progreso periódicamente (cada 100m para caminata, cada 500m para bus)
      _announceProgressIfNeeded(currentStep, distanceToTarget);

      // Alerta de proximidad (solo si no se ha anunciado antes)
      if (distanceToTarget <= proximityAlertMeters &&
          distanceToTarget > arrivalThresholdMeters) {
        _announceProximity(currentStep);
      }

      // Llegada al objetivo (ajustar threshold según precisión GPS, pero con límite máximo)
      final adjustedThreshold = math.min(
        arrivalThresholdMeters + (position.accuracy * 0.3),
        maxArrivalThreshold,
      );

      _navLog(
        '🎯 Umbral ajustado: ${adjustedThreshold.toStringAsFixed(1)}m (GPS accuracy: ${position.accuracy.toStringAsFixed(1)}m)',
      );

      if (distanceToTarget <= adjustedThreshold) {
        _handleStepArrival(currentStep);
      }
    }

    // Si está en un paso de bus, detectar si está esperando o ya subió
    if (currentStep.type == 'bus') {
      // Si está cerca del paradero de inicio Y no se ha movido mucho, está esperando
      final busLegs = _activeNavigation!.itinerary.legs
          .where((leg) => leg.type == 'bus')
          .toList();
      
      if (busLegs.isNotEmpty) {
        final busLeg = busLegs.first;
        final departStop = busLeg.departStop?.location;
        
        if (departStop != null) {
          final distanceToStart = _distance.as(
            LengthUnit.Meter,
            userLocation,
            departStop,
          );
          
          // Si está cerca del paradero de inicio (< 50m) y velocidad baja, está esperando
          if (distanceToStart < 50 && position.speed < 1.0) {
            _navLog('🚌 Usuario esperando el bus en el paradero');
          }
          // Si está moviéndose rápido, asumimos que subió al bus
          else if (position.speed > 2.0) {
            _navLog(
              '🚌 [BUS-RIDING] Usuario en movimiento (${position.speed.toStringAsFixed(1)} m/s) - Anunciando paradas',
            );
            // Anunciar paradas intermedias
            _checkBusStopsProgress(currentStep, userLocation);
          }
        }
      }
    }
  }

  /// Obtiene una posición suavizada usando el promedio de las últimas posiciones
  Position _getSmoothPosition() {
    if (_positionHistory.isEmpty) {
      return _positionHistory.last;
    }

    double sumLat = 0;
    double sumLon = 0;
    int count = _positionHistory.length;

    for (var pos in _positionHistory) {
      sumLat += pos.latitude;
      sumLon += pos.longitude;
    }

    return Position(
      latitude: sumLat / count,
      longitude: sumLon / count,
      timestamp: _positionHistory.last.timestamp,
      accuracy: _positionHistory.last.accuracy,
      altitude: _positionHistory.last.altitude,
      heading: _positionHistory.last.heading,
      speed: _positionHistory.last.speed,
      speedAccuracy: _positionHistory.last.speedAccuracy,
      altitudeAccuracy: _positionHistory.last.altitudeAccuracy,
      headingAccuracy: _positionHistory.last.headingAccuracy,
    );
  }

  /// Anuncia proximidad al objetivo
  void _announceProximity(NavigationStep step) {
    // Evitar anuncios duplicados para el mismo paso
    if (_lastProximityAnnouncedStepIndex ==
        _activeNavigation?.currentStepIndex) {
      return;
    }

    String message = '';

    switch (step.type) {
      case 'walk':
        message = 'Te estás acercando al paradero ${step.stopName}';
        break;
      case 'bus':
        message = 'Próxima parada: ${step.stopName}';
        break;
      case 'arrival':
        message = 'Estás cerca de tu destino';
        break;
    }

    if (message.isNotEmpty) {
      TtsService.instance.speak(message);
      _lastProximityAnnouncedStepIndex = _activeNavigation?.currentStepIndex;
    }
  }

  /// Anuncia progreso periódicamente durante la navegación
  void _announceProgressIfNeeded(NavigationStep step, double distanceMeters) {
    final now = DateTime.now();

    // Intervalos de anuncio según tipo de paso
    final announceInterval = step.type == 'walk'
        ? const Duration(minutes: 1) // Cada minuto caminando
        : const Duration(minutes: 2); // Cada 2 minutos en bus

    // Intervalos de distancia para anunciar
    final distanceThreshold = step.type == 'walk'
        ? 100.0 // Cada 100m caminando
        : 500.0; // Cada 500m en bus

    // Verificar si es momento de anunciar
    bool shouldAnnounce = false;

    // Primera vez o pasó suficiente tiempo
    if (_lastProgressAnnouncement == null ||
        now.difference(_lastProgressAnnouncement!) >= announceInterval) {
      shouldAnnounce = true;
    }

    // O cambió significativamente la distancia
    if (_lastAnnouncedDistance != null &&
        (_lastAnnouncedDistance! - distanceMeters).abs() >= distanceThreshold) {
      shouldAnnounce = true;
    }

    if (!shouldAnnounce) return;

    // Construir mensaje de progreso
    String message = '';
    final timeRemaining = _activeNavigation?.remainingTimeSeconds;

    if (step.type == 'walk') {
      final meters = distanceMeters.round();
      final minutes = timeRemaining != null
          ? (timeRemaining / 60).ceil()
          : null;

      if (meters > 100) {
        final simplifiedStopName = _simplifyStopNameForTTS(
          step.stopName,
          isDestination: true,
        );
        message = 'Continúa caminando. Faltan $meters metros';
        if (minutes != null && minutes > 0) {
          message +=
              ', aproximadamente $minutes ${minutes == 1 ? "minuto" : "minutos"}';
        }
        message += ' para llegar al $simplifiedStopName';
      }
    } else if (step.type == 'bus') {
      final km = (distanceMeters / 1000).toStringAsFixed(1);
      final simplifiedStopName = _simplifyStopNameForTTS(
        step.stopName,
        isDestination: true,
      );
      message =
          'Viajando en bus ${step.busRoute}. Faltan $km kilómetros hasta $simplifiedStopName';
    }

    if (message.isNotEmpty) {
      _navLog('📢 [PROGRESO] $message');
      TtsService.instance.speak(message);
      _lastProgressAnnouncement = now;
      _lastAnnouncedDistance = distanceMeters;
    }
  }

  /// Maneja llegada a un paso
  void _handleStepArrival(NavigationStep step) {
    _navLog('✅ Llegada al paso: ${step.type}');

    // Evitar anuncios duplicados para el mismo paso
    if (_lastArrivalAnnouncedStepIndex == _activeNavigation?.currentStepIndex) {
      return;
    }

    String announcement = '';
    bool shouldAutoAdvance = true;

    switch (step.type) {
      case 'walk':
        final simplifiedStopName = _simplifyStopNameForTTS(
          step.stopName,
          isDestination: true,
        );
        
        // Verificar si el siguiente paso es un bus
        final currentIndex = _activeNavigation!.currentStepIndex;
        final allSteps = _activeNavigation!.steps;
        bool hasNextBusStep = false;
        String? busRoute;
        int? estimatedMinutes;
        
        if (currentIndex < allSteps.length - 1) {
          final nextStep = allSteps[currentIndex + 1];
          if (nextStep.type == 'bus' || nextStep.type == 'wait_bus') {
            hasNextBusStep = true;
            busRoute = nextStep.busRoute;
            
            // NO avanzar automáticamente cuando el siguiente paso es bus
            shouldAutoAdvance = false;
            _navLog('⏸️ Esperando confirmación del usuario para subir al bus');
            
            // INICIAR TRACKING DE LLEGADAS EN TIEMPO REAL
            final stopCode = _extractStopCode(step.stopName);
            
            if (stopCode != null && busRoute != null) {
              _navLog('🚌 [ARRIVALS] Iniciando tracking: Bus $busRoute en $stopCode');
              
              BusArrivalsService.instance.startTracking(
                stopCode: stopCode,
                routeNumber: busRoute,
                onUpdate: (arrivals) {
                  _navLog('🔄 [ARRIVALS] Actualización: ${arrivals.arrivals.length} buses');
                  onBusArrivalsUpdated?.call(arrivals);
                  

                  // Extraer tiempo estimado del primer bus de la ruta solicitada
                  final busArrival = arrivals.arrivals.firstWhere(
                    (a) => a.routeNumber == busRoute,
                    orElse: () => arrivals.arrivals.first,
                  );
                  estimatedMinutes = busArrival.estimatedMinutes;
                },
                onBusPassed: (routeNumber) {
                  _navLog('🚨 [ARRIVALS] Bus $routeNumber ya pasó - activando recálculo');
                  onBusMissed?.call(routeNumber);
                },
                onApproaching: (busArrival) {
                  _navLog('⚠️ [ARRIVALS] Bus ${busArrival.routeNumber} llegando en ${busArrival.estimatedMinutes} min');
                  VibrationService.instance.tripleVibration();
                  TtsService.instance.speak('El bus ${busArrival.routeNumber} está llegando', urgent: true);
                },
              );
            } else {
              _navLog('⚠️ [ARRIVALS] No se pudo extraer stopCode o busRoute para tracking');
            }
          }
        }
        
        // CONSTRUIR MENSAJE FLUIDO SIN CORTES
        if (hasNextBusStep && busRoute != null) {
          // Mensaje con toda la información en un solo TTS
          announcement = 'Has llegado al $simplifiedStopName. Espera el bus $busRoute';
          if (estimatedMinutes != null && estimatedMinutes! > 0) {
            announcement += ' que está a $estimatedMinutes ${estimatedMinutes == 1 ? "minuto" : "minutos"}';
          }
          announcement += '.';
