import 'package:equatable/equatable.dart';
import 'package:latlong2/latlong.dart';

/// ============================================================================
/// NAVIGATION STATE - Estados de navegación
/// ============================================================================
/// Gestiona el estado de la navegación GPS turn-by-turn:
/// - Cálculo de rutas
/// - Navegación activa
/// - Instrucciones de giro
/// - Recalculación automática
/// - Llegada a destino

abstract class NavigationState extends Equatable {
  const NavigationState();

  @override
  List<Object?> get props => [];
}

/// Estado inicial - Sin navegación activa
class NavigationInitial extends NavigationState {
  const NavigationInitial();
}

/// Calculando ruta
class NavigationCalculating extends NavigationState {
  final LatLng origin;
  final LatLng destination;
  final String? destinationName;

  const NavigationCalculating({
    required this.origin,
    required this.destination,
    this.destinationName,
  });

  @override
  List<Object?> get props => [origin, destination, destinationName];
}

/// Ruta calculada, navegación activa
class NavigationActive extends NavigationState {
  final NavigationRoute route;
  final int currentStepIndex;
  final double distanceToNextStep; // metros
  final double totalDistanceRemaining; // metros
  final Duration estimatedTimeRemaining;
  final LatLng currentPosition;
  final double? currentHeading; // grados (0-360)
  final NavigationInstruction? currentInstruction;
  final NavigationInstruction? nextInstruction;

  const NavigationActive({
    required this.route,
    required this.currentStepIndex,
    required this.distanceToNextStep,
    required this.totalDistanceRemaining,
    required this.estimatedTimeRemaining,
    required this.currentPosition,
    this.currentHeading,
    this.currentInstruction,
    this.nextInstruction,
  });

  @override
  List<Object?> get props => [
    route,
    currentStepIndex,
    distanceToNextStep,
    totalDistanceRemaining,
    estimatedTimeRemaining,
    currentPosition,
    currentHeading,
    currentInstruction,
    nextInstruction,
  ];

  /// Helpers
  bool get isNearNextStep => distanceToNextStep < 50; // menos de 50m
  bool get isAlmostArrived => totalDistanceRemaining < 100; // menos de 100m
  double get progressPercentage =>
      1.0 - (totalDistanceRemaining / route.totalDistance);

  /// Formateo para UI
  String get distanceToNextStepFormatted {
    if (distanceToNextStep < 1000) {
      return '${distanceToNextStep.toInt()} m';
    }
    return '${(distanceToNextStep / 1000).toStringAsFixed(1)} km';
  }

  String get totalDistanceRemainingFormatted {
    if (totalDistanceRemaining < 1000) {
      return '${totalDistanceRemaining.toInt()} m';
    }
    return '${(totalDistanceRemaining / 1000).toStringAsFixed(1)} km';
  }

  String get estimatedTimeRemainingFormatted {
    final minutes = estimatedTimeRemaining.inMinutes;
    if (minutes < 60) {
      return '$minutes min';
    }
    final hours = minutes ~/ 60;
    final remainingMinutes = minutes % 60;
    return '$hours h $remainingMinutes min';
  }

  NavigationActive copyWith({
    NavigationRoute? route,
    int? currentStepIndex,
    double? distanceToNextStep,
    double? totalDistanceRemaining,
    Duration? estimatedTimeRemaining,
    LatLng? currentPosition,
    double? currentHeading,
    NavigationInstruction? currentInstruction,
    NavigationInstruction? nextInstruction,
  }) {
    return NavigationActive(
      route: route ?? this.route,
      currentStepIndex: currentStepIndex ?? this.currentStepIndex,
      distanceToNextStep: distanceToNextStep ?? this.distanceToNextStep,
      totalDistanceRemaining:
          totalDistanceRemaining ?? this.totalDistanceRemaining,
      estimatedTimeRemaining:
          estimatedTimeRemaining ?? this.estimatedTimeRemaining,
      currentPosition: currentPosition ?? this.currentPosition,
      currentHeading: currentHeading ?? this.currentHeading,
      currentInstruction: currentInstruction ?? this.currentInstruction,
      nextInstruction: nextInstruction ?? this.nextInstruction,
    );
  }
}

/// Llegada a destino
class NavigationArrived extends NavigationState {
  final LatLng destination;
  final String? destinationName;
  final Duration totalDuration;
  final double totalDistance; // metros

  const NavigationArrived({
    required this.destination,
    this.destinationName,
    required this.totalDuration,
    required this.totalDistance,
  });

  @override
  List<Object?> get props => [
    destination,
    destinationName,
    totalDuration,
    totalDistance,
  ];

