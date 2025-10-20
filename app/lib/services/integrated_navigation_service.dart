import 'dart:developer' as developer;
// ============================================================================
// INTEGRATED NAVIGATION SERVICE
// ============================================================================
// Combina Moovit scraping + GTFS data para navegación completa
// Detecta llegada a paraderos y guía al usuario en tiempo real
// ============================================================================

import 'dart:async';
import 'dart:math' as math;
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'red_bus_service.dart';
import 'tts_service.dart';
import 'bus_arrivals_service.dart';

class NavigationStep {
  final String type; // 'walk', 'wait_bus', 'ride_bus', 'transfer', 'arrival'
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
      case 'wait_bus':
        return 'Esperando el bus ${step.busRoute} en ${step.stopName}';
      case 'ride_bus':
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

      // Si es paso de walk o ride_bus, recortar geometría desde el punto más cercano al usuario
      if ((step.type == 'walk' || step.type == 'ride_bus') &&
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

    developer.log('⚠️ No hay geometría pre-calculada para paso $currentStepIndex');

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

  final RedBusService _redBusService = RedBusService.instance;
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

  // Control de paradas visitadas durante ride_bus
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
    developer.log('🚀 Iniciando navegación integrada a $destinationName');

    // Inicializar posición actual
    try {
      _lastPosition = await Geolocator.getCurrentPosition();
    } catch (e) {
      developer.log('⚠️ No se pudo obtener posición actual: $e');
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
      developer.log('♻️ Usando itinerario ya obtenido (evita llamada duplicada)');
      itinerary = existingItinerary;
    } else {
      developer.log('🔄 Solicitando nuevo itinerario al backend...');
      final routeOptions = await _redBusService.getRouteOptions(
        originLat: originLat,
        originLon: originLon,
        destLat: destLat,
        destLon: destLon,
      );

      if (routeOptions.firstOption == null) {
        throw Exception('No se encontraron rutas disponibles');
      }

      itinerary = routeOptions.firstOption!;
    }

    developer.log('📋 Itinerario obtenido: ${itinerary.summary}');
    developer.log('🚌 Buses Red recomendados: ${itinerary.redBusRoutes.join(", ")}');

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

    developer.log('🚶 Construyendo pasos de navegación (1:1 con legs del backend)...');
    developer.log('🚶 Legs del itinerario: ${itinerary.legs.length}');

    // Mapeo DIRECTO 1:1: cada leg del backend = 1 paso en el frontend
    for (var i = 0; i < itinerary.legs.length; i++) {
      final leg = itinerary.legs[i];

      if (leg.type == 'walk') {
        // Paso de caminata
        final walkTo = leg.arriveStop?.location;

        if (walkTo != null) {
          developer.log('🚶 Paso WALK hasta ${leg.arriveStop?.name}');

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
            ),
          );
        }
      } else if (leg.type == 'bus' && leg.isRedBus) {
        // Paso de bus: combina espera + viaje en UN SOLO paso
        developer.log(
          '🚌 Paso BUS ${leg.routeNumber}: ${leg.departStop?.name} → ${leg.arriveStop?.name}',
        );

        final stopInfo = await _getStopInfoFromGTFS(leg.departStop?.name ?? '');
        final busOptions = await _getBusesAtStop(stopInfo?['stop_id'] ?? '');

        steps.add(
          NavigationStep(
            type: 'bus',
            instruction:
                'Toma el bus Red ${leg.routeNumber} en ${leg.departStop?.name} hasta ${leg.arriveStop?.name}',
            location: leg.arriveStop?.location,
            stopId: stopInfo?['stop_id'],
            stopName: leg.arriveStop?.name,
            busRoute: leg.routeNumber,
            busOptions: busOptions,
            estimatedDuration:
                leg.durationMinutes + 5, // Viaje + espera estimada
            totalStops: leg.stopCount,
            realDistanceMeters: leg.distanceKm * 1000,
            realDurationSeconds: leg.durationMinutes * 60,
          ),
        );
      }
    }

    // Log de todos los pasos generados
    developer.log('🚶 ===== PASOS DE NAVEGACIÓN GENERADOS =====');
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      developer.log('🚶 Paso $i: ${step.type} - ${step.instruction}');
      if (step.type == 'bus') {
        developer.log('   └─ Bus: ${step.busRoute}, StopName: ${step.stopName}');
      }
    }
    developer.log('🚶 ==========================================');

    return steps;
  }

  /// Obtiene información del paradero desde GTFS por nombre
  Future<Map<String, dynamic>?> _getStopInfoFromGTFS(String stopName) async {
    // TODO: Implementar cuando ApiClient tenga método get()
    // final response = await ApiClient.instance.get('/api/stops/search?name=$stopName');
    return null;
  }

  /// Obtiene lista de buses que pasan por un paradero
  Future<List<String>> _getBusesAtStop(String stopId) async {
    // TODO: Implementar cuando ApiClient tenga método get()
    // final response = await ApiClient.instance.get('/api/stops/$stopId/routes');
    return [];
  }

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
        developer.log('   ✅ [SIMPLE] Geometría: ${leg.geometry!.length} puntos');

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

    developer.log('🗺️ [SIMPLE] Geometrías creadas: ${geometries.keys.toList()}');
    return geometries;
  }

  /// Anuncia el inicio de navegación por voz
  void _announceNavigationStart(String destination, RedBusItinerary itinerary) {
    developer.log('🔊 [TTS] _announceNavigationStart llamado');
    developer.log('🔊 [TTS] _activeNavigation != null? ${_activeNavigation != null}');

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

        developer.log('🔊 [TTS] firstStepInstruction creado: $firstStepInstruction');
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
Duración total estimada: ${itinerary.totalDurationMinutes} minutos. 
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

    // Si está esperando un bus, detectar buses cercanos
    if (currentStep.type == 'wait_bus') {
      _detectNearbyBuses(currentStep, userLocation);
    }

    // Si está en el bus (ride_bus), detectar y anunciar paradas intermedias
    if (currentStep.type == 'ride_bus') {
      _checkBusStopsProgress(currentStep, userLocation);
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
      case 'wait_bus':
        message = 'Has llegado al paradero. Espera el bus ${step.busRoute}';
        break;
      case 'ride_bus':
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
    } else if (step.type == 'ride_bus') {
      final km = (distanceMeters / 1000).toStringAsFixed(1);
      final simplifiedStopName = _simplifyStopNameForTTS(
        step.stopName,
        isDestination: true,
      );
      message =
          'Viajando en bus ${step.busRoute}. Faltan $km kilómetros hasta $simplifiedStopName';
    } else if (step.type == 'wait_bus') {
      final simplifiedStopName = _simplifyStopNameForTTS(
        step.stopName,
        isDestination: true,
      );
      message = 'Esperando el bus ${step.busRoute} en $simplifiedStopName';
    }

    if (message.isNotEmpty) {
      developer.log('📢 [PROGRESO] $message');
      TtsService.instance.speak(message);
      _lastProgressAnnouncement = now;
      _lastAnnouncedDistance = distanceMeters;
    }
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

      case 'wait_bus':
        announcement =
            'Estás en el paradero correcto. Espera el bus Red ${step.busRoute}';
        break;

      case 'ride_bus':
        final simplifiedStopName = _simplifyStopNameForTTS(
          step.stopName,
          isDestination: true,
        );
        announcement = 'Bájate aquí. Has llegado a $simplifiedStopName';
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

    // Si el siguiente paso es ride_bus, resetear control de paradas
    final nextStep = _activeNavigation!.currentStep;
    if (nextStep?.type == 'ride_bus') {
      _announcedStops.clear();
      _currentBusStopIndex = 0;
      developer.log('🚌 [BUS_STOPS] Iniciando nuevo viaje en bus - resetear paradas');
    }

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

  /// Detecta buses cercanos usando datos de tiempo real
  Future<void> _detectNearbyBuses(
    NavigationStep step,
    LatLng userLocation,
  ) async {
    if (step.stopId == null) return;

    // TODO: Implementar cuando ApiClient tenga método getBusArrivals()
    /*
    try {
      // Consultar API de tiempo real para obtener llegadas próximas
      final arrivals = await ApiClient.instance.getBusArrivals(step.stopId!);
      
      if (arrivals.isNotEmpty) {
        final nextBus = arrivals.first;
        final routeShortName = nextBus['route_short_name'] ?? '';
        final etaMinutes = nextBus['eta_minutes'] ?? 0;
        
        if (etaMinutes <= 5) {
          TtsService.instance.speak(
            'El bus $routeShortName llegará en $etaMinutes minutos.',
          );
        }
      }
    } catch (e) {
      developer.log('⚠️ [BUS_DETECTION] Error detectando buses cercanos: $e');
    }
    */
  }

  /// Verifica progreso a través de paradas de bus durante ride_bus
  /// Anuncia cada parada cuando el usuario pasa cerca
  void _checkBusStopsProgress(NavigationStep step, LatLng userLocation) {
    // Obtener lista de paradas del leg actual
    final currentLegIndex = _activeNavigation?.currentStepIndex;
    if (currentLegIndex == null) {
      developer.log('⚠️ [BUS_STOPS] currentLegIndex es null');
      return;
    }

    developer.log('🚌 [BUS_STOPS] currentLegIndex: $currentLegIndex');
    developer.log(
      '🚌 [BUS_STOPS] Total legs en itinerario: ${_activeNavigation!.itinerary.legs.length}',
    );

    // Buscar el leg de bus correspondiente en el itinerario
    final busLegs = _activeNavigation!.itinerary.legs
        .where((leg) => leg.type == 'bus')
        .toList();

    if (busLegs.isEmpty) {
      developer.log('⚠️ [BUS_STOPS] No se encontró ningún leg de bus en el itinerario');
      return;
    }

    developer.log('🚌 [BUS_STOPS] Encontrados ${busLegs.length} legs de bus');

    // Usar el primer leg de bus (normalmente solo hay uno)
    final busLeg = busLegs.first;
    final stops = busLeg.stops;

    if (stops == null || stops.isEmpty) {
      developer.log('⚠️ [BUS_STOPS] No hay paradas disponibles en el leg de bus');
      developer.log('⚠️ [BUS_STOPS] busLeg.type: ${busLeg.type}');
      developer.log('⚠️ [BUS_STOPS] busLeg.routeNumber: ${busLeg.routeNumber}');
      return;
    }

    developer.log(
      '🚌 [BUS_STOPS] Verificando progreso: ${stops.length} paradas totales, índice actual: $_currentBusStopIndex',
    );

    // Verificar cercanía a cada parada (en orden)
    for (int i = _currentBusStopIndex; i < stops.length; i++) {
      final stop = stops[i];
      final stopLocation = stop.location;

      final distanceToStop = _distance.as(
        LengthUnit.Meter,
        userLocation,
        stopLocation,
      );

      developer.log('🚌 [STOP $i] ${stop.name}: ${distanceToStop.toStringAsFixed(0)}m');

      // Si está cerca de esta parada (50m) y no se ha anunciado
      final stopId = '${stop.name}_${stop.sequence}';
      if (distanceToStop <= 50.0 && !_announcedStops.contains(stopId)) {
        developer.log(
          '✅ [BUS_STOPS] Parada detectada a ${distanceToStop.toStringAsFixed(0)}m - Anunciando...',
        );
        _announceCurrentBusStop(stop, i + 1, stops.length);
        _announcedStops.add(stopId);
        _currentBusStopIndex = i + 1; // Avanzar al siguiente índice
        break; // Solo anunciar una parada a la vez
      }
    }
  }

  /// Anuncia la parada actual del bus
  void _announceCurrentBusStop(
    RedBusStop stop,
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

    String announcement;
    if (isLastStop) {
      final stopCode = stop.code != null && stop.code!.isNotEmpty
          ? 'código ${stop.code}, '
          : '';
      announcement =
          'Próxima parada: $stopCode${stop.name}. Es tu parada de bajada. Prepárate para descender.';
    } else if (isFirstStop) {
      final stopCode = stop.code != null && stop.code!.isNotEmpty
          ? 'código ${stop.code}, '
          : '';
      announcement =
          'Primera parada: $stopCode${stop.name}. Ahora estás en el bus.';
    } else {
      final stopCode = stop.code != null && stop.code!.isNotEmpty
          ? 'código ${stop.code}, '
          : '';
      announcement = 'Parada $stopNumber de $totalStops: $stopCode${stop.name}';
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

    developer.log(
      '📍 [STEP] Avanzando paso: $currentIndex → ${_activeNavigation!.currentStepIndex}',
    );
    developer.log('📍 [STEP] Nuevo paso: ${newStep?.type} - ${newStep?.instruction}');

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

    // Si hay navegación activa y estamos esperando el bus
    if (_activeNavigation != null) {
      final currentStep = _activeNavigation!.currentStep;

      if (currentStep?.type == 'wait_bus' && currentStep?.stopId != null) {
        developer.log(
          '🚌 [VOICE] En paradero ${currentStep!.stopId}, consultando llegadas...',
        );

        try {
          final arrivals = await BusArrivalsService.instance.getBusArrivals(
            currentStep.stopId!,
          );

          if (arrivals != null && arrivals.arrivals.isNotEmpty) {
            TtsService.instance.speak(arrivals.arrivalsSummary, urgent: true);
            return true;
          } else {
            TtsService.instance.speak(
              'No hay información de buses disponible para este paradero',
              urgent: true,
            );
            return true;
          }
        } catch (e) {
          developer.log('❌ [VOICE] Error obteniendo llegadas: $e');
          TtsService.instance.speak(
            'No pude obtener información de buses en este momento',
            urgent: true,
          );
          return true;
        }
      }
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
