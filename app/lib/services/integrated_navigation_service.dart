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
import 'api_client.dart';
import 'tts_service.dart';

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
  });

  NavigationStep copyWith({bool? isCompleted, int? currentStop}) {
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

  ActiveNavigation({
    required this.destination,
    required this.steps,
    required this.routeGeometry,
    required this.stepGeometries,
    required this.itinerary,
    required this.estimatedDuration,
    this.currentStepIndex = 0,
  });

  NavigationStep? get currentStep =>
      currentStepIndex < steps.length ? steps[currentStepIndex] : null;

  // Geometría solo del paso ACTUAL usando el mapa de geometrías
  List<LatLng> getCurrentStepGeometry(LatLng currentPosition) {
    final step = currentStep;
    if (step == null) {
      print('🔍 getCurrentStepGeometry: step es null');
      return [];
    }

    print('🔍 getCurrentStepGeometry: Paso actual = ${step.type} (índice $currentStepIndex)');
    print('🔍 Geometrías disponibles: ${stepGeometries.keys.toList()}');

    // Si tenemos geometría pre-calculada para este paso, usarla
    if (stepGeometries.containsKey(currentStepIndex)) {
      final geometry = stepGeometries[currentStepIndex]!;
      print('🔍 Geometría encontrada para paso $currentStepIndex: ${geometry.length} puntos');

      // Si es paso de walk, actualizar el punto inicial con la posición actual
      if (step.type == 'walk' && geometry.length >= 2) {
        print('🔍 Paso WALK: Actualizando geometría con posición actual');
        return [
          currentPosition, // Posición actual actualizada
          ...geometry.sublist(1), // Resto de la geometría
        ];
      }

      print('🔍 Retornando geometría pre-calculada');
      return geometry;
    }

    print('⚠️ No hay geometría pre-calculada para paso $currentStepIndex');

    // Fallback: generar geometría básica
    if (step.location != null) {
      if (step.type == 'walk') {
        print('🔍 Fallback: Creando geometría básica para WALK');
        return [currentPosition, step.location!];
      }
    }

    print('⚠️ Sin geometría para este paso');
    return []; // Sin geometría
  }

  bool get isComplete => currentStepIndex >= steps.length;

  void advanceToNextStep() {
    if (!isComplete) {
      currentStepIndex++;
    }
  }
}

class IntegratedNavigationService {
  static final IntegratedNavigationService instance =
      IntegratedNavigationService._();
  IntegratedNavigationService._();

  final RedBusService _redBusService = RedBusService.instance;
  final ApiClient _apiClient = ApiClient();
  final Distance _distance = const Distance();

  ActiveNavigation? _activeNavigation;
  StreamSubscription<Position>? _positionStream;
  Position? _lastPosition; // Última posición GPS recibida

  // Callbacks
  Function(NavigationStep)? onStepChanged;
  Function(String)? onArrivalAtStop;
  Function()? onDestinationReached;
  Function(String)? onBusDetected;

  // Configuración de umbrales adaptativos
  static const double ARRIVAL_THRESHOLD_METERS =
      30.0; // 30m para considerar "llegada" (más estricto)
  static const double PROXIMITY_ALERT_METERS =
      150.0; // 150m para alertar proximidad
  static const double GPS_ACCURACY_THRESHOLD =
      20.0; // Precisión GPS mínima aceptable (metros)
  static const double MAX_ARRIVAL_THRESHOLD =
      50.0; // Umbral máximo incluso con GPS impreciso

  // Histórico de posiciones para suavizar detección
  final List<Position> _positionHistory = [];
  static const int MAX_POSITION_HISTORY = 5;

  // Control de anuncios duplicados
  int? _lastProximityAnnouncedStepIndex;
  int? _lastArrivalAnnouncedStepIndex;

