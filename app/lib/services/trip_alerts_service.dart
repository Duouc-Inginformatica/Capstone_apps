import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:vibration/vibration.dart';
import 'device/tts_service.dart';

/// Sprint 5: Servicio para alertas contextuales durante el viaje
class TripAlertsService {
  TripAlertsService._internal();
  static final TripAlertsService instance = TripAlertsService._internal();

  // Estado del servicio
  bool _isMonitoring = false;
  Timer? _monitoringTimer;

  // Ubicaciones del viaje
  LatLng? _destinationStop;
  String? _destinationStopName;
  LatLng? _currentDestination;
  String? _currentDestinationName;
  String? _expectedBusRoute;

  // Configuración de alertas
  static const double _approachingStopThreshold = 300; // 300 metros
  static const double _nearStopThreshold = 150; // 150 metros
  static const double _veryNearStopThreshold = 50; // 50 metros
  static const Duration _monitoringInterval = Duration(seconds: 8);

  // Control de alertas (para no repetir)
  bool _approachingAlertGiven = false;
  bool _nearAlertGiven = false;
  bool _veryNearAlertGiven = false;

  // Callbacks
  Function(double distance)? onApproachingStop;
  Function()? onArrivedAtStop;
  Function(String message)? onAlert;

  bool get isMonitoring => _isMonitoring;

  /// Sprint 5: Recordar antes de llegar al paradero
  void startMonitoring({
    required LatLng destinationStop,
    required String destinationStopName,
    required LatLng finalDestination,
    required String finalDestinationName,
    String? busRoute,
  }) {
    _destinationStop = destinationStop;
    _destinationStopName = destinationStopName;
    _currentDestination = finalDestination;
    _currentDestinationName = finalDestinationName;
    _expectedBusRoute = busRoute;
    _isMonitoring = true;

    // Resetear banderas de alertas
    _approachingAlertGiven = false;
    _nearAlertGiven = false;
    _veryNearAlertGiven = false;

    TtsService.instance.speak(
      'Iniciando monitoreo del viaje. Te avisaré cuando estés cerca de $_destinationStopName.',
    );

    _monitoringTimer?.cancel();
    _monitoringTimer = Timer.periodic(
      _monitoringInterval,
      (_) => _checkProximity(),
    );

    // Primera verificación inmediata
    _checkProximity();
  }

  /// Detener monitoreo
  void stopMonitoring() {
    _isMonitoring = false;
    _monitoringTimer?.cancel();
    _destinationStop = null;
    _destinationStopName = null;
    _currentDestination = null;
    _currentDestinationName = null;
    _expectedBusRoute = null;
    _approachingAlertGiven = false;
    _nearAlertGiven = false;
    _veryNearAlertGiven = false;
  }

  /// Sprint 5: Verificar proximidad a la parada de destino
  Future<void> _checkProximity() async {
    if (!_isMonitoring || _destinationStop == null) return;

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      final currentLocation = LatLng(position.latitude, position.longitude);
      final distanceToStop = _calculateDistance(
        currentLocation,
        _destinationStop!,
      );

      onApproachingStop?.call(distanceToStop);

      // Alertas progresivas según distancia
      if (distanceToStop <= _veryNearStopThreshold && !_veryNearAlertGiven) {
        _giveVeryNearAlert(distanceToStop);
      } else if (distanceToStop <= _nearStopThreshold && !_nearAlertGiven) {
        _giveNearAlert(distanceToStop);
      } else if (distanceToStop <= _approachingStopThreshold &&
          !_approachingAlertGiven) {
        _giveApproachingAlert(distanceToStop);
      }
    } catch (e) {
      // Error silencioso, continuará en próximo ciclo
    }
  }

  /// Alerta: Acercándose (300m)
  void _giveApproachingAlert(double distance) {
    _approachingAlertGiven = true;

    Vibration.vibrate(duration: 200);

    final message =
        'Te estás acercando a $_destinationStopName. '
        'Distancia aproximada: ${distance.round()} metros. '
        'Prepárate para bajarte.';

    TtsService.instance.speak(message);
    onAlert?.call(message);
  }

  /// Alerta: Cerca (150m)
  void _giveNearAlert(double distance) {
    _nearAlertGiven = true;

    Vibration.vibrate(pattern: [0, 200, 100, 200]);

    final message =
        'Estás muy cerca de $_destinationStopName, '
        'a solo ${distance.round()} metros. '
        'Prepárate para solicitar la parada.';

    TtsService.instance.speak(message);
    onAlert?.call(message);
  }

  /// Alerta: Muy cerca (50m)
  void _giveVeryNearAlert(double distance) {
    _veryNearAlertGiven = true;

    Vibration.vibrate(pattern: [0, 300, 100, 300, 100, 300]);

    final message =
        '¡Atención! Llegaste a $_destinationStopName. '
        'Solicita la parada ahora. Distancia: ${distance.round()} metros.';

    TtsService.instance.speak(message);
    onAlert?.call(message);
    onArrivedAtStop?.call();
  }

  /// Sprint 5: Alerta para subir a la micro correcta
  void alertCorrectBus(String busRoute) {
    Vibration.vibrate(pattern: [0, 200, 100, 200, 100, 200]);

    final message =
        'Alerta: Asegúrate de subir al bus correcto. '
        'Debes tomar el bus $busRoute.';

    TtsService.instance.speak(message);
    onAlert?.call(message);
  }

  /// Sprint 5: Alerta de desviación de ruta
  void alertRouteDeviation(double deviationMeters) {
    Vibration.vibrate(pattern: [0, 400, 200, 400]);

    final message =
        'Alerta de desviación: Te has alejado ${deviationMeters.round()} metros '
        'de la ruta esperada. Verifica que estés en el bus correcto.';

    TtsService.instance.speak(message);
    onAlert?.call(message);
  }

  /// Calcular distancia entre dos puntos
  double _calculateDistance(LatLng point1, LatLng point2) {
    return Geolocator.distanceBetween(
      point1.latitude,
      point1.longitude,
      point2.latitude,
      point2.longitude,
    );
  }

  /// Obtener información del estado actual
  Map<String, dynamic> getCurrentStatus() {
    return {
      'isMonitoring': _isMonitoring,
      'destinationStopName': _destinationStopName,
      'destinationStop': _destinationStop != null ? {
        'latitude': _destinationStop!.latitude,
        'longitude': _destinationStop!.longitude,
      } : null,
      'finalDestinationName': _currentDestinationName,
      'finalDestination': _currentDestination != null ? {
        'latitude': _currentDestination!.latitude,
        'longitude': _currentDestination!.longitude,
      } : null,
      'expectedBusRoute': _expectedBusRoute,
      'approachingAlertGiven': _approachingAlertGiven,
      'nearAlertGiven': _nearAlertGiven,
      'veryNearAlertGiven': _veryNearAlertGiven,
    };
  }

  void dispose() {
    stopMonitoring();
  }
}