  String get totalDistanceFormatted {
    if (totalDistance < 1000) {
      return '${totalDistance.toInt()} m';
    }
    return '${(totalDistance / 1000).toStringAsFixed(2)} km';
  }
}

/// Error en navegación
class NavigationError extends NavigationState {
  final String message;
  final NavigationErrorType errorType;
  final StackTrace? stackTrace;

  const NavigationError({
    required this.message,
    required this.errorType,
    this.stackTrace,
  });

  @override
  List<Object?> get props => [message, errorType];
}

/// Recalculando ruta (usuario se desvió)
class NavigationRecalculating extends NavigationState {
  final LatLng currentPosition;
  final LatLng destination;
  final String reason;

  const NavigationRecalculating({
    required this.currentPosition,
    required this.destination,
    required this.reason,
  });

  @override
  List<Object?> get props => [currentPosition, destination, reason];
}

// =============================================================================
// MODELOS DE DATOS
// =============================================================================

/// Ruta completa de navegación
class NavigationRoute extends Equatable {
  final String id;
  final LatLng origin;
  final LatLng destination;
  final List<NavigationStep> steps;
  final List<LatLng> polylinePoints;
  final double totalDistance; // metros
  final Duration estimatedDuration;
  final DateTime calculatedAt;

  const NavigationRoute({
    required this.id,
    required this.origin,
    required this.destination,
    required this.steps,
    required this.polylinePoints,
    required this.totalDistance,
    required this.estimatedDuration,
    required this.calculatedAt,
  });

  @override
  List<Object?> get props => [
    id,
    origin,
    destination,
    steps,
    polylinePoints,
    totalDistance,
    estimatedDuration,
  ];
}

/// Paso individual de navegación
class NavigationStep extends Equatable {
  final int index;
  final LatLng startLocation;
  final LatLng endLocation;
  final double distance; // metros
  final Duration duration;
  final String instruction; // "Gira a la izquierda en Av. Providencia"
  final NavigationManeuver maneuver;
  final String? roadName;

  const NavigationStep({
    required this.index,
    required this.startLocation,
    required this.endLocation,
    required this.distance,
    required this.duration,
    required this.instruction,
    required this.maneuver,
    this.roadName,
  });

  @override
  List<Object?> get props => [
    index,
    startLocation,
    endLocation,
    distance,
    duration,
    instruction,
    maneuver,
    roadName,
  ];
}

/// Instrucción de navegación con iconografía
class NavigationInstruction extends Equatable {
  final NavigationManeuver maneuver;
  final String text;
  final double distance; // metros hasta esta instrucción
  final String? roadName;

  const NavigationInstruction({
    required this.maneuver,
    required this.text,
    required this.distance,
    this.roadName,
  });

  @override
  List<Object?> get props => [maneuver, text, distance, roadName];

  /// Ícono según tipo de maniobra
  String get iconAsset {
    switch (maneuver) {
      case NavigationManeuver.turnLeft:
        return 'assets/icons/turn_left.png';
      case NavigationManeuver.turnRight:
        return 'assets/icons/turn_right.png';
      case NavigationManeuver.turnSlightLeft:
        return 'assets/icons/turn_slight_left.png';
      case NavigationManeuver.turnSlightRight:
        return 'assets/icons/turn_slight_right.png';
      case NavigationManeuver.turnSharpLeft:
        return 'assets/icons/turn_sharp_left.png';
      case NavigationManeuver.turnSharpRight:
        return 'assets/icons/turn_sharp_right.png';
      case NavigationManeuver.continue_:
        return 'assets/icons/continue_straight.png';
      case NavigationManeuver.arrive:
        return 'assets/icons/arrive.png';
      case NavigationManeuver.depart:
        return 'assets/icons/depart.png';
      case NavigationManeuver.roundabout:
        return 'assets/icons/roundabout.png';
      case NavigationManeuver.uturn:
        return 'assets/icons/uturn.png';
    }
  }
}

/// Tipos de maniobras
enum NavigationManeuver {
  turnLeft,
  turnRight,
  turnSlightLeft,
  turnSlightRight,
  turnSharpLeft,
  turnSharpRight,
  continue_, // "continue" es palabra reservada
  arrive,
  depart,
  roundabout,
  uturn,
}

/// Tipos de errores de navegación
enum NavigationErrorType {
  routeCalculationFailed, // No se pudo calcular ruta
  noRouteFound, // Sin ruta disponible
  gpsSignalLost, // Perdida de señal GPS
  tooFarFromRoute, // Usuario muy lejos de la ruta
  networkError, // Error de red
  unknown,
}
