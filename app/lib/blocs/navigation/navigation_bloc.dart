import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'navigation_event.dart';
import 'navigation_state.dart';
import '../../services/debug_logger.dart';
import '../../services/routing_service.dart';

/// ============================================================================
/// NAVIGATION BLOC - Gestión de navegación turn-by-turn
/// ============================================================================
/// Maneja toda la lógica de navegación GPS:
/// - Cálculo de rutas con GraphHopper backend
/// - Tracking de posición en tiempo real
/// - Detección de desvíos de ruta
/// - Recalculación automática
/// - Instrucciones de giro
///
/// Beneficios vs setState():
/// - Testeable independientemente (mock rutas)
/// - Reactive programming
/// - Separación de lógica y UI
/// - Estado inmutable (debugging más fácil)

class NavigationBloc extends Bloc<NavigationEvent, NavigationState> {
  StreamSubscription<Position>? _positionSubscription;
  DateTime? _navigationStartTime;

  // Configuración
  static const double _offRouteThreshold = 50.0; // metros
  static const double _arrivedThreshold = 20.0; // metros
  static const double _nextStepThreshold = 30.0; // metros

  NavigationBloc() : super(const NavigationInitial()) {
    on<NavigationStarted>(_onNavigationStarted);
    on<NavigationPositionUpdated>(_onNavigationPositionUpdated);
    on<NavigationRecalculateRequested>(_onNavigationRecalculateRequested);
    on<NavigationStopped>(_onNavigationStopped);
    on<NavigationErrorOccurred>(_onNavigationErrorOccurred);
    on<NavigationNextStepReached>(_onNavigationNextStepReached);
    on<NavigationDestinationReached>(_onNavigationDestinationReached);
  }

