import 'package:equatable/equatable.dart';
import 'package:geolocator/geolocator.dart';

/// ============================================================================
/// LOCATION STATE - Estados de ubicación GPS
/// ============================================================================
/// Maneja todos los estados posibles del sistema de ubicación

abstract class LocationState extends Equatable {
  const LocationState();

  @override
  List<Object?> get props => [];
}

/// Estado inicial - GPS no inicializado
class LocationInitial extends LocationState {
  const LocationInitial();
}

/// Estado de carga - Solicitando permisos o inicializando GPS
class LocationLoading extends LocationState {
  const LocationLoading();
}

/// Estado exitoso - GPS funcionando y con posición actualizada
class LocationLoaded extends LocationState {
  final Position position;
  final double? heading; // Orientación del dispositivo (0-360°)
  final DateTime timestamp;

  const LocationLoaded({
    required this.position,
    this.heading,
    required this.timestamp,
  });

  @override
  List<Object?> get props => [
        position.latitude,
        position.longitude,
        position.accuracy,
        heading,
        timestamp,
      ];

  /// Crea copia con cambios
  LocationLoaded copyWith({
    Position? position,
    double? heading,
    DateTime? timestamp,
  }) {
    return LocationLoaded(
      position: position ?? this.position,
      heading: heading ?? this.heading,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  /// Calcula distancia a otra posición
  double distanceTo(double targetLat, double targetLon) {
    return Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      targetLat,
      targetLon,
    );
  }

  /// Verifica si la posición es precisa (< 20 metros)
  bool get isAccurate => position.accuracy < 20.0;

  /// Verifica si la posición es reciente (< 10 segundos)
  bool get isRecent {
    return DateTime.now().difference(timestamp).inSeconds < 10;
  }
}

/// Estado de error - Permisos denegados, GPS desactivado, etc.
class LocationError extends LocationState {
  final String message;
  final LocationErrorType errorType;

  const LocationError({
    required this.message,
    required this.errorType,
  });

  @override
  List<Object?> get props => [message, errorType];
}

/// Tipos de errores de ubicación
enum LocationErrorType {
  permissionDenied, // Usuario denegó permisos
  permissionDeniedForever, // Usuario denegó permanentemente
  serviceDisabled, // GPS desactivado en el dispositivo
  timeout, // Timeout esperando ubicación
  unknown, // Error desconocido
}

/// Estado de permiso - Esperando decisión del usuario
class LocationPermissionRequested extends LocationState {
  const LocationPermissionRequested();
}
