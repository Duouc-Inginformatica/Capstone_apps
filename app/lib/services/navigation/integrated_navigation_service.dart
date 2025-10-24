import 'dart:developer' as developer;
// ============================================================================
// INTEGRATED NAVIGATION SERVICE
// ============================================================================
// Combina Moovit scraping + GTFS data para navegación completa
// Detecta llegada a paraderos y guía al usuario en tiempo real
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import '../backend/api_client.dart';
import '../device/tts_service.dart';
import '../backend/bus_arrivals_service.dart';

// Helper para logs que se muestran tanto en consola como en developer tools
void _log(String message) {
  debugPrint('[IntegratedNav] $message');
  developer.log(message, name: 'IntegratedNavigation');
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
<<<<<<< HEAD:app/lib/services/navigation/integrated_navigation_service.dart
      try {
        geometry = (json['geometry'] as List)
            .map((g) {
              if (g == null) return null;
              
              // El backend devuelve arrays: [LONGITUD, LATITUD] (formato GeoJSON estándar)
              if (g is List && g.length >= 2) {
                final lon = (g[0] as num?)?.toDouble();  // Primer valor es longitud
                final lat = (g[1] as num?)?.toDouble();  // Segundo valor es latitud
                
                if (lat == null || lon == null) return null;
                return LatLng(lat, lon);  // LatLng espera (latitud, longitud)
              }
              
              // Fallback: si viene como Map {lat, lng}
              if (g is Map) {
                final gMap = g as Map<String, dynamic>;
                final lat = (gMap['lat'] as num?)?.toDouble();
                final lng = (gMap['lng'] as num?)?.toDouble();
                
                if (lat == null || lng == null) return null;
                return LatLng(lat, lng);
              }
              
              debugPrint('[RedBusLeg] ⚠️ geometry item formato desconocido: ${g.runtimeType}');
              return null;
            })
            .whereType<LatLng>() // Filtrar nulls
            .toList();
      } catch (e) {
        debugPrint('[RedBusLeg] ⚠️ Error parseando geometry: $e');
        geometry = null;
      }
    }

    // Inferir isRedBus del campo 'mode' o si tiene route_number
    bool inferredIsRedBus = false;
    if (json['is_red_bus'] != null) {
      inferredIsRedBus = json['is_red_bus'] as bool;
    } else if (json['mode'] != null) {
      final mode = (json['mode'] as String).toLowerCase();
      inferredIsRedBus = mode == 'red' || mode == 'bus';
    } else if (json['route_number'] != null) {
      inferredIsRedBus = true; // Si tiene número de ruta, asumimos que es Red
=======
      geometry = (json['geometry'] as List)
          .map((g) {
            // La geometría viene como [[lon, lat], [lon, lat]] desde el backend (formato GeoJSON/GraphHopper)
            // LatLng de Google Maps espera (lat, lon), así que invertimos el orden
            if (g is List && g.length >= 2) {
              return LatLng(
                (g[1] as num).toDouble(), // lat - segunda posición en GeoJSON
                (g[0] as num).toDouble(), // lon - primera posición en GeoJSON
              );
            }
            // Fallback por si viene como objeto (compatibilidad)
            return LatLng(
              (g['lat'] as num?)?.toDouble() ?? 0.0,
              (g['lng'] as num?)?.toDouble() ?? 0.0,
            );
          })
          .toList();
>>>>>>> 88b8f82315f1ef3e7674c7eb0beb04ff488bcc78:app/lib/services/integrated_navigation_service.dart
    }

    return RedBusLeg(
      type: json['type'] as String? ?? 'walk',
      instruction: json['instruction'] as String? ?? '',
<<<<<<< HEAD:app/lib/services/navigation/integrated_navigation_service.dart
      isRedBus: inferredIsRedBus,
=======
      isRedBus: (json['mode'] as String?) == 'Red', // Determinar si es Red Bus basado en el campo 'mode'
>>>>>>> 88b8f82315f1ef3e7674c7eb0beb04ff488bcc78:app/lib/services/integrated_navigation_service.dart
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
    // Parsear origin con null-safety
    LatLng origin;
    if (json['origin'] != null && json['origin'] is Map) {
      final originMap = json['origin'] as Map<String, dynamic>;
      origin = LatLng(
        (originMap['lat'] as num?)?.toDouble() ?? 0.0,
        (originMap['lng'] as num?)?.toDouble() ?? 0.0,
      );
    } else {
      origin = const LatLng(0.0, 0.0);
    }

    // Parsear destination con null-safety
    LatLng destination;
    if (json['destination'] != null && json['destination'] is Map) {
      final destMap = json['destination'] as Map<String, dynamic>;
      destination = LatLng(
        (destMap['lat'] as num?)?.toDouble() ?? 0.0,
        (destMap['lng'] as num?)?.toDouble() ?? 0.0,
      );
    } else {
      destination = const LatLng(0.0, 0.0);
    }

    return RedBusItinerary(
      summary: json['summary'] as String? ?? 'Ruta calculada',
      totalDuration: json['total_duration_minutes'] as int? ?? 0,
      redBusRoutes: json['red_bus_routes'] != null
          ? List<String>.from(json['red_bus_routes'] as List)
          : [],
      legs: (json['legs'] as List?)
              ?.map((l) => RedBusLeg.fromJson(l as Map<String, dynamic>))
              .toList() ??
          [],
<<<<<<< HEAD:app/lib/services/navigation/integrated_navigation_service.dart
      origin: origin,
      destination: destination,
=======
      origin: LatLng(
        (json['origin']['latitude'] as num?)?.toDouble() ?? 0.0,
        (json['origin']['longitude'] as num?)?.toDouble() ?? 0.0,
      ),
      destination: LatLng(
        (json['destination']['latitude'] as num?)?.toDouble() ?? 0.0,
        (json['destination']['longitude'] as num?)?.toDouble() ?? 0.0,
      ),
>>>>>>> 88b8f82315f1ef3e7674c7eb0beb04ff488bcc78:app/lib/services/integrated_navigation_service.dart
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
      developer.log('🔍 getCurrentStepGeometry: step es null');
      return [];
    }

    developer.log(
      '🔍 getCurrentStepGeometry: Paso actual = ${step.type} (índice $currentStepIndex)',
    );
    developer.log('🔍 Geometrías disponibles: ${stepGeometries.keys.toList()}');

    // Si tenemos geometría pre-calculada para este paso, usarla
    if (stepGeometries.containsKey(currentStepIndex)) {
      final geometry = stepGeometries[currentStepIndex]!;
      developer.log(
        '🔍 Geometría encontrada para paso $currentStepIndex: ${geometry.length} puntos',
      );

      // Si es paso de walk o bus, recortar geometría desde el punto más cercano al usuario
      if ((step.type == 'walk' || step.type == 'bus') &&
          geometry.length >= 2) {
        developer.log(
          '🔍 Paso ${step.type.toUpperCase()}: Recortando geometría desde posición actual',
        );

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

        developer.log(
          '🔍 Punto más cercano: índice $closestIndex (${minDistance.toStringAsFixed(0)}m)',
        );

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

      developer.log('🔍 Retornando geometría pre-calculada');
      return geometry;
    }

    developer.log(
      '⚠️ No hay geometría pre-calculada para paso $currentStepIndex',
    );

    // Fallback: generar geometría básica
    if (step.location != null) {
      if (step.type == 'walk') {
        developer.log('🔍 Fallback: Creando geometría básica para WALK');
        return [currentPosition, step.location!];
      }
    }

    developer.log('⚠️ Sin geometría para este paso');
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
      currentStepIndex++;
      stepStartTime = DateTime.now(); // Reiniciar tiempo del paso
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
    _log('🚀 [START] Iniciando navegación integrada a $destinationName');
    _log('📍 [START] Origen: ($originLat, $originLon)');
    _log('📍 [START] Destino: ($destLat, $destLon)');

    try {
      // Inicializar posición actual
      try {
        _lastPosition = await Geolocator.getCurrentPosition();
        _log('✅ [GPS] Posición actual obtenida');
      } catch (e) {
        _log('⚠️ [GPS] No se pudo obtener posición actual: $e');
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
      _log(
        '♻️ Usando itinerario ya obtenido (evita llamada duplicada)',
      );
      itinerary = existingItinerary;
    } else {
      _log('🔄 Solicitando nuevo itinerario al backend...');
      
      // Llamada directa al backend sin servicio intermedio
      final apiClient = ApiClient();
      final uri = Uri.parse('${apiClient.baseUrl}/api/red/itinerary');
      final body = {
        'origin_lat': originLat,
        'origin_lon': originLon,
        'dest_lat': destLat,
        'dest_lon': destLon,
      };

      _log('🌐 [HTTP] POST $uri');
      _log('📤 [HTTP] Body: ${jsonEncode(body)}');

      final requestTime = DateTime.now();
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
      
      final elapsed = DateTime.now().difference(requestTime);
      _log('⏱️ [HTTP] Respuesta en ${elapsed.inSeconds}s (${elapsed.inMilliseconds}ms)');
      _log('📥 [HTTP] Status: ${response.statusCode}');
      _log('📥 [HTTP] Body length: ${response.body.length} bytes');

      if (response.statusCode != 200) {
        _log('❌ [HTTP] Error response body: ${response.body}');
        throw Exception('Error al obtener itinerario: ${response.statusCode}');
      }

      _log('✅ [HTTP] Decodificando JSON...');
      final data = jsonDecode(response.body) as Map<String, dynamic>;
<<<<<<< HEAD:app/lib/services/navigation/integrated_navigation_service.dart
      _log('✅ [HTTP] JSON keys: ${data.keys.join(", ")}');
      
      // Debug: Imprimir JSON COMPLETO recibido del backend
      _log('🔍 [JSON COMPLETO] ================================');
      final jsonString = jsonEncode(data);
      // Dividir en chunks de 1000 caracteres para que no se trunque
      for (int i = 0; i < jsonString.length; i += 1000) {
        final end = (i + 1000 < jsonString.length) ? i + 1000 : jsonString.length;
        _log('🔍 [JSON PART ${i ~/ 1000 + 1}] ${jsonString.substring(i, end)}');
      }
      _log('🔍 [JSON COMPLETO] ================================');
      
      // Debug: Ver estructura completa
      _log('🔍 [JSON] origin: ${data['origin']}');
      _log('🔍 [JSON] destination: ${data['destination']}');
      
      // El backend devuelve la ruta en 'options' (array de opciones)
      // Tomar la primera opción si existe
      Map<String, dynamic> routeData;
      if (data['options'] != null && data['options'] is List && (data['options'] as List).isNotEmpty) {
        final options = data['options'] as List;
        _log('🔍 [JSON] ${options.length} opciones de ruta disponibles');
        routeData = options[0] as Map<String, dynamic>;
        _log('🔍 [JSON] Usando opción 1: ${routeData.keys.join(", ")}');
      } else {
        _log('❌ [JSON] No hay opciones de ruta disponibles');
        throw Exception('El backend no devolvió opciones de ruta');
      }
      
      _log('🏗️ [PARSE] Construyendo RedBusItinerary...');
      itinerary = RedBusItinerary.fromJson(routeData);
      _log('✅ [PARSE] Itinerario construido exitosamente');
=======
      
      // El backend retorna RouteOptions con un array "options"
      // Tomamos la primera opción
      if (data['options'] == null || (data['options'] as List).isEmpty) {
        throw Exception('No se encontraron opciones de ruta');
      }
      
      final firstOption = (data['options'] as List)[0] as Map<String, dynamic>;
      itinerary = RedBusItinerary.fromJson(firstOption);
>>>>>>> 88b8f82315f1ef3e7674c7eb0beb04ff488bcc78:app/lib/services/integrated_navigation_service.dart
    }

    _log('📋 Itinerario obtenido: ${itinerary.summary}');
    _log(
      '🚌 Buses Red recomendados: ${itinerary.redBusRoutes.join(", ")}',
    );
    _log('🗺️ [ITINERARY] Tiene ${itinerary.legs.length} legs');

    // 2. Construir pasos de navegación detallados
    _log('🏗️ [BUILD] Construyendo pasos de navegación...');
    final steps = await _buildNavigationSteps(itinerary, originLat, originLon);
    _log('✅ [BUILD] ${steps.length} pasos construidos');

    // 3. Obtener geometría completa de la ruta
    _log('🗺️ [GEOMETRY] Construyendo geometría completa...');
    final geometry = await _buildCompleteRouteGeometry(itinerary);
    _log('✅ [GEOMETRY] ${geometry.length} puntos en geometría');

    // 4. Construir geometrías individuales para cada paso
    _log('🗺️ [STEP_GEO] Construyendo geometrías por paso...');
    final stepGeometries = await _buildStepGeometries(
      steps,
      itinerary,
      LatLng(originLat, originLon),
    );
    _log('✅ [STEP_GEO] ${stepGeometries.length} geometrías de pasos');

    // 5. Calcular duración total estimada
    final totalDuration = itinerary.legs.fold<int>(
      0,
      (sum, leg) => sum + leg.durationMinutes,
    );
    _log('⏱️ [DURATION] Duración total estimada: $totalDuration min');

    // 6. Crear navegación activa
    _log('🎯 [NAV] Creando ActiveNavigation...');
    _activeNavigation = ActiveNavigation(
      destination: destinationName,
      steps: steps,
      routeGeometry: geometry,
      stepGeometries: stepGeometries,
      itinerary: itinerary,
      estimatedDuration: totalDuration,
    );
    _log('✅ [NAV] ActiveNavigation creado exitosamente');

    // 6.1. Iniciar tiempos de navegación
    _activeNavigation!.start();
    _log('⏰ [NAV] Tiempos de navegación iniciados');

    // 7. Reiniciar control de anuncios
    _lastProximityAnnouncedStepIndex = null;
    _lastArrivalAnnouncedStepIndex = null;
    _announcedStops.clear(); // Limpiar paradas anunciadas
    _currentBusStopIndex = 0; // Resetear índice de parada
    _log('🔄 [NAV] Control de anuncios reiniciado');

    // 8. Anunciar inicio de navegación
    _announceNavigationStart(destinationName, itinerary);

    // 9. Iniciar seguimiento GPS
    _startLocationTracking();
    _log('📍 [GPS] Seguimiento de ubicación iniciado');

    _log('🎉 [SUCCESS] Navegación iniciada exitosamente con ${steps.length} pasos');
    return _activeNavigation!;
    
    } catch (e, stackTrace) {
      _log('❌ [ERROR] Error crítico en startNavigation: $e');
      _log('📚 [ERROR] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Construye pasos de navegación detallados desde el itinerario
  /// SIMPLIFICADO: Mapeo 1:1 con legs del backend
  Future<List<NavigationStep>> _buildNavigationSteps(
    RedBusItinerary itinerary,
    double currentLat,
    double currentLon,
  ) async {
    final steps = <NavigationStep>[];

    developer.log(
      '🚶 Construyendo pasos de navegación (1:1 con legs del backend)...',
    );
    developer.log('🚶 Legs del itinerario: ${itinerary.legs.length}');

    // Mapeo DIRECTO 1:1: cada leg del backend = 1 paso en el frontend
    for (var i = 0; i < itinerary.legs.length; i++) {
      final leg = itinerary.legs[i];
      
      developer.log('📦 Leg ${i+1}/${itinerary.legs.length}: type="${leg.type}", isRedBus=${leg.isRedBus}, routeNumber=${leg.routeNumber}');

      if (leg.type == 'walk') {
        // Paso de caminata
        developer.log('🚶 Paso ${i+1} WALK: ${leg.instruction}');
        developer.log('   └─ Distancia RAW del JSON: ${leg.distanceKm}km');
        developer.log('   └─ Distancia en metros (x1000): ${(leg.distanceKm * 1000).toInt()}m');
        developer.log('   └─ Duración: ${leg.durationMinutes}min');
        developer.log('   └─ DepartStop: ${leg.departStop?.name ?? "N/A"}');
        developer.log('   └─ ArriveStop: ${leg.arriveStop?.name ?? "N/A"}');

        // Determinar destino del paso de caminata
        String instruction = leg.instruction;
        if (instruction.isEmpty) {
          if (leg.arriveStop != null) {
            instruction = 'Camina hacia el paradero ${leg.arriveStop!.name}';
          } else if (leg.departStop != null) {
            instruction = 'Camina desde ${leg.departStop!.name}';
          } else if (i == 0) {
            instruction = 'Camina hacia el paradero de inicio';
          } else if (i == itinerary.legs.length - 1) {
            instruction = 'Camina hacia tu destino';
          } else {
            instruction = 'Camina ${(leg.distanceKm * 1000).toInt()} metros';
          }
        }

        steps.add(
          NavigationStep(
            type: 'walk',
            instruction: instruction,
            location: leg.arriveStop?.location ?? leg.departStop?.location,
            stopName: leg.arriveStop?.name ?? leg.departStop?.name,
            estimatedDuration: leg.durationMinutes,
            realDistanceMeters: leg.distanceKm * 1000,
            realDurationSeconds: leg.durationMinutes * 60,
            streetInstructions:
                (leg.streetInstructions != null &&
                    leg.streetInstructions!.isNotEmpty)
                ? List<String>.from(leg.streetInstructions!)
                : <String>[instruction],
          ),
        );
      } else if (leg.type == 'bus' && leg.isRedBus) {
        // Paso de bus: UN SOLO paso tipo 'bus' (simplificado)
        // La detección de subir al bus se hará por velocidad GPS
        developer.log(
          '🚌 Paso BUS ${leg.routeNumber}: ${leg.departStop?.name} → ${leg.arriveStop?.name}',
        );
        developer.log(
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

          developer.log(
            '🚌 Paradas convertidas: ${busStops.length} paradas',
          );
          developer.log(
            '   Primera: ${busStops.first['name']} [${busStops.first['code']}]',
          );
          developer.log(
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
      } else {
        // Leg no reconocido
        developer.log('⚠️ Leg tipo "${leg.type}" no reconocido o isRedBus=${leg.isRedBus}');
        developer.log('   └─ routeNumber: ${leg.routeNumber}');
        developer.log('   └─ instruction: ${leg.instruction}');
      }
    }

    // Log de todos los pasos generados
    developer.log('🚶 ===== PASOS DE NAVEGACIÓN GENERADOS =====');
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      developer.log('🚶 Paso $i: ${step.type} - ${step.instruction}');
      if (step.type == 'bus') {
        developer.log(
          '   └─ Bus: ${step.busRoute}, StopName: ${step.stopName}',
        );
      }
    }
    developer.log('🚶 ==========================================');

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

      developer.log(
        '🗺️ [SIMPLE] Paso $i: step.type=${step.type} ← leg.type=${leg.type}',
      );

      // Validar que los tipos coincidan
      if ((step.type == 'walk' && leg.type != 'walk') ||
          (step.type == 'bus' && leg.type != 'bus')) {
        developer.log('   ⚠️ [SIMPLE] ADVERTENCIA: Tipos no coinciden!');
      }

      // Usar geometría del backend directamente
      if (leg.geometry != null && leg.geometry!.isNotEmpty) {
        geometries[i] = List.from(leg.geometry!);
        developer.log(
          '   ✅ [SIMPLE] Geometría: ${leg.geometry!.length} puntos',
        );

        if (leg.departStop != null || leg.arriveStop != null) {
          developer.log(
            '   📍 [SIMPLE] ${leg.departStop?.name ?? "Inicio"} → ${leg.arriveStop?.name ?? "Destino"}',
          );
        }
      } else {
        // Fallback: línea recta entre origen y destino
        final start = leg.departStop?.location ?? origin;
        final end = leg.arriveStop?.location ?? step.location;

        if (end != null) {
          geometries[i] = [start, end];
          developer.log('   ⚠️ [SIMPLE] Fallback línea recta (2 puntos)');
        } else {
          developer.log('   ❌ [SIMPLE] Sin geometría disponible');
        }
      }
    }

    developer.log(
      '🗺️ [SIMPLE] Geometrías creadas: ${geometries.keys.toList()}',
    );
    return geometries;
  }

  /// Anuncia el inicio de navegación por voz
  void _announceNavigationStart(String destination, RedBusItinerary itinerary) {
    developer.log('🔊 [TTS] _announceNavigationStart llamado');
    developer.log(
      '🔊 [TTS] _activeNavigation != null? ${_activeNavigation != null}',
    );

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
      developer.log('🔊 [TTS] currentStep.type = ${step.type}');
      developer.log('🔊 [TTS] currentStep.stopName = ${step.stopName}');
      developer.log('🔊 [TTS] currentStep.instruction = ${step.instruction}');

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

        developer.log(
          '🔊 [TTS] firstStepInstruction creado: $firstStepInstruction',
        );
      } else {
        developer.log(
          '🔊 [TTS] NO se creó firstStepInstruction (type=${step.type}, stopName=${step.stopName})',
        );
      }
    } else {
      developer.log('🔊 [TTS] currentStep es NULL');
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

    developer.log('🔊 [TTS] Mensaje completo a anunciar:');
    developer.log('🔊 [TTS] ===========================');
    developer.log(message);
    developer.log('🔊 [TTS] ===========================');

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
      developer.log(
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
          developer.log(
            '🗺️ Distancia real restante (GraphHopper): ${distanceToTarget.toStringAsFixed(1)}m',
          );
        } else {
          // Fallback: línea recta
          distanceToTarget = _distance.as(
            LengthUnit.Meter,
            userLocation,
            currentStep.location!,
          );
          developer.log(
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
        developer.log(
          '📍 Distancia línea recta: ${distanceToTarget.toStringAsFixed(1)}m',
        );
      }

      developer.log(
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

      developer.log(
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
            developer.log('🚌 Usuario esperando el bus en el paradero');
          }
          // Si está moviéndose rápido, asumimos que subió al bus
          else if (position.speed > 2.0) {
            developer.log(
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

    // NUEVO: Anunciar instrucciones de calle para usuarios no videntes
    if (step.type == 'walk' && step.streetInstructions != null && step.streetInstructions!.isNotEmpty) {
      _announceStreetInstructionsIfNeeded(step, distanceMeters);
      return; // Las instrucciones de calle reemplazan los anuncios genéricos
    }

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
      developer.log('📢 [PROGRESO] $message');
      TtsService.instance.speak(message);
      _lastProgressAnnouncement = now;
      _lastAnnouncedDistance = distanceMeters;
    }
  }

  // Track para instrucciones de calle ya anunciadas
  int _lastAnnouncedStreetInstructionIndex = -1;

  /// Anuncia instrucciones de calle paso a paso basado en distancia recorrida
  void _announceStreetInstructionsIfNeeded(NavigationStep step, double distanceRemaining) {
    if (step.streetInstructions == null || step.streetInstructions!.isEmpty) return;
    if (step.realDistanceMeters == null) return;

    final totalDistance = step.realDistanceMeters!;
    final distanceWalked = totalDistance - distanceRemaining;
    final progressPercent = (distanceWalked / totalDistance).clamp(0.0, 1.0);

    // Calcular qué instrucción debería anunciar basado en el progreso
    final totalInstructions = step.streetInstructions!.length;
    final currentInstructionIndex = (progressPercent * totalInstructions).floor();
    final safeIndex = currentInstructionIndex.clamp(0, totalInstructions - 1);

    // Si ya anunciamos esta instrucción, no repetir
    if (safeIndex <= _lastAnnouncedStreetInstructionIndex) return;

    // Anunciar la nueva instrucción
    final instruction = step.streetInstructions![safeIndex];
    developer.log('🧭 [CALLE] Instrucción $safeIndex/${totalInstructions-1}: $instruction');
    developer.log('   └─ Progreso: ${(progressPercent * 100).toInt()}% ($distanceWalked/${totalDistance}m)');

    TtsService.instance.speak(instruction);
    _lastAnnouncedStreetInstructionIndex = safeIndex;
  }

  /// Maneja llegada a un paso
  void _handleStepArrival(NavigationStep step) {
    developer.log('✅ Llegada al paso: ${step.type}');

    // Evitar anuncios duplicados para el mismo paso
    if (_lastArrivalAnnouncedStepIndex == _activeNavigation?.currentStepIndex) {
      return;
    }

    String announcement = '';

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
  //     developer.log('⚠️ [BUS_DETECTION] Error detectando buses cercanos: $e');
  //   }
  //   */
  // }

  /// Verifica progreso a través de paradas de bus durante viaje en bus
  /// Anuncia cada parada cuando el usuario pasa cerca
  void _checkBusStopsProgress(NavigationStep step, LatLng userLocation) {
    // Usar paradas almacenadas directamente en el NavigationStep
    final busStops = step.busStops;

    if (busStops == null || busStops.isEmpty) {
      developer.log(
        '⚠️ [BUS_STOPS] No hay paradas disponibles en el paso actual',
      );
      return;
    }

    developer.log(
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

      developer.log(
        '🚌 [STOP $i] ${stop['name']}: ${distanceToStop.toStringAsFixed(0)}m',
      );

      // Si está cerca de esta parada (50m) y no se ha anunciado
      final stopId = '${stop['name']}_$i';
      if (distanceToStop <= 50.0 && !_announcedStops.contains(stopId)) {
        developer.log(
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
        developer.log(
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

    developer.log('🔔 [TTS] $announcement');
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
    developer.log('🛑 Navegación detenida');
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
      developer.log('🗺️ [GEOMETRY] activeNavigation o lastPosition es null');
      return [];
    }

    final currentPos = LatLng(
      _lastPosition!.latitude,
      _lastPosition!.longitude,
    );

    final geometry = _activeNavigation!.getCurrentStepGeometry(currentPos);
    developer.log(
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
      developer.log('⚠️ No hay navegación activa');
      return;
    }

    final currentIndex = _activeNavigation!.currentStepIndex;
    if (currentIndex + 1 >= _activeNavigation!.steps.length) {
      developer.log('⚠️ Ya estás en el último paso de navegación');
      return;
    }

    _activeNavigation!.currentStepIndex++;
    final newStep = _activeNavigation!.currentStep;

    // Resetear índice de instrucciones de calle al cambiar de paso
    _lastAnnouncedStreetInstructionIndex = -1;

    developer.log(
      '📍 [STEP] Avanzando paso: $currentIndex → ${_activeNavigation!.currentStepIndex}',
    );
    developer.log(
      '📍 [STEP] Nuevo paso: ${newStep?.type} - ${newStep?.instruction}',
    );

    // Notificar cambio de paso
    if (newStep != null && onStepChanged != null) {
      onStepChanged!(newStep);
    }
  }

  /// TEST: Simula una posición GPS para testing
  /// Útil para probar la navegación sin caminar físicamente
  void simulatePosition(Position position) {
    developer.log(
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

    developer.log('🎤 [VOICE] Comando recibido: "$lowerCommand"');

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

    developer.log('⚠️ [VOICE] Comando no reconocido');
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
    developer.log('🚌 [VOICE] Procesando comando: Cuando llega la micro');

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
      developer.log('🚌 [VOICE] Buscando paradero cercano a posición GPS...');

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
        developer.log('❌ [VOICE] Error buscando paradero cercano: $e');
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
    developer.log('📍 [VOICE] Procesando comando: Dónde estoy');

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
    developer.log('⏱️ [VOICE] Procesando comando: Cuánto falta');

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
    developer.log('🔄 [VOICE] Procesando comando: Repetir instrucción');

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