  /// Iniciar navegación
  Future<void> _onNavigationStarted(
    NavigationStarted event,
    Emitter<NavigationState> emit,
  ) async {
    DebugLogger.info(
      'Iniciando navegación a ${event.destinationName ?? event.destination}',
      context: 'NavigationBloc',
    );

    emit(
      NavigationCalculating(
        origin: event.origin ?? _getCurrentPosition(),
        destination: event.destination,
        destinationName: event.destinationName,
      ),
    );

    try {
      // =========================================================================
      // CALCULAR RUTA CON GRAPHHOPPER BACKEND
      // =========================================================================
      final route = await _calculateRoute(
        origin: event.origin ?? _getCurrentPosition(),
        destination: event.destination,
      );

      _navigationStartTime = DateTime.now();

      // Emitir estado de navegación activa
      emit(
        NavigationActive(
          route: route,
          currentStepIndex: 0,
          distanceToNextStep: route.steps.first.distance,
          totalDistanceRemaining: route.totalDistance,
          estimatedTimeRemaining: route.estimatedDuration,
          currentPosition: route.origin,
          currentInstruction: _buildInstruction(route.steps.first),
          nextInstruction: route.steps.length > 1
              ? _buildInstruction(route.steps[1])
              : null,
        ),
      );

      DebugLogger.success(
        'Ruta calculada: ${route.totalDistance.toInt()}m, ${route.steps.length} pasos',
        context: 'NavigationBloc',
      );
    } catch (e, stackTrace) {
      DebugLogger.error(
        'Error calculando ruta',
        context: 'NavigationBloc',
        error: e,
        stackTrace: stackTrace,
      );

      emit(
        NavigationError(
          message: 'No se pudo calcular la ruta: $e',
          errorType: NavigationErrorType.routeCalculationFailed,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  /// Actualizar posición durante navegación
  Future<void> _onNavigationPositionUpdated(
    NavigationPositionUpdated event,
    Emitter<NavigationState> emit,
  ) async {
    final currentState = state;
    if (currentState is! NavigationActive) return;

    final currentStep = currentState.route.steps[currentState.currentStepIndex];

    // =========================================================================
    // CALCULAR DISTANCIA AL SIGUIENTE PASO
    // =========================================================================
    final distanceToNextStep = Geolocator.distanceBetween(
      event.position.latitude,
      event.position.longitude,
      currentStep.endLocation.latitude,
      currentStep.endLocation.longitude,
    );

    // =========================================================================
    // VERIFICAR SI LLEGÓ AL DESTINO
    // =========================================================================
    final distanceToDestination = Geolocator.distanceBetween(
      event.position.latitude,
      event.position.longitude,
      currentState.route.destination.latitude,
      currentState.route.destination.longitude,
    );

    if (distanceToDestination < _arrivedThreshold) {
      add(const NavigationDestinationReached());
      return;
    }

    // =========================================================================
    // VERIFICAR SI AVANZÓ AL SIGUIENTE PASO
    // =========================================================================
    if (distanceToNextStep < _nextStepThreshold &&
        currentState.currentStepIndex < currentState.route.steps.length - 1) {
      add(
        NavigationNextStepReached(stepIndex: currentState.currentStepIndex + 1),
      );
      return;
    }

    // =========================================================================
    // VERIFICAR SI SE DESVIÓ DE LA RUTA
    // =========================================================================
    final distanceToRoute = _calculateDistanceToPolyline(
      event.position,
      currentState.route.polylinePoints,
    );

    if (distanceToRoute > _offRouteThreshold) {
      DebugLogger.warning(
        'Usuario desviado de la ruta: ${distanceToRoute.toInt()}m',
        context: 'NavigationBloc',
      );

      add(
        const NavigationRecalculateRequested(
          reason: 'Usuario fuera de la ruta',
        ),
      );
      return;
    }

    // =========================================================================
    // ACTUALIZAR ESTADO CON NUEVA POSICIÓN
    // =========================================================================
    final totalDistanceRemaining = _calculateRemainingDistance(
      event.position,
      currentState.route,
      currentState.currentStepIndex,
    );

    final estimatedTimeRemaining = _calculateEstimatedTime(
      totalDistanceRemaining,
      averageSpeed: 5.0, // 5 m/s = 18 km/h (caminando/transporte)
    );

    emit(
      currentState.copyWith(
        currentPosition: event.position,
        currentHeading: event.heading,
        distanceToNextStep: distanceToNextStep,
        totalDistanceRemaining: totalDistanceRemaining,
        estimatedTimeRemaining: estimatedTimeRemaining,
      ),
    );
  }

  /// Avanzar al siguiente paso
  Future<void> _onNavigationNextStepReached(
    NavigationNextStepReached event,
    Emitter<NavigationState> emit,
  ) async {
    final currentState = state;
    if (currentState is! NavigationActive) return;

    final newStepIndex = event.stepIndex;
    if (newStepIndex >= currentState.route.steps.length) return;

    final newStep = currentState.route.steps[newStepIndex];
    final nextStep = newStepIndex + 1 < currentState.route.steps.length
        ? currentState.route.steps[newStepIndex + 1]
        : null;

    DebugLogger.info(
      'Avanzando a paso ${newStepIndex + 1}/${currentState.route.steps.length}: ${newStep.instruction}',
      context: 'NavigationBloc',
    );

    emit(
      currentState.copyWith(
        currentStepIndex: newStepIndex,
        distanceToNextStep: newStep.distance,
        currentInstruction: _buildInstruction(newStep),
        nextInstruction: nextStep != null ? _buildInstruction(nextStep) : null,
      ),
    );
  }

  /// Recalcular ruta
  Future<void> _onNavigationRecalculateRequested(
    NavigationRecalculateRequested event,
    Emitter<NavigationState> emit,
  ) async {
    final currentState = state;
    if (currentState is! NavigationActive) return;

    DebugLogger.warning(
      'Recalculando ruta: ${event.reason}',
      context: 'NavigationBloc',
    );

    emit(
      NavigationRecalculating(
        currentPosition: currentState.currentPosition,
        destination: currentState.route.destination,
        reason: event.reason,
      ),
    );

    try {
      final newRoute = await _calculateRoute(
        origin: currentState.currentPosition,
        destination: currentState.route.destination,
      );

      emit(
        NavigationActive(
          route: newRoute,
          currentStepIndex: 0,
          distanceToNextStep: newRoute.steps.first.distance,
          totalDistanceRemaining: newRoute.totalDistance,
          estimatedTimeRemaining: newRoute.estimatedDuration,
          currentPosition: currentState.currentPosition,
          currentHeading: currentState.currentHeading,
          currentInstruction: _buildInstruction(newRoute.steps.first),
          nextInstruction: newRoute.steps.length > 1
              ? _buildInstruction(newRoute.steps[1])
              : null,
        ),
      );

      DebugLogger.success('Ruta recalculada', context: 'NavigationBloc');
    } catch (e) {
      add(
        NavigationErrorOccurred(
          message: 'Error recalculando ruta: $e',
          errorType: NavigationErrorType.routeCalculationFailed,
        ),
      );
    }
  }

  /// Llegada a destino
  Future<void> _onNavigationDestinationReached(
    NavigationDestinationReached event,
    Emitter<NavigationState> emit,
  ) async {
    final currentState = state;
    if (currentState is! NavigationActive) return;

    final totalDuration = _navigationStartTime != null
        ? DateTime.now().difference(_navigationStartTime!)
        : Duration.zero;

    DebugLogger.success(
      '¡Destino alcanzado! Duración: ${totalDuration.inMinutes} min',
      context: 'NavigationBloc',
    );

    emit(
      NavigationArrived(
        destination: currentState.route.destination,
        destinationName: null, // TODO: obtener del route
        totalDuration: totalDuration,
        totalDistance: currentState.route.totalDistance,
      ),
    );

    // Auto-detener navegación después de 5 segundos
    await Future.delayed(const Duration(seconds: 5));
    add(const NavigationStopped(reason: 'Destino alcanzado'));
  }

  /// Detener navegación
  Future<void> _onNavigationStopped(
    NavigationStopped event,
    Emitter<NavigationState> emit,
  ) async {
    DebugLogger.info(
      'Deteniendo navegación: ${event.reason ?? "usuario"}',
      context: 'NavigationBloc',
    );

    await _positionSubscription?.cancel();
    _positionSubscription = null;
    _navigationStartTime = null;

    emit(const NavigationInitial());
  }

  /// Error de navegación
  Future<void> _onNavigationErrorOccurred(
    NavigationErrorOccurred event,
    Emitter<NavigationState> emit,
  ) async {
    DebugLogger.error(
      'Error de navegación',
      context: 'NavigationBloc',
      error: event.message,
      stackTrace: event.stackTrace,
    );

    emit(
      NavigationError(
        message: event.message,
        errorType: event.errorType,
        stackTrace: event.stackTrace,
      ),
    );
  }

  // ===========================================================================
  // HELPERS PRIVADOS
  // ===========================================================================

  /// Calcular ruta usando GraphHopper backend REAL
  Future<NavigationRoute> _calculateRoute({
    required LatLng origin,
    required LatLng destination,
  }) async {
    try {
      DebugLogger.info(
        '🗺️  Calculando ruta con GraphHopper: ${origin.latitude.toStringAsFixed(4)},${origin.longitude.toStringAsFixed(4)} → ${destination.latitude.toStringAsFixed(4)},${destination.longitude.toStringAsFixed(4)}',
        context: 'NavigationBloc',
      );

      // =========================================================================
      // LLAMAR AL BACKEND GRAPHHOPPER LOCAL
      // =========================================================================
      final routeResponse = await RoutingService.instance.getWalkingRoute(
        origin: origin,
        destination: destination,
      );

      final routeData = routeResponse.route;

      // =========================================================================
      // CONVERTIR INSTRUCCIONES DE GRAPHHOPPER A NAVIGATION STEPS
      // =========================================================================
      final steps = <NavigationStep>[];

      for (int i = 0; i < routeData.instructions.length; i++) {
        final instruction = routeData.instructions[i];

        // Determinar ubicación de inicio y fin del paso
        final startIndex = i == 0 ? 0 : routeData.instructions[i - 1].interval;
        final endIndex = instruction.interval.clamp(
          0,
          routeData.geometry.length - 1,
        );

        final startLocation = startIndex < routeData.geometry.length
            ? routeData.geometry[startIndex]
            : origin;
        final endLocation = endIndex < routeData.geometry.length
            ? routeData.geometry[endIndex]
            : destination;

        // Convertir tipo de maniobra de GraphHopper a nuestro enum
        final maneuver = _convertManeuverType(instruction.sign);

        steps.add(
          NavigationStep(
            index: i,
            startLocation: startLocation,
            endLocation: endLocation,
            distance: instruction.distance,
            duration: instruction.duration,
            instruction: instruction.text,
            maneuver: maneuver,
            roadName: instruction.streetName,
          ),
        );
      }

      // Si no hay instrucciones, crear un paso único
      if (steps.isEmpty) {
        steps.add(
          NavigationStep(
            index: 0,
            startLocation: origin,
            endLocation: destination,
            distance: routeData.distance,
            duration: routeData.duration,
            instruction: 'Dirigirse hacia el destino',
            maneuver: NavigationManeuver.continue_,
            roadName: null,
          ),
        );
      }

      final route = NavigationRoute(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        origin: origin,
        destination: destination,
        steps: steps,
        polylinePoints: routeData.geometry,
        totalDistance: routeData.distance,
        estimatedDuration: routeData.duration,
        calculatedAt: DateTime.now(),
      );

      DebugLogger.success(
        '✅ Ruta calculada: ${(routeData.distance / 1000).toStringAsFixed(2)} km, ${steps.length} pasos, ${_formatDuration(routeData.duration)}',
        context: 'NavigationBloc',
      );

      return route;
    } catch (e, stackTrace) {
      DebugLogger.error(
        'Error calculando ruta con GraphHopper',
        context: 'NavigationBloc',
        error: e,
        stackTrace: stackTrace,
      );

      // Fallback: generar ruta simple en caso de error
      DebugLogger.warning(
        '⚠️  Usando ruta de respaldo (línea recta)',
        context: 'NavigationBloc',
      );

      final distance = Geolocator.distanceBetween(
        origin.latitude,
        origin.longitude,
        destination.latitude,
        destination.longitude,
      );

      final step = NavigationStep(
        index: 0,
        startLocation: origin,
        endLocation: destination,
        distance: distance,
        duration: Duration(seconds: (distance / 1.4).round()), // ~5 km/h
        instruction: 'Dirigirse hacia el destino',
        maneuver: NavigationManeuver.continue_,
        roadName: null,
      );

      return NavigationRoute(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        origin: origin,
        destination: destination,
        steps: [step],
        polylinePoints: [origin, destination],
        totalDistance: distance,
        estimatedDuration: step.duration,
        calculatedAt: DateTime.now(),
      );
    }
  }

  /// Convertir código de maniobra de GraphHopper a enum
  NavigationManeuver _convertManeuverType(int sign) {
    switch (sign) {
      case -3:
        return NavigationManeuver.turnSharpLeft;
      case -2:
        return NavigationManeuver.turnLeft;
      case -1:
        return NavigationManeuver.turnSlightLeft;
      case 0:
        return NavigationManeuver.continue_;
      case 1:
        return NavigationManeuver.turnSlightRight;
      case 2:
        return NavigationManeuver.turnRight;
      case 3:
        return NavigationManeuver.turnSharpRight;
      case 4:
        return NavigationManeuver.arrive;
      case 6:
        return NavigationManeuver.roundabout;
      default:
        return NavigationManeuver.continue_;
    }
  }

  /// Formatear duración a texto legible
  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);

    if (hours > 0) {
      return '${hours}h ${minutes}min';
    }
    return '${minutes}min';
  }

  /// Obtener posición actual (mock)
  LatLng _getCurrentPosition() {
    // TODO: Obtener de LocationBloc
    return const LatLng(-33.4489, -70.6693); // Santiago centro
  }

  /// Calcular distancia a la polyline más cercana
  double _calculateDistanceToPolyline(LatLng point, List<LatLng> polyline) {
    if (polyline.isEmpty) return double.infinity;

    double minDistance = double.infinity;

    for (int i = 0; i < polyline.length - 1; i++) {
      final p1 = polyline[i];
      final p2 = polyline[i + 1];

      final distance = _distanceToLineSegment(point, p1, p2);
      if (distance < minDistance) {
        minDistance = distance;
      }
    }

    return minDistance;
  }

  /// Calcular distancia de un punto a un segmento de línea
  double _distanceToLineSegment(
    LatLng point,
    LatLng lineStart,
    LatLng lineEnd,
  ) {
    final distance = Geolocator.distanceBetween(
      point.latitude,
      point.longitude,
      lineStart.latitude,
      lineStart.longitude,
    );

    return distance; // Simplificado - en producción usar geometría real
  }

  /// Calcular distancia restante
  double _calculateRemainingDistance(
    LatLng currentPosition,
    NavigationRoute route,
    int currentStepIndex,
  ) {
    double remaining = 0;

    // Distancia desde posición actual al final del paso actual
    final currentStep = route.steps[currentStepIndex];
    remaining += Geolocator.distanceBetween(
      currentPosition.latitude,
      currentPosition.longitude,
      currentStep.endLocation.latitude,
      currentStep.endLocation.longitude,
    );

    // Sumar distancias de pasos restantes
    for (int i = currentStepIndex + 1; i < route.steps.length; i++) {
      remaining += route.steps[i].distance;
    }

    return remaining;
  }

  /// Calcular tiempo estimado
  Duration _calculateEstimatedTime(
    double distance, {
    required double averageSpeed,
  }) {
    final seconds = (distance / averageSpeed).round();
    return Duration(seconds: seconds);
  }

  /// Construir instrucción desde paso
  NavigationInstruction _buildInstruction(NavigationStep step) {
    return NavigationInstruction(
      maneuver: step.maneuver,
      text: step.instruction,
      distance: step.distance,
      roadName: step.roadName,
    );
  }

  @override
  Future<void> close() {
    _positionSubscription?.cancel();
    return super.close();
  }
}
