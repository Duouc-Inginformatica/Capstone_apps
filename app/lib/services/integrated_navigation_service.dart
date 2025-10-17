// ============================================================================
// INTEGRATED NAVIGATION SERVICE
// ============================================================================
// Combina Moovit scraping + GTFS data para navegación completa
// Detecta llegada a paraderos y guía al usuario en tiempo real
// ============================================================================

import 'dart:async';
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
  });

  NavigationStep copyWith({bool? isCompleted}) {
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
    );
  }
}

class ActiveNavigation {
  final String destination;
  final List<NavigationStep> steps;
  final List<LatLng> routeGeometry;
  final RedBusItinerary itinerary;
  final int estimatedDuration; // Duración total estimada en minutos
  int currentStepIndex;
  
  ActiveNavigation({
    required this.destination,
    required this.steps,
    required this.routeGeometry,
    required this.itinerary,
    required this.estimatedDuration,
    this.currentStepIndex = 0,
  });

  NavigationStep? get currentStep =>
      currentStepIndex < steps.length ? steps[currentStepIndex] : null;

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
  
  // Callbacks
  Function(NavigationStep)? onStepChanged;
  Function(String)? onArrivalAtStop;
  Function()? onDestinationReached;
  Function(String)? onBusDetected;

  // Configuración de umbrales adaptativos
  static const double ARRIVAL_THRESHOLD_METERS = 50.0; // 50m para considerar "llegada"
  static const double PROXIMITY_ALERT_METERS = 100.0; // 100m para alertar proximidad
  static const double GPS_ACCURACY_THRESHOLD = 20.0; // Precisión GPS mínima aceptable (metros)
  
  // Histórico de posiciones para suavizar detección
  final List<Position> _positionHistory = [];
  static const int MAX_POSITION_HISTORY = 5;

