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
        // Paso de bus: UN SOLO paso tipo 'bus' (simplificado)
        // La detección de subir al bus se hará por velocidad GPS
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

        steps.add(
          NavigationStep(
            type: 'bus',
            instruction:
                'Toma el bus Red ${leg.routeNumber} en ${leg.departStop?.name} hasta ${leg.arriveStop?.name}',
            location: leg.arriveStop?.location,
            stopId: null, // Sin consultar GTFS para optimizar
            stopName: leg.arriveStop?.name,
            busRoute: leg.routeNumber,
            busOptions: const [], // Sin consultar para optimizar
            estimatedDuration: leg.durationMinutes + 5, // Incluye espera
            totalStops: leg.stops?.length,
            realDistanceMeters: leg.distanceKm * 1000,
            realDurationSeconds: leg.durationMinutes * 60,
            busStops: busStops, // Paradas del backend
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

    for (int i = 0; i < steps.length && i < itinerary.legs.length; i++) {
      final step = steps[i];
      final leg = itinerary.legs[i];

      _navLog(
        '🗺️ [SIMPLE] Paso $i: step.type=${step.type} ← leg.type=${leg.type}',
      );

      // Validar que los tipos coincidan
      if ((step.type == 'walk' && leg.type != 'walk') ||
          (step.type == 'bus' && leg.type != 'bus')) {
        _navLog('   ⚠️ [SIMPLE] ADVERTENCIA: Tipos no coinciden!');
      }

      // Usar geometría del backend directamente
      if (leg.geometry != null && leg.geometry!.isNotEmpty) {
        geometries[i] = List.from(leg.geometry!);
        _navLog(
          '   ✅ [SIMPLE] Geometría: ${leg.geometry!.length} puntos',
        );

        if (leg.departStop != null || leg.arriveStop != null) {
          _navLog(
            '   📍 [SIMPLE] ${leg.departStop?.name ?? "Inicio"} → ${leg.arriveStop?.name ?? "Destino"}',
          );
        }
      } else {
        // Fallback: línea recta entre origen y destino
        final start = leg.departStop?.location ?? origin;
        final end = leg.arriveStop?.location ?? step.location;

        if (end != null) {
          geometries[i] = [start, end];
          _navLog('   ⚠️ [SIMPLE] Fallback línea recta (2 puntos)');
        } else {
          _navLog('   ❌ [SIMPLE] Sin geometría disponible');
        }
      }
    }

    _navLog(
      '🗺️ [SIMPLE] Geometrías creadas: ${geometries.keys.toList()}',
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

        // Agregar instrucciones de calle si están disponibles
        if (step.streetInstructions != null &&
            step.streetInstructions!.isNotEmpty) {
          final firstStreetInstruction = step.streetInstructions!.first;
          firstStepInstruction += 'Comienza así: $firstStreetInstruction. ';
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
        '⚠️ GPS con baja precisión: ${position.accuracy.toStringAsFixed(1)}m - Ignorando',
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
        announcement = 'Has llegado al $simplifiedStopName. ';
        if (step.busOptions != null && step.busOptions!.isNotEmpty) {
          announcement += 'Buses disponibles: ${step.busOptions!.join(", ")}';
        }
        onArrivalAtStop?.call(step.stopId ?? '');
        
        // Verificar si el siguiente paso es un bus
        final currentIndex = _activeNavigation!.currentStepIndex;
        final allSteps = _activeNavigation!.steps;
        if (currentIndex < allSteps.length - 1) {
          final nextStep = allSteps[currentIndex + 1];
          if (nextStep.type == 'bus') {
            // NO avanzar automáticamente cuando el siguiente paso es bus
            // El usuario debe confirmar que subió usando el botón "Simular"
            shouldAutoAdvance = false;
            _navLog('⏸️ Esperando confirmación del usuario para subir al bus');
          }
        }
        break;

      case 'bus':
        // Cuando llega al destino del paso de bus (paradero de bajada)
        final simplifiedStopName = _simplifyStopNameForTTS(
          step.stopName,
          isDestination: true,
        );
        announcement = 'Bájate aquí. Has llegado a $simplifiedStopName';
        // Resetear control de paradas para el siguiente viaje
        _announcedStops.clear();
        _currentBusStopIndex = 0;
        break;

      case 'arrival':
        announcement = '¡Felicitaciones! Has llegado a tu destino';
        onDestinationReached?.call();
        stopNavigation();
        break;
    }

    // Marcar que se anunció este paso
    _lastArrivalAnnouncedStepIndex = _activeNavigation?.currentStepIndex;

    // Solo avanzar automáticamente si corresponde
    if (shouldAutoAdvance) {
      // Avanzar al siguiente paso
      _activeNavigation!.advanceToNextStep();

      // Resetear control de anuncios de progreso para el nuevo paso
      _lastProgressAnnouncement = null;
      _lastAnnouncedDistance = null;

      final nextStep = _activeNavigation!.currentStep;
      onStepChanged?.call(nextStep ?? step);

      // Combinar anuncio actual con el siguiente paso
      String fullAnnouncement = announcement;

      if (!_activeNavigation!.isComplete && fullAnnouncement.isNotEmpty) {
        final nextStep = _activeNavigation!.currentStep!;
        fullAnnouncement += ' Ahora, ${nextStep.instruction}';
      }

      if (fullAnnouncement.isNotEmpty) {
        TtsService.instance.speak(fullAnnouncement);
      }
    } else {
      // Solo anunciar la llegada, sin avanzar al siguiente paso
      if (announcement.isNotEmpty) {
        TtsService.instance.speak(announcement);
      }
    }
  }

  // /// Detecta buses cercanos usando datos de tiempo real
  // Future<void> _detectNearbyBuses(
  //   NavigationStep step,
  //   LatLng userLocation,
  // ) async {
  //   if (step.stopId == null) return;

  //   // TODO: Implementar cuando ApiClient tenga método getBusArrivals()
  //   /*
  //   try {
  //     // Consultar API de tiempo real para obtener llegadas próximas
  //     final arrivals = await ApiClient.instance.getBusArrivals(step.stopId!);
  //     
  //     if (arrivals.isNotEmpty) {
  //       final nextBus = arrivals.first;
  //       final routeShortName = nextBus['route_short_name'] ?? '';
  //       final etaMinutes = nextBus['eta_minutes'] ?? 0;
  //       
  //       if (etaMinutes <= 5) {
  //         TtsService.instance.speak(
  //           'El bus $routeShortName llegará en $etaMinutes minutos.',
  //         );
  //       }
  //     }
  //   } catch (e) {
  //     _navLog('⚠️ [BUS_DETECTION] Error detectando buses cercanos: $e');
  //   }
  //   */
  // }

  /// Verifica progreso a través de paradas de bus durante viaje en bus
  /// Anuncia cada parada cuando el usuario pasa cerca
  void _checkBusStopsProgress(NavigationStep step, LatLng userLocation) {
    // Usar paradas almacenadas directamente en el NavigationStep
    final busStops = step.busStops;

    if (busStops == null || busStops.isEmpty) {
      _navLog(
        '⚠️ [BUS_STOPS] No hay paradas disponibles en el paso actual',
      );
      return;
    }

    _navLog(
      '🚌 [BUS_STOPS] Verificando progreso: ${busStops.length} paradas totales, índice actual: $_currentBusStopIndex',
    );

    // Verificar cercanía a cada parada (en orden)
    for (int i = _currentBusStopIndex; i < busStops.length; i++) {
      final stop = busStops[i];
      final stopLocation = LatLng(
        stop['lat'] as double,
        stop['lng'] as double,
      );

      final distanceToStop = _distance.as(
        LengthUnit.Meter,
        userLocation,
        stopLocation,
      );

      _navLog(
        '🚌 [STOP $i] ${stop['name']}: ${distanceToStop.toStringAsFixed(0)}m',
      );

      // Si está cerca de esta parada (50m) y no se ha anunciado
      final stopId = '${stop['name']}_$i';
      if (distanceToStop <= 50.0 && !_announcedStops.contains(stopId)) {
        _navLog(
          '✅ [BUS_STOPS] Parada detectada a ${distanceToStop.toStringAsFixed(0)}m - Anunciando...',
        );
        _announceCurrentBusStop(stop, i + 1, busStops.length);
        _announcedStops.add(stopId);
        _currentBusStopIndex = i + 1; // Avanzar al siguiente índice
        break; // Solo anunciar una parada a la vez
      }
    }
  }

  /// Anuncia la parada actual del bus
  void _announceCurrentBusStop(
    Map<String, dynamic> stop,
    int stopNumber,
    int totalStops,
  ) {
    final isLastStop = stopNumber == totalStops;
    final isFirstStop = stopNumber == 1;

    // OPTIMIZACIÓN: Si hay más de 10 paradas, solo anunciar paradas clave
    // para demostración (primeras 3, algunas intermedias, últimas 2)
    if (totalStops > 10 && !isFirstStop && !isLastStop) {
      // Calcular si esta parada debe ser anunciada
      final shouldAnnounce = _shouldAnnounceStop(stopNumber, totalStops);
      if (!shouldAnnounce) {
        _navLog(
          '⏭️ [TTS] Parada $stopNumber omitida (solo anuncio de paradas clave)',
        );
        return; // Saltar esta parada
      }
    }

    final stopName = stop['name'] as String;
    final stopCode = stop['code'] as String?;

    String announcement;
    if (isLastStop) {
      final codeStr = stopCode != null && stopCode.isNotEmpty
          ? 'código $stopCode, '
          : '';
      announcement =
          'Próxima parada: $codeStr$stopName. Es tu parada de bajada. Prepárate para descender.';
    } else if (isFirstStop) {
      final codeStr = stopCode != null && stopCode.isNotEmpty
          ? 'código $stopCode, '
          : '';
      announcement =
          'Primera parada: $codeStr$stopName. Ahora estás en el bus.';
    } else {
      final codeStr = stopCode != null && stopCode.isNotEmpty
          ? 'código $stopCode, '
          : '';
      announcement = 'Parada $stopNumber de $totalStops: $codeStr$stopName';
    }

    _navLog('🔔 [TTS] $announcement');
    TtsService.instance.speak(announcement);
  }

  /// Determina si una parada debe ser anunciada para demostración
  /// Cuando hay más de 10 paradas, solo anuncia:
  /// - Primeras 3 paradas (índices 1, 2, 3)
  /// - Algunas intermedias (2-3 paradas en el medio)
  /// - Últimas 2 paradas (penúltima y última)
  bool _shouldAnnounceStop(int stopNumber, int totalStops) {
    // Primera parada
    if (stopNumber == 1) return true;

    // Primeras 3 paradas
    if (stopNumber <= 3) return true;

    // Últimas 2 paradas
    if (stopNumber >= totalStops - 1) return true;

    // Paradas intermedias estratégicas
    final middlePoint = (totalStops / 2).round();
    final quarterPoint = (totalStops / 4).round();
    final threeQuarterPoint = ((totalStops * 3) / 4).round();

    // Anunciar paradas en cuartos del recorrido
    if (stopNumber == quarterPoint ||
        stopNumber == middlePoint ||
        stopNumber == threeQuarterPoint) {
      return true;
    }

    return false; // Omitir el resto de paradas
  }

  /// Detiene la navegación activa
  void stopNavigation() {
    _positionStream?.cancel();
    _activeNavigation = null;
    _announcedStops.clear(); // Limpiar paradas anunciadas
    _currentBusStopIndex = 0; // Resetear índice
    _navLog('🛑 Navegación detenida');
  }

  /// Obtiene el paso actual
  NavigationStep? get currentStep => _activeNavigation?.currentStep;

  /// Verifica si hay navegación activa
  bool get hasActiveNavigation => _activeNavigation != null;

  /// Obtiene la navegación activa
  ActiveNavigation? get activeNavigation => _activeNavigation;

  /// Obtiene la última posición GPS conocida
  Position? get lastPosition => _lastPosition;

  // Geometría del paso actual usando la última posición GPS
  List<LatLng> get currentStepGeometry {
    if (_activeNavigation == null || _lastPosition == null) {
      _navLog('🗺️ [GEOMETRY] activeNavigation o lastPosition es null');
      return [];
    }

    final currentPos = LatLng(
      _lastPosition!.latitude,
      _lastPosition!.longitude,
    );

    final geometry = _activeNavigation!.getCurrentStepGeometry(currentPos);
    _navLog(
      '🗺️ [GEOMETRY] Retornando geometría del paso ${_activeNavigation!.currentStepIndex}: ${geometry.length} puntos',
    );

    return geometry;
  }

  /// Repite la instrucción actual
  void repeatCurrentInstruction() {
    final step = _activeNavigation?.currentStep;
    if (step != null) {
      TtsService.instance.speak(step.instruction);
    }
  }

  /// Cancela la navegación
  void cancelNavigation() {
    stopNavigation();
    TtsService.instance.speak('Navegación cancelada');
  }

  /// Avanza al siguiente paso de navegación
  void advanceToNextStep() {
    if (_activeNavigation == null) {
      _navLog('⚠️ No hay navegación activa');
      return;
    }

    final currentIndex = _activeNavigation!.currentStepIndex;
    if (currentIndex + 1 >= _activeNavigation!.steps.length) {
      _navLog('⚠️ Ya estás en el último paso de navegación');
      return;
    }

    // Guardar el paso actual antes de avanzar
    final previousStep = _activeNavigation!.currentStep;
    
    _activeNavigation!.currentStepIndex++;
    final newStep = _activeNavigation!.currentStep;

    _navLog(
      '📍 [STEP] Avanzando paso: $currentIndex → ${_activeNavigation!.currentStepIndex}',
    );
    _navLog(
      '📍 [STEP] Nuevo paso: ${newStep?.type} - ${newStep?.instruction}',
    );

    // CRÍTICO: Actualizar _lastPosition a la ubicación del paso anterior
    // Esto asegura que la geometría del nuevo paso se dibuje desde la posición correcta
    if (previousStep?.location != null && _lastPosition != null) {
      _lastPosition = Position(
        latitude: previousStep!.location!.latitude,
        longitude: previousStep.location!.longitude,
        timestamp: DateTime.now(),
        accuracy: 10.0,
        altitude: _lastPosition!.altitude,
        altitudeAccuracy: _lastPosition!.altitudeAccuracy,
        heading: _lastPosition!.heading,
        headingAccuracy: _lastPosition!.headingAccuracy,
        speed: 0.0,
        speedAccuracy: _lastPosition!.speedAccuracy,
      );
      _navLog('📍 [STEP] Posición actualizada al final del paso anterior: ${previousStep.location}');
    }

    // Notificar cambio de paso
    if (newStep != null && onStepChanged != null) {
      onStepChanged!(newStep);
    }
    
    // Notificar cambio de geometría
    if (onGeometryUpdated != null) {
      onGeometryUpdated!();
    }
  }

  /// TEST: Simula una posición GPS para testing
  /// Útil para probar la navegación sin caminar físicamente
  void simulatePosition(Position position) {
    _navLog(
      '🧪 [TEST] Inyectando posición simulada: ${position.latitude}, ${position.longitude}',
    );
    _onLocationUpdate(position);
  }

  // =========================================================================
  // COMANDOS DE VOZ
  // =========================================================================

  /// Procesa comandos de voz relacionados con navegación
  /// Retorna true si el comando fue manejado
  Future<bool> handleVoiceCommand(String command) async {
    final lowerCommand = command.toLowerCase().trim();

    _navLog('🎤 [VOICE] Comando recibido: "$lowerCommand"');

    // Comando: "cuando llega la micro" / "cuando llega el bus"
    if (_isAskingForBusArrivals(lowerCommand)) {
      return await _handleBusArrivalsCommand();
    }

    // Comando: "dónde estoy" / "ubicación actual"
    if (_isAskingForLocation(lowerCommand)) {
      return await _handleLocationCommand();
    }

    // Comando: "cuánto falta" / "tiempo restante"
    if (_isAskingForRemainingTime(lowerCommand)) {
      return await _handleRemainingTimeCommand();
    }

    // Comando: "repetir instrucción" / "qué hago ahora"
    if (_isAskingForCurrentInstruction(lowerCommand)) {
      return await _handleRepeatInstructionCommand();
    }

    _navLog('⚠️ [VOICE] Comando no reconocido');
    return false;
  }

  bool _isAskingForBusArrivals(String command) {
    final patterns = [
      'cuando llega',
      'cuándo llega',
      'que micro',
      'qué micro',
      'que bus',
      'qué bus',
      'buses próximos',
      'micros próximas',
      'próximo bus',
      'próxima micro',
    ];
    return patterns.any((pattern) => command.contains(pattern));
  }

  bool _isAskingForLocation(String command) {
    final patterns = [
      'dónde estoy',
      'donde estoy',
      'mi ubicación',
      'ubicación actual',
      'dónde me encuentro',
    ];
    return patterns.any((pattern) => command.contains(pattern));
  }

  bool _isAskingForRemainingTime(String command) {
    final patterns = [
      'cuánto falta',
      'cuanto falta',
      'tiempo restante',
      'cuánto me falta',
      'a qué hora llego',
    ];
    return patterns.any((pattern) => command.contains(pattern));
  }

  bool _isAskingForCurrentInstruction(String command) {
    final patterns = [
      'repetir',
      'qué hago',
      'que hago',
      'instrucción',
      'indicación',
      'cómo sigo',
      'como sigo',
    ];
    return patterns.any((pattern) => command.contains(pattern));
  }

  Future<bool> _handleBusArrivalsCommand() async {
    _navLog('🚌 [VOICE] Procesando comando: Cuando llega la micro');

    // Información de llegadas ya no se consulta durante navegación activa
    // para evitar bloqueo del main thread
    if (_activeNavigation != null) {
      TtsService.instance.speak(
        'Las paradas serán anunciadas durante tu viaje en bus',
        urgent: true,
      );
      return true;
    }

    // Si no hay navegación activa o no estamos en un paradero,
    // buscar paradero más cercano usando GPS
    if (_lastPosition != null) {
      _navLog('🚌 [VOICE] Buscando paradero cercano a posición GPS...');

      try {
        final arrivals = await BusArrivalsService.instance
            .getBusArrivalsByLocation(
              _lastPosition!.latitude,
              _lastPosition!.longitude,
            );

        if (arrivals != null && arrivals.arrivals.isNotEmpty) {
          TtsService.instance.speak(arrivals.arrivalsSummary, urgent: true);
          return true;
        } else {
          TtsService.instance.speak(
            'No encontré paraderos cercanos con información de buses',
            urgent: true,
          );
          return true;
        }
      } catch (e) {
        _navLog('❌ [VOICE] Error buscando paradero cercano: $e');
        TtsService.instance.speak(
          'No pude encontrar paraderos cercanos',
          urgent: true,
        );
        return true;
      }
    }

    TtsService.instance.speak(
      'No tengo información de tu ubicación para buscar paraderos',
      urgent: true,
    );
    return true;
  }

  Future<bool> _handleLocationCommand() async {
    _navLog('📍 [VOICE] Procesando comando: Dónde estoy');

    if (_lastPosition != null) {
      final lat = _lastPosition!.latitude.toStringAsFixed(6);
      final lon = _lastPosition!.longitude.toStringAsFixed(6);

      TtsService.instance.speak(
        'Estás en latitud $lat, longitud $lon',
        urgent: true,
      );
      return true;
    }

    TtsService.instance.speak(
      'No tengo información de tu ubicación',
      urgent: true,
    );
    return false;
  }

  Future<bool> _handleRemainingTimeCommand() async {
    _navLog('⏱️ [VOICE] Procesando comando: Cuánto falta');

    if (_activeNavigation == null) {
      TtsService.instance.speak('No hay navegación activa', urgent: true);
      return false;
    }

    final currentStep = _activeNavigation!.currentStep;
    if (currentStep == null) {
      TtsService.instance.speak('Has llegado a tu destino', urgent: true);
      return true;
    }

    final statusDesc = _activeNavigation!.getStatusDescription();
    String message = statusDesc;

    if (_activeNavigation!.distanceToNextPoint != null) {
      final distanceM = _activeNavigation!.distanceToNextPoint!;
      if (distanceM < 1000) {
        message += ', faltan ${distanceM.round()} metros';
      } else {
        message +=
            ', faltan ${(distanceM / 1000).toStringAsFixed(1)} kilómetros';
      }
    }

    if (_activeNavigation!.remainingTimeSeconds != null) {
      final mins = (_activeNavigation!.remainingTimeSeconds! / 60).ceil();
      message += ', aproximadamente $mins ${mins == 1 ? "minuto" : "minutos"}';
    }

    TtsService.instance.speak(message, urgent: true);
    return true;
  }

  Future<bool> _handleRepeatInstructionCommand() async {
    _navLog('🔄 [VOICE] Procesando comando: Repetir instrucción');

    if (_activeNavigation == null) {
      TtsService.instance.speak('No hay navegación activa', urgent: true);
      return false;
    }

    final currentStep = _activeNavigation!.currentStep;
    if (currentStep == null) {
      TtsService.instance.speak('Has llegado a tu destino', urgent: true);
      return true;
    }

    TtsService.instance.speak(currentStep.instruction, urgent: true);
    return true;
  }

  /// Simplifica nombres de paraderos para TTS
  /// Convierte "PC1237-Raúl Labbé / esq. Av. La Dehesa" en "Paradero"
  String _simplifyStopNameForTTS(
    String? stopName, {
    bool isDestination = false,
  }) {
    if (stopName == null || stopName.isEmpty) {
      return 'el destino';
    }

    // Si es el destino final o contiene "paradero", simplificar a solo "Paradero"
    if (isDestination ||
        stopName.toLowerCase().contains('paradero') ||
        stopName.toLowerCase().contains('parada')) {
      return 'Paradero';
    }

    // Para otros casos, remover códigos pero mantener la calle
    String cleaned = stopName;

    // Remover código de paradero (PC/PA/PB seguido de números)
    cleaned = cleaned.replaceAll(RegExp(r'P[A-Z]\d+\s*[-/]\s*'), '');

    // Remover "Paradero" o "Parada" seguido de números
    cleaned = cleaned.replaceAll(RegExp(r'Paradero\s+\d+\s*[-/]\s*'), '');
    cleaned = cleaned.replaceAll(RegExp(r'Parada\s+\d+\s*[-/]\s*'), '');

    // Limpiar espacios extra
    cleaned = cleaned.trim();

    // Si después de limpiar está vacío, retornar "Paradero"
    if (cleaned.isEmpty) {
      return 'Paradero';
    }

    return cleaned;
  }
}