  /// Inicia navegación completa desde ubicación actual a destino
  Future<ActiveNavigation> startNavigation({
    required double originLat,
    required double originLon,
    required double destLat,
    required double destLon,
    required String destinationName,
  }) async {
    print('🚀 Iniciando navegación integrada a $destinationName');

    // Inicializar posición actual
    try {
      _lastPosition = await Geolocator.getCurrentPosition();
    } catch (e) {
      print('⚠️ No se pudo obtener posición actual: $e');
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

    // 1. Obtener itinerario de Moovit
    final itinerary = await _redBusService.getRedBusItinerary(
      originLat: originLat,
      originLon: originLon,
      destLat: destLat,
      destLon: destLon,
    );

    print('📋 Itinerario obtenido: ${itinerary.summary}');
    print('🚌 Buses Red recomendados: ${itinerary.redBusRoutes.join(", ")}');

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

    // 7. Reiniciar control de anuncios
    _lastProximityAnnouncedStepIndex = null;
    _lastArrivalAnnouncedStepIndex = null;

    // 8. Anunciar inicio de navegación
    _announceNavigationStart(destinationName, itinerary);

    // 9. Iniciar seguimiento GPS
    _startLocationTracking();

    return _activeNavigation!;
  }

  /// Construye pasos de navegación detallados desde el itinerario
  Future<List<NavigationStep>> _buildNavigationSteps(
    RedBusItinerary itinerary,
    double currentLat,
    double currentLon,
  ) async {
    final steps = <NavigationStep>[];

    // SIEMPRE agregar paso inicial de caminata al primer paradero
    // Esto es CRÍTICO para usuarios no videntes
    final firstBusLeg = itinerary.legs.firstWhere(
      (leg) => leg.type == 'bus',
      orElse: () => itinerary.legs.first,
    );

    if (firstBusLeg.type == 'bus' && firstBusLeg.departStop != null) {
      // Calcular distancia desde posición actual al paradero de partida
      final stopLat = firstBusLeg.departStop!.location.latitude;
      final stopLon = firstBusLeg.departStop!.location.longitude;
      final distanceMeters = _calculateDistance(
        currentLat,
        currentLon,
        stopLat,
        stopLon,
      );

      // SIEMPRE agregar paso de caminata al inicio
      // No confiar solo en GPS - el usuario debe confirmar llegada físicamente
      final walkTimeMinutes = math.max(
        1,
        (distanceMeters / 80).ceil(),
      ); // ~80m/min, mínimo 1 minuto

      steps.add(
        NavigationStep(
          type: 'walk',
          instruction:
              'Camina hacia el paradero ${firstBusLeg.departStop!.name}',
          location: firstBusLeg.departStop!.location,
          stopId: null,
          stopName: firstBusLeg.departStop!.name,
          estimatedDuration: walkTimeMinutes,
        ),
      );
    }

    // Procesar los legs del itinerario
    for (var i = 0; i < itinerary.legs.length; i++) {
      final leg = itinerary.legs[i];

      if (leg.type == 'walk') {
        // Paso de caminata (solo si no es el primero que ya agregamos)
        if (i > 0 || steps.isEmpty) {
          steps.add(
            NavigationStep(
              type: 'walk',
              instruction: leg.instruction.isNotEmpty
                  ? leg.instruction
                  : 'Camina ${(leg.distanceKm * 1000).toInt()} metros',
              location: leg.arriveStop?.location,
              stopName: leg.arriveStop?.name,
              estimatedDuration: leg.durationMinutes,
            ),
          );
        }
      } else if (leg.type == 'bus' && leg.isRedBus) {
        // Esperar el bus
        final stopInfo = await _getStopInfoFromGTFS(leg.departStop?.name ?? '');
        final busOptions = await _getBusesAtStop(stopInfo?['stop_id'] ?? '');

        steps.add(
          NavigationStep(
            type: 'wait_bus',
            instruction:
                'Espera el bus Red ${leg.routeNumber} en ${leg.departStop?.name ?? 'este paradero'}',
            location: leg.departStop?.location,
            stopId: stopInfo?['stop_id'],
            stopName: leg.departStop?.name,
            busRoute: leg.routeNumber,
            busOptions: busOptions,
            estimatedDuration: 5, // Estimado de espera
          ),
        );

        // Viajar en el bus
        steps.add(
          NavigationStep(
            type: 'ride_bus',
            instruction:
                'Viaja en el bus Red ${leg.routeNumber} hasta ${leg.arriveStop?.name ?? 'tu parada de destino'}',
            location: leg.arriveStop?.location,
            stopId: await _getStopId(leg.arriveStop?.name ?? ''),
            stopName: leg.arriveStop?.name,
            busRoute: leg.routeNumber,
            estimatedDuration: leg.durationMinutes,
            totalStops: leg.stopCount, // Número de paradas desde el backend
          ),
        );
      }
    }

    // Paso final: llegada
    steps.add(
      NavigationStep(
        type: 'arrival',
        instruction: 'Has llegado a tu destino: ${itinerary.destination}',
        location: itinerary.destination,
        estimatedDuration: 0,
      ),
    );

    return steps;
  }

  /// Calcula distancia en metros entre dos puntos geográficos (fórmula Haversine)
  double _calculateDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadius = 6371000; // Radio de la Tierra en metros
    final dLat = _degreesToRadians(lat2 - lat1);
    final dLon = _degreesToRadians(lon2 - lon1);

    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degreesToRadians(lat1)) *
            math.cos(_degreesToRadians(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);

    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadius * c;
  }

  double _degreesToRadians(double degrees) {
    return degrees * math.pi / 180;
  }

