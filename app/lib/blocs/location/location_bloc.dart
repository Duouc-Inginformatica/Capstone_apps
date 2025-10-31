import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'location_event.dart';
import 'location_state.dart';
import '../../services/debug_logger.dart';

/// ============================================================================
/// LOCATION BLOC - Gestión de estado de ubicación GPS
/// ============================================================================
/// Maneja toda la lógica de ubicación GPS:
/// - Permisos de ubicación
/// - Stream de actualizaciones GPS
/// - Throttling de eventos (evita updates excesivos)
/// - Detección de precisión baja
///
/// Beneficios vs setState():
/// - Testeable independientemente
/// - Reactive programming
/// - Separación de lógica y UI
/// - Rebuild selectivo (solo widgets que usan LocationBloc)

class LocationBloc extends Bloc<LocationEvent, LocationState> {
  StreamSubscription<Position>? _positionStreamSubscription;
  Position? _lastPosition;
  DateTime? _lastUpdateTime;

  // Configuración de throttling
  static const Duration _throttleDuration = Duration(milliseconds: 500);
  static const double _minimumDistanceFilter = 10.0; // metros

  LocationBloc() : super(const LocationInitial()) {
    // Registrar handlers de eventos
    on<LocationStarted>(_onLocationStarted);
    on<LocationStopped>(_onLocationStopped);
    on<LocationUpdated>(_onLocationUpdated);
    on<LocationErrorOccurred>(_onLocationErrorOccurred);
    on<LocationPermissionRequested>(_onLocationPermissionRequested);
    on<LocationPermissionChecked>(_onLocationPermissionChecked);
    on<LocationRefreshRequested>(_onLocationRefreshRequested);
  }

  /// Iniciar servicio de ubicación
  Future<void> _onLocationStarted(
    LocationStarted event,
    Emitter<LocationState> emit,
  ) async {
    DebugLogger.info(
      'Iniciando servicio de ubicación',
      context: 'LocationBloc',
    );
    emit(const LocationLoading());

    try {
      // 1. Verificar si el servicio de ubicación está habilitado
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        emit(
          const LocationError(
            message: 'GPS desactivado. Activa la ubicación en Configuración.',
            errorType: LocationErrorType.serviceDisabled,
          ),
        );
        return;
      }

      // 2. Verificar permisos
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          emit(
            const LocationError(
              message: 'Permisos de ubicación denegados',
              errorType: LocationErrorType.permissionDenied,
            ),
          );
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        emit(
          const LocationError(
            message:
                'Permisos de ubicación denegados permanentemente. Ve a Configuración para habilitarlos.',
            errorType: LocationErrorType.permissionDeniedForever,
          ),
        );
        return;
      }

