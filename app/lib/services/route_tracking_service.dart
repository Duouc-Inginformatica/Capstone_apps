import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:vibration/vibration.dart';
import 'tts_service.dart';

/// CAP-30: Seguimiento en tiempo real del usuario durante el viaje
/// CAP-20: Recalcular ruta si me desvío
class RouteTrackingService {
  RouteTrackingService._internal();
  static final RouteTrackingService instance = RouteTrackingService._internal();

  // Estado del viaje
  bool _isTracking = false;
  List<LatLng> _plannedRoute = [];
  LatLng? _destination;
  String? _destinationName;
  Timer? _trackingTimer;

  // Configuración
  static const double _deviationThresholdMeters = 100; // Umbral de desviación
  static const Duration _trackingInterval = Duration(seconds: 10); // Cada 10s
  static const double _arrivedThresholdMeters = 50; // Umbral de llegada

  // Callbacks
  Function(Position)? onPositionUpdate;
  Function(double distanceToRoute, bool needsRecalculation)?
  onDeviationDetected;
  Function()? onDestinationReached;
  Function(String instruction)? onNextInstruction;

  bool get isTracking => _isTracking;
  LatLng? get destination => _destination;
  String? get destinationName => _destinationName;

  /// CAP-30: Iniciar seguimiento en tiempo real
  void startTracking({
    required List<LatLng> plannedRoute,
    required LatLng destination,
    required String destinationName,
  }) {
    _plannedRoute = plannedRoute;
    _destination = destination;
    _destinationName = destinationName;
    _isTracking = true;

    TtsService.instance.speak(
      'Iniciando seguimiento en tiempo real hacia $_destinationName. '
      'Te avisaré si te desvías de la ruta.',
    );

    _trackingTimer?.cancel();
    _trackingTimer = Timer.periodic(_trackingInterval, (_) => _checkPosition());

    // Primera verificación inmediata
    _checkPosition();
  }

  /// Detener seguimiento
  void stopTracking() {
    _isTracking = false;
    _trackingTimer?.cancel();
    _plannedRoute.clear();
    _destination = null;
    _destinationName = null;

    TtsService.instance.speak('Seguimiento detenido');
  }

  /// CAP-30 + CAP-20: Verificar posición y detectar desvíos
  Future<void> _checkPosition() async {
    if (!_isTracking || _destination == null) return;

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      final currentLocation = LatLng(position.latitude, position.longitude);

      // Notificar actualización de posición
      onPositionUpdate?.call(position);

      // CAP-30: Verificar si llegó al destino
      final distanceToDestination = _calculateDistance(
        currentLocation,
        _destination!,
      );

      if (distanceToDestination <= _arrivedThresholdMeters) {
        _handleArrival();
        return;
      }

      // CAP-20: Verificar desviación de la ruta
      if (_plannedRoute.isNotEmpty) {
        final distanceToRoute = _calculateDistanceToRoute(currentLocation);
        final needsRecalculation = distanceToRoute > _deviationThresholdMeters;

        if (needsRecalculation) {
          _handleDeviation(distanceToRoute);
        } else {
          // Dar feedback de progreso cada cierto tiempo
          _provideProgressUpdate(distanceToDestination);
        }

        onDeviationDetected?.call(distanceToRoute, needsRecalculation);
      }
    } catch (e) {
      TtsService.instance.speak('Error obteniendo ubicación actual');
    }
  }

  /// CAP-20: Manejar desviación de la ruta
  void _handleDeviation(double distanceToRoute) {
    Vibration.vibrate(pattern: [0, 200, 100, 200]); // Patrón de vibración

    TtsService.instance.speak(
      'Te has desviado ${distanceToRoute.round()} metros de la ruta planificada. '
      'Recalculando nueva ruta desde tu ubicación actual.',
    );

    onDeviationDetected?.call(distanceToRoute, true);
  }

  /// CAP-30: Notificar llegada al destino
  void _handleArrival() {
    Vibration.vibrate(pattern: [0, 500, 200, 500, 200, 500]); // Celebración

    TtsService.instance.speak(
      '¡Has llegado a $_destinationName! Viaje completado exitosamente.',
    );

    onDestinationReached?.call();
    stopTracking();
  }

  /// Proveer actualizaciones de progreso
  void _provideProgressUpdate(double distanceToDestination) {
    final distanceKm = (distanceToDestination / 1000).toStringAsFixed(1);
    final distanceM = distanceToDestination.round();

    String message;
    if (distanceToDestination > 1000) {
      message = 'Te encuentras a $distanceKm kilómetros de $_destinationName';
    } else if (distanceToDestination > 200) {
      message = 'Te encuentras a $distanceM metros de $_destinationName';
    } else {
      message =
          'Estás muy cerca de $_destinationName, a solo $distanceM metros';
    }

    TtsService.instance.speak(message);
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

  /// CAP-20: Calcular distancia mínima a la ruta planificada
  double _calculateDistanceToRoute(LatLng currentLocation) {
    if (_plannedRoute.isEmpty) return double.infinity;

    double minDistance = double.infinity;

    // Buscar el punto más cercano en la ruta
    for (final routePoint in _plannedRoute) {
      final distance = _calculateDistance(currentLocation, routePoint);
      if (distance < minDistance) {
        minDistance = distance;
      }
    }

    return minDistance;
  }

  /// CAP-12: Leer instrucción específica
  void readInstruction(String instruction) {
    TtsService.instance.speak(instruction);
  }

  /// CAP-12: Leer todas las instrucciones de la ruta
  void readAllInstructions(List<String> instructions) {
    if (instructions.isEmpty) {
      TtsService.instance.speak('No hay instrucciones disponibles');
      return;
    }

    final fullMessage =
        'Instrucciones para llegar a $_destinationName. '
        '${instructions.asMap().entries.map((e) => 'Paso ${e.key + 1}: ${e.value}').join('. ')}';

    TtsService.instance.speak(fullMessage);
  }

  /// Obtener siguiente instrucción basada en posición actual
  String? getNextInstruction(List<String> instructions, int currentStep) {
    if (currentStep >= 0 && currentStep < instructions.length) {
      return instructions[currentStep];
    }
    return null;
  }

  void dispose() {
    stopTracking();
  }
}