  /// Inicia navegación completa desde ubicación actual a destino
  Future<ActiveNavigation> startNavigation({
    required double originLat,
    required double originLon,
    required double destLat,
    required double destLon,
    required String destinationName,
  }) async {
    print('🚀 Iniciando navegación integrada a $destinationName');

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

    // 4. Calcular duración total estimada
    final totalDuration = itinerary.legs.fold<int>(
      0, 
      (sum, leg) => sum + leg.durationMinutes,
    );

    // 5. Crear navegación activa
    _activeNavigation = ActiveNavigation(
      destination: destinationName,
      steps: steps,
      routeGeometry: geometry,
      itinerary: itinerary,
      estimatedDuration: totalDuration,
    );

    // 6. Anunciar inicio de navegación
    _announceNavigationStart(destinationName, itinerary);

    // 7. Iniciar seguimiento GPS
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

    for (var i = 0; i < itinerary.legs.length; i++) {
      final leg = itinerary.legs[i];

      if (leg.type == 'walk') {
        // Paso de caminata
        if (i == 0) {
          // Primera caminata hacia el paradero
          final stopInfo = await _findNearestStop(currentLat, currentLon);
          
          steps.add(NavigationStep(
            type: 'walk',
            instruction: 'Camina ${leg.distanceKm * 1000} metros hacia el paradero ${stopInfo?['stop_name'] ?? 'más cercano'}',
            location: leg.departStop?.location,
            stopId: stopInfo?['stop_id'],
            stopName: stopInfo?['stop_name'],
            estimatedDuration: leg.durationMinutes,
          ));
        } else {
          // Caminata final o entre paraderos
          steps.add(NavigationStep(
            type: 'walk',
            instruction: leg.instruction,
            estimatedDuration: leg.durationMinutes,
          ));
        }
      } else if (leg.type == 'bus' && leg.isRedBus) {
        // Esperar el bus
        final stopInfo = await _getStopInfoFromGTFS(leg.departStop?.name ?? '');
        final busOptions = await _getBusesAtStop(stopInfo?['stop_id'] ?? '');

        steps.add(NavigationStep(
          type: 'wait_bus',
          instruction: 'Espera el bus Red ${leg.routeNumber} en ${leg.departStop?.name ?? 'este paradero'}',
          location: leg.departStop?.location,
          stopId: stopInfo?['stop_id'],
          stopName: leg.departStop?.name,
          busRoute: leg.routeNumber,
          busOptions: busOptions,
          estimatedDuration: 5, // Estimado de espera
        ));

        // Viajar en el bus
        steps.add(NavigationStep(
          type: 'ride_bus',
          instruction: 'Viaja en el bus Red ${leg.routeNumber} hasta ${leg.arriveStop?.name ?? 'tu parada de destino'}',
          location: leg.arriveStop?.location,
          stopId: await _getStopId(leg.arriveStop?.name ?? ''),
          stopName: leg.arriveStop?.name,
          busRoute: leg.routeNumber,
          estimatedDuration: leg.durationMinutes,
        ));
      }
    }

    // Paso final: llegada
    steps.add(NavigationStep(
      type: 'arrival',
      instruction: 'Has llegado a tu destino: ${itinerary.destination}',
      location: itinerary.destination,
      estimatedDuration: 0,
    ));

    return steps;
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

  /// Anuncia el inicio de navegación por voz
  void _announceNavigationStart(String destination, RedBusItinerary itinerary) {
    final message = '''
Navegación iniciada hacia $destination. 
Duración estimada: ${itinerary.totalDurationMinutes} minutos.
Tomarás ${itinerary.redBusRoutes.length} bus${itinerary.redBusRoutes.length > 1 ? 'es' : ''}: ${itinerary.redBusRoutes.join(', ')}.
Primera instrucción: ${itinerary.legs.first.instruction}
''';

    TtsService.instance.speak(message);
  }

  /// Inicia seguimiento GPS en tiempo real
  void _startLocationTracking() {
    _positionStream?.cancel();

    _positionStream = Geolocator.getPositionStream(
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

    // Filtrar posiciones con baja precisión GPS
    if (position.accuracy > GPS_ACCURACY_THRESHOLD) {
      print('⚠️ GPS con baja precisión: ${position.accuracy.toStringAsFixed(1)}m - Ignorando');
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

    final userLocation = LatLng(smoothedPosition.latitude, smoothedPosition.longitude);

    // Verificar si llegó a la ubicación del paso actual
    if (currentStep.location != null) {
      final distanceToTarget = _distance.as(
        LengthUnit.Meter,
        userLocation,
        currentStep.location!,
      );

      print('📍 Distancia al objetivo: ${distanceToTarget.toStringAsFixed(1)}m (GPS: ${position.accuracy.toStringAsFixed(1)}m)');

      // Alerta de proximidad (solo si no se ha anunciado antes)
      if (distanceToTarget <= PROXIMITY_ALERT_METERS && distanceToTarget > ARRIVAL_THRESHOLD_METERS) {
        _announceProximity(currentStep);
      }

      // Llegada al objetivo (ajustar threshold según precisión GPS)
      final adjustedThreshold = ARRIVAL_THRESHOLD_METERS + (position.accuracy * 0.5);
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
    }
  }

  /// Maneja llegada a un paso
  void _handleStepArrival(NavigationStep step) {
    print('✅ Llegada al paso: ${step.type}');

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
        announcement = 'Estás en el paradero correcto. Espera el bus Red ${step.busRoute}';
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

    if (announcement.isNotEmpty) {
      TtsService.instance.speak(announcement);
    }

    // Avanzar al siguiente paso
    _activeNavigation!.advanceToNextStep();
    onStepChanged?.call(_activeNavigation!.currentStep ?? step);

    // Anunciar siguiente paso
    if (!_activeNavigation!.isComplete) {
      final nextStep = _activeNavigation!.currentStep!;
      TtsService.instance.speak('Siguiente paso: ${nextStep.instruction}');
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