      // 3. Obtener posición inicial
      final initialPosition =
          await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 0,
              timeLimit: Duration(seconds: 15),
            ),
          ).timeout(
            const Duration(seconds: 20),
            onTimeout: () async {
              return await Geolocator.getLastKnownPosition() ??
                  Position(
                    latitude: -33.4489,
                    longitude: -70.6693,
                    timestamp: DateTime.now(),
                    accuracy: 0,
                    altitude: 0,
                    altitudeAccuracy: 0,
                    heading: 0,
                    headingAccuracy: 0,
                    speed: 0,
                    speedAccuracy: 0,
                  );
            },
          );

      _lastPosition = initialPosition;
      _lastUpdateTime = DateTime.now();

      emit(
        LocationLoaded(position: initialPosition, timestamp: DateTime.now()),
      );

      DebugLogger.success(
        'Posición inicial: ${initialPosition.latitude}, ${initialPosition.longitude}',
        context: 'LocationBloc',
      );

      // 4. Suscribirse al stream de posiciones
      _positionStreamSubscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 5,
              timeLimit: Duration(minutes: 5),
            ),
          ).listen(
            (Position position) {
              add(
                LocationUpdated(
                  latitude: position.latitude,
                  longitude: position.longitude,
                  accuracy: position.accuracy,
                  heading: position.heading,
                  timestamp: DateTime.now(),
                ),
              );
            },
            onError: (error) {
              DebugLogger.warning(
                'Stream error: $error',
                context: 'LocationBloc',
              );
            },
          );
    } catch (e, stackTrace) {
      DebugLogger.error(
        'Error iniciando ubicación',
        context: 'LocationBloc',
        error: e,
        stackTrace: stackTrace,
      );

      emit(
        LocationError(
          message: 'Error: ${e.toString()}',
          errorType: LocationErrorType.unknown,
        ),
      );
    }
  }

  /// Detener servicio de ubicación
  Future<void> _onLocationStopped(
    LocationStopped event,
    Emitter<LocationState> emit,
  ) async {
    DebugLogger.info(
      'Deteniendo servicio de ubicación',
      context: 'LocationBloc',
    );

    await _positionStreamSubscription?.cancel();
    _positionStreamSubscription = null;
    _lastPosition = null;
    _lastUpdateTime = null;

    emit(const LocationInitial());
  }

  /// Nueva posición GPS recibida
  Future<void> _onLocationUpdated(
    LocationUpdated event,
    Emitter<LocationState> emit,
  ) async {
    final now = DateTime.now();

    // =========================================================================
    // THROTTLING: Evitar updates muy frecuentes
    // =========================================================================
    if (_lastUpdateTime != null) {
      final timeSinceLastUpdate = now.difference(_lastUpdateTime!);
      if (timeSinceLastUpdate < _throttleDuration) {
        // Ignorar update si es muy reciente
        return;
      }
    }

    // =========================================================================
    // DISTANCE FILTER: Solo emitir si hay movimiento significativo
    // =========================================================================
    if (_lastPosition != null) {
      final distance = Geolocator.distanceBetween(
        _lastPosition!.latitude,
        _lastPosition!.longitude,
        event.latitude,
        event.longitude,
      );

      if (distance < _minimumDistanceFilter) {
        // Ignorar update si el movimiento es muy pequeño
        return;
      }
    }

    // =========================================================================
    // EMITIR NUEVO ESTADO
    // =========================================================================
    final position = Position(
      latitude: event.latitude,
      longitude: event.longitude,
      timestamp: event.timestamp,
      accuracy: event.accuracy,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: event.heading ?? 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

    _lastPosition = position;
    _lastUpdateTime = now;

    emit(
      LocationLoaded(
        position: position,
        heading: event.heading,
        timestamp: event.timestamp,
      ),
    );

    DebugLogger.info(
      'Ubicación actualizada: ${event.latitude.toStringAsFixed(6)}, ${event.longitude.toStringAsFixed(6)} (±${event.accuracy.toStringAsFixed(1)}m)',
      context: 'LocationBloc',
    );
  }

  /// Error de ubicación
  Future<void> _onLocationErrorOccurred(
    LocationErrorOccurred event,
    Emitter<LocationState> emit,
  ) async {
    DebugLogger.error(
      'Error de ubicación',
      context: 'LocationBloc',
      error: event.message,
    );

    emit(
      LocationError(
        message: event.message,
        errorType: LocationErrorType.unknown,
      ),
    );
  }

  /// Solicitar permisos de ubicación
  Future<void> _onLocationPermissionRequested(
    LocationPermissionRequested event,
    Emitter<LocationState> emit,
  ) async {
    emit(const LocationPermissionRequesting());

    final status = await Permission.location.request();

    if (status.isGranted) {
      add(const LocationStarted());
    } else if (status.isDenied) {
      emit(
        const LocationError(
          message: 'Permisos de ubicación denegados',
          errorType: LocationErrorType.permissionDenied,
        ),
      );
    } else if (status.isPermanentlyDenied) {
      emit(
        const LocationError(
          message: 'Abre Configuración para habilitar permisos de ubicación',
          errorType: LocationErrorType.permissionDeniedForever,
        ),
      );
    }
  }

  /// Verificar permisos de ubicación
  Future<void> _onLocationPermissionChecked(
    LocationPermissionChecked event,
    Emitter<LocationState> emit,
  ) async {
    final permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse) {
      add(const LocationStarted());
    } else {
      add(const LocationPermissionRequested());
    }
  }

  /// Refrescar ubicación manualmente
  Future<void> _onLocationRefreshRequested(
    LocationRefreshRequested event,
    Emitter<LocationState> emit,
  ) async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );

      add(
        LocationUpdated(
          latitude: position.latitude,
          longitude: position.longitude,
          accuracy: position.accuracy,
          heading: position.heading,
          timestamp: DateTime.now(),
        ),
      );
    } catch (e) {
      add(LocationErrorOccurred(message: 'Error refrescando ubicación: $e'));
    }
  }

  @override
  Future<void> close() {
    _positionStreamSubscription?.cancel();
    return super.close();
  }
}
