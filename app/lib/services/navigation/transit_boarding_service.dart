import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:vibration/vibration.dart';
import 'tts_service.dart';

/// CAP-29: Confirmación de micro abordada
/// Detecta cuando el usuario aborda un bus y confirma el número de línea
class TransitBoardingService {
  TransitBoardingService._internal();
  static final TransitBoardingService instance =
      TransitBoardingService._internal();

  // Estado del servicio
  bool _isMonitoring = false;
  String? _expectedBusRoute;
  Timer? _monitoringTimer;
  int _movingCount = 0;

  // Configuración
  static const double _boardingSpeedThreshold = 5.0; // m/s (~18 km/h)
  static const int _movingCountThreshold =
      3; // 3 lecturas consecutivas en movimiento
  static const Duration _monitoringInterval = Duration(seconds: 5);

  // Callbacks
  Function(String busRoute)? onBoardingConfirmed;
  Function()? onBoardingCancelled;

  bool get isMonitoring => _isMonitoring;
  String? get expectedBusRoute => _expectedBusRoute;

  /// CAP-29: Iniciar monitoreo de abordaje
  void startMonitoring({required String expectedBusRoute}) {
    _expectedBusRoute = expectedBusRoute;
    _isMonitoring = true;
    _movingCount = 0;

    TtsService.instance.speak(
      'Esperando confirmación de abordaje del bus $_expectedBusRoute. '
      'Te avisaré cuando detecte que has subido.',
    );

    _monitoringTimer?.cancel();
    _monitoringTimer = Timer.periodic(
      _monitoringInterval,
      (_) => _checkBoarding(),
    );
  }

  /// Detener monitoreo
  void stopMonitoring() {
    _isMonitoring = false;
    _monitoringTimer?.cancel();
    _expectedBusRoute = null;
    _movingCount = 0;
  }

  /// CAP-29: Verificar si el usuario ha abordado
  Future<void> _checkBoarding() async {
    if (!_isMonitoring) return;

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      final speed = position.speed; // m/s

      // Detectar movimiento consistente (indicador de estar en un bus)
      if (speed >= _boardingSpeedThreshold) {
        _movingCount++;

        if (_movingCount >= _movingCountThreshold) {
          _confirmBoarding();
        } else {
          TtsService.instance.speak(
            'Detectando movimiento. Confirma si ya subiste al bus $_expectedBusRoute',
          );
        }
      } else {
        // Resetear contador si se detiene
        if (_movingCount > 0) {
          _movingCount = 0;
          TtsService.instance.speak('Movimiento detenido. Esperando...');
        }
      }
    } catch (e) {
      // Error silencioso, continuará en próximo ciclo
    }
  }

  /// CAP-29: Confirmar abordaje exitoso
  void _confirmBoarding() {
    Vibration.vibrate(pattern: [0, 300, 100, 300]); // Confirmación háptica

    TtsService.instance.speak(
      '¡Confirmado! Has abordado el bus $_expectedBusRoute. '
      'Iniciando seguimiento de tu viaje.',
    );

    onBoardingConfirmed?.call(_expectedBusRoute!);
    stopMonitoring();
  }

  /// CAP-29: Confirmación manual del usuario por voz
  void confirmBoardingManually(String spokenRoute) {
    if (!_isMonitoring) return;

    final normalized = _normalizeRouteName(spokenRoute);
    final expected = _normalizeRouteName(_expectedBusRoute ?? '');

    if (normalized == expected ||
        spokenRoute.toLowerCase().contains('sí') ||
        spokenRoute.toLowerCase().contains('si') ||
        spokenRoute.toLowerCase().contains('confirmar')) {
      Vibration.vibrate(duration: 300);
      TtsService.instance.speak(
        'Perfecto, confirmado manualmente. Abordaste el bus $_expectedBusRoute',
      );

      onBoardingConfirmed?.call(_expectedBusRoute!);
      stopMonitoring();
    } else if (spokenRoute.toLowerCase().contains('no') ||
        spokenRoute.toLowerCase().contains('cancelar')) {
      TtsService.instance.speak('Confirmación cancelada. Seguiré esperando.');
      onBoardingCancelled?.call();
      stopMonitoring();
    }
  }

  /// Normalizar nombre de ruta para comparación
  String _normalizeRouteName(String route) {
    return route.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '').trim();
  }

  /// Solicitar confirmación manual
  void requestManualConfirmation() {
    TtsService.instance.speak(
      '¿Ya subiste al bus $_expectedBusRoute? Di sí para confirmar o no para cancelar.',
    );
  }

  void dispose() {
    stopMonitoring();
  }
}