  /// Encuentra el paradero más cercano usando GTFS
  Future<Map<String, dynamic>?> _findNearestStop(double lat, double lon) async {
    try {
      final stops = await _apiClient.getNearbyStops(
        lat: lat,
        lon: lon,
        radius: 500,
        limit: 1,
      );

      if (stops.isNotEmpty) {
        return stops.first as Map<String, dynamic>;
      }
    } catch (e) {
      print('Error buscando paradero cercano: $e');
    }
    return null;
  }

  /// Obtiene información del paradero desde GTFS por nombre
  Future<Map<String, dynamic>?> _getStopInfoFromGTFS(String stopName) async {
    // En producción, esto debería hacer una búsqueda en el backend
    // Por ahora, retornamos datos simulados
    return {
      'stop_id': 'PJ178',
      'stop_name': stopName,
      'stop_lat': -33.437,
      'stop_lon': -70.650,
    };
  }

  /// Obtiene lista de buses que pasan por un paradero
  Future<List<String>> _getBusesAtStop(String stopId) async {
    // Consultar GTFS para obtener rutas que pasan por este paradero
    // Por ahora retornamos los de ejemplo
    return ['426', '406', '422'];
  }

  /// Obtiene el ID del paradero por nombre
  Future<String?> _getStopId(String stopName) async {
    final stopInfo = await _getStopInfoFromGTFS(stopName);
    return stopInfo?['stop_id'];
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
  Future<Map<int, List<LatLng>>> _buildStepGeometries(
    List<NavigationStep> steps,
    RedBusItinerary itinerary,
    LatLng origin,
  ) async {
    final geometries = <int, List<LatLng>>{};

    for (int i = 0; i < steps.length; i++) {
      final step = steps[i];
      final stepGeometry = <LatLng>[];

      switch (step.type) {
        case 'walk':
          // Geometría de caminata: línea recta desde origen hasta paradero
          if (step.location != null) {
            stepGeometry.add(origin); // Posición inicial
            stepGeometry.add(step.location!); // Paradero destino
          }
          break;

        case 'ride_bus':
          // Geometría del bus: obtener del leg correspondiente del itinerario
          for (var leg in itinerary.legs) {
            if (leg.type == 'bus' &&
                leg.routeNumber == step.busRoute &&
                leg.geometry != null &&
                leg.geometry!.isNotEmpty) {
              stepGeometry.addAll(leg.geometry!);
              break;
            }
          }

          // Si no hay geometría del leg, crear línea entre paraderos
          if (stepGeometry.isEmpty && step.location != null) {
            // Buscar el paradero de inicio del bus
            final prevStep = i > 0 ? steps[i - 1] : null;
            if (prevStep?.location != null) {
              stepGeometry.add(prevStep!.location!);
              stepGeometry.add(step.location!);
            }
          }
          break;

        case 'wait_bus':
          // No hay geometría para esperar en el paradero
          break;
      }

      if (stepGeometry.isNotEmpty) {
        geometries[i] = stepGeometry;
      }
    }

    return geometries;
  }

  /// Anuncia el inicio de navegación por voz
  void _announceNavigationStart(String destination, RedBusItinerary itinerary) {
    // Construir mensaje detallado del viaje
    final busLegs = itinerary.legs.where((leg) => leg.type == 'bus').toList();

    String busInfo = '';
    if (busLegs.isNotEmpty) {
      final firstBusLeg = busLegs.first;
      busInfo = 'Tomarás el bus ${firstBusLeg.routeNumber}';

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
      // Los otros pasos se anunciarán cuando se llegue a ellos
      if (step.type == 'walk' && step.stopName != null) {
        final distance = (step.estimatedDuration * 80).toInt();
        firstStepInstruction =
            'Primer paso: Dirígete caminando hacia el paradero ${step.stopName}. '
            'Distancia aproximada: $distance metros. '
            'Tiempo estimado: ${step.estimatedDuration} minuto';
        if (step.estimatedDuration > 1) firstStepInstruction += 's';
        firstStepInstruction += '. ';
      }
      // Si el primer paso NO es walk (caso raro), no anunciar nada extra
    }

    final message =
        '''
Ruta calculada hacia $destination. 
$busInfo
Duración total estimada: ${itinerary.totalDurationMinutes} minutos. 
$firstStepInstruction
Te iré guiando paso a paso.
''';

    // Una sola llamada TTS para todo el anuncio inicial
    TtsService.instance.speak(message, urgent: true);
  }

  /// Anuncia el paso actual con detalles
  void _announceCurrentStep(NavigationStep step) {
    String announcement = '';

    switch (step.type) {
      case 'walk':
        if (step.stopName != null) {
          final distance = (step.estimatedDuration * 80)
              .toInt(); // ~80m/min velocidad caminata
          announcement =
              'Dirígete caminando hacia el paradero ${step.stopName}. '
              'Distancia aproximada: $distance metros. '
              'Tiempo estimado: ${step.estimatedDuration} minuto';
          if (step.estimatedDuration > 1) announcement += 's';
        } else {
          announcement = step.instruction;
        }
        break;

      case 'wait_bus':
        announcement =
            'Has llegado al paradero ${step.stopName ?? ""}. '
            'Espera el bus ${step.busRoute}. ';

        if (step.busOptions != null && step.busOptions!.length > 1) {
          announcement +=
              'Otros buses que pasan por aquí: ${step.busOptions!.join(", ")}. ';
        }

        announcement += 'Te avisaré cuando llegue tu bus.';
        break;

      case 'ride_bus':
        announcement =
            'Sube al bus ${step.busRoute}. '
            'Debes bajar en ${step.stopName ?? "tu parada de destino"}. ';

        if (step.totalStops != null && step.totalStops! > 0) {
          announcement += 'Son ${step.totalStops} paradas. ';
        }

        announcement +=
            'Tiempo estimado: ${step.estimatedDuration} minutos. '
            'Te avisaré cuando estés cerca de tu parada.';
        break;

      case 'arrival':
        announcement =
            'Has llegado a tu destino: ${step.stopName ?? ""}. '
            'Navegación completada. ¡Buen viaje!';
        break;

      default:
        announcement = step.instruction;
    }

    TtsService.instance.announceNavigation(announcement, urgent: true);
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

    // Filtrar posiciones con baja precisión GPS
    if (position.accuracy > GPS_ACCURACY_THRESHOLD) {
      print(
        '⚠️ GPS con baja precisión: ${position.accuracy.toStringAsFixed(1)}m - Ignorando',
      );
      return;
    }

    // Agregar al histórico de posiciones
    _positionHistory.add(position);
    if (_positionHistory.length > MAX_POSITION_HISTORY) {
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
      final distanceToTarget = _distance.as(
        LengthUnit.Meter,
        userLocation,
        currentStep.location!,
      );

      print(
        '📍 Distancia al objetivo: ${distanceToTarget.toStringAsFixed(1)}m (GPS: ${position.accuracy.toStringAsFixed(1)}m)',
      );

      // Alerta de proximidad (solo si no se ha anunciado antes)
      if (distanceToTarget <= PROXIMITY_ALERT_METERS &&
          distanceToTarget > ARRIVAL_THRESHOLD_METERS) {
        _announceProximity(currentStep);
      }

      // Llegada al objetivo (ajustar threshold según precisión GPS, pero con límite máximo)
      final adjustedThreshold = math.min(
        ARRIVAL_THRESHOLD_METERS + (position.accuracy * 0.3),
        MAX_ARRIVAL_THRESHOLD,
      );

      print(
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

  /// Maneja llegada a un paso
  void _handleStepArrival(NavigationStep step) {
    print('✅ Llegada al paso: ${step.type}');

    // Evitar anuncios duplicados para el mismo paso
    if (_lastArrivalAnnouncedStepIndex == _activeNavigation?.currentStepIndex) {
      return;
    }

    String announcement = '';

    switch (step.type) {
      case 'walk':
        announcement = 'Has llegado al paradero ${step.stopName}. ';
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
        announcement = 'Bájate aquí. Has llegado a ${step.stopName}';
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
    onStepChanged?.call(_activeNavigation!.currentStep ?? step);

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

  /// Detecta buses cercanos (simulado - en producción usar GPS del bus)
  void _detectNearbyBuses(NavigationStep step, LatLng userLocation) {
    // En producción, esto consultaría la API de tiempo real de buses
    // Por ahora, simulamos la detección

    // Este método se llamaría cuando se detecte que un bus está llegando
    // usando datos de GPS de los buses o información de la API de Transantiago
  }

  /// Detiene la navegación activa
  void stopNavigation() {
    _positionStream?.cancel();
    _activeNavigation = null;
    print('🛑 Navegación detenida');
  }

  /// Obtiene el paso actual
  NavigationStep? get currentStep => _activeNavigation?.currentStep;

  /// Verifica si hay navegación activa
  bool get hasActiveNavigation => _activeNavigation != null;

  /// Obtiene la navegación activa
  ActiveNavigation? get activeNavigation => _activeNavigation;

  // Geometría del paso actual usando la última posición GPS
  List<LatLng> get currentStepGeometry {
    if (_activeNavigation == null || _lastPosition == null) return [];

    final currentPos = LatLng(
      _lastPosition!.latitude,
      _lastPosition!.longitude,
    );
    return _activeNavigation!.getCurrentStepGeometry(currentPos);
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
    if (_activeNavigation != null) {
      TtsService.instance.speak('Navegación cancelada');
      stopNavigation();
    }
  }
}
