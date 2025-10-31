import 'package:equatable/equatable.dart';

/// ============================================================================
/// LOCATION EVENTS - Eventos del sistema de ubicación
/// ============================================================================
/// Define todos los eventos que pueden ocurrir en el sistema de ubicación

abstract class LocationEvent extends Equatable {
  const LocationEvent();

  @override
  List<Object?> get props => [];
}

/// Evento: Iniciar servicio de ubicación
class LocationStarted extends LocationEvent {
  const LocationStarted();
}

/// Evento: Detener servicio de ubicación
class LocationStopped extends LocationEvent {
  const LocationStopped();
}

/// Evento: Nueva posición GPS recibida
class LocationUpdated extends LocationEvent {
  final double latitude;
  final double longitude;
  final double accuracy;
  final double? heading;
  final DateTime timestamp;

  const LocationUpdated({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    this.heading,
    required this.timestamp,
  });

  @override
  List<Object?> get props => [
    latitude,
    longitude,
    accuracy,
    heading,
    timestamp,
  ];
}

/// Evento: Error de ubicación
class LocationErrorOccurred extends LocationEvent {
  final String message;

  const LocationErrorOccurred({required this.message});

  @override
  List<Object?> get props => [message];
}

/// Evento: Solicitar permisos de ubicación
class LocationPermissionRequested extends LocationEvent {
  const LocationPermissionRequested();
}

/// Evento: Verificar permisos de ubicación
class LocationPermissionChecked extends LocationEvent {
  const LocationPermissionChecked();
}

/// Evento: Refrescar ubicación manualmente
class LocationRefreshRequested extends LocationEvent {
  const LocationRefreshRequested();
}
