import 'package:equatable/equatable.dart';
import 'package:latlong2/latlong.dart';
import 'navigation_state.dart';

/// ============================================================================
/// NAVIGATION EVENT - Eventos de navegación
/// ============================================================================
/// Eventos que disparan cambios en el estado de navegación

abstract class NavigationEvent extends Equatable {
  const NavigationEvent();

  @override
  List<Object?> get props => [];
}

/// Iniciar navegación a un destino
class NavigationStarted extends NavigationEvent {
  final LatLng destination;
  final String? destinationName;
  final LatLng? origin; // Si es null, usa posición GPS actual

  const NavigationStarted({
    required this.destination,
    this.destinationName,
    this.origin,
  });

  @override
  List<Object?> get props => [destination, destinationName, origin];
}

/// Actualizar posición durante navegación
class NavigationPositionUpdated extends NavigationEvent {
  final LatLng position;
  final double? heading; // grados (0-360)
  final double accuracy; // metros
  final DateTime timestamp;

  const NavigationPositionUpdated({
    required this.position,
    this.heading,
    required this.accuracy,
    required this.timestamp,
  });

  @override
  List<Object?> get props => [position, heading, accuracy, timestamp];
}

/// Forzar recalculación de ruta (usuario se desvió)
class NavigationRecalculateRequested extends NavigationEvent {
  final String reason;

  const NavigationRecalculateRequested({required this.reason});

  @override
  List<Object?> get props => [reason];
}

/// Detener navegación
class NavigationStopped extends NavigationEvent {
  final String? reason;

  const NavigationStopped({this.reason});

  @override
  List<Object?> get props => [reason];
}

/// Error de navegación
class NavigationErrorOccurred extends NavigationEvent {
  final String message;
  final NavigationErrorType errorType;
  final StackTrace? stackTrace;

  const NavigationErrorOccurred({
    required this.message,
    required this.errorType,
    this.stackTrace,
  });

  @override
  List<Object?> get props => [message, errorType];
}

/// Avanzar al siguiente paso de navegación
class NavigationNextStepReached extends NavigationEvent {
  final int stepIndex;

  const NavigationNextStepReached({required this.stepIndex});

  @override
  List<Object?> get props => [stepIndex];
}

/// Llegada a destino
class NavigationDestinationReached extends NavigationEvent {
  const NavigationDestinationReached();
}

/// Simular navegación (para testing)
class NavigationSimulationToggled extends NavigationEvent {
  final bool enabled;

  const NavigationSimulationToggled({required this.enabled});

  @override
  List<Object?> get props => [enabled];
}
