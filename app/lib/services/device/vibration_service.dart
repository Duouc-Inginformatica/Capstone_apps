import 'package:vibration/vibration.dart';

/// Servicio centralizado para manejar vibraciones hápticas
/// Evita código duplicado y proporciona patrones de vibración predefinidos
class VibrationService {
  VibrationService._();
  static final VibrationService instance = VibrationService._();

  bool? _hasVibrator;

  /// Inicializa el servicio detectando si el dispositivo tiene vibrador
  Future<void> initialize() async {
    _hasVibrator = await Vibration.hasVibrator();
  }

  /// Vibración simple de confirmación
  Future<void> confirmation() async {
    _hasVibrator ??= await Vibration.hasVibrator();
    if (_hasVibrator == true) {
      await Vibration.vibrate(duration: 200);
    }
  }

  /// Vibración doble para llegadas importantes
  Future<void> doubleVibration() async {
    _hasVibrator ??= await Vibration.hasVibrator();
    if (_hasVibrator == true) {
      await Vibration.vibrate(duration: 150);
      await Future.delayed(const Duration(milliseconds: 200));
      await Vibration.vibrate(duration: 150);
    }
  }

  /// Vibración triple para completar ruta/destino
  Future<void> tripleVibration() async {
    _hasVibrator ??= await Vibration.hasVibrator();
    if (_hasVibrator == true) {
      await Vibration.vibrate(duration: 100);
      await Future.delayed(const Duration(milliseconds: 150));
      await Vibration.vibrate(duration: 100);
      await Future.delayed(const Duration(milliseconds: 150));
      await Vibration.vibrate(duration: 100);
    }
  }

  /// Vibración larga para errores o alertas
  Future<void> error() async {
    _hasVibrator ??= await Vibration.hasVibrator();
    if (_hasVibrator == true) {
      await Vibration.vibrate(duration: 300);
    }
  }

  /// Patrón de vibración personalizado
  /// Acepta duración simple o patrón complejo con intensidades
  Future<void> custom({
    int? duration,
    List<int>? pattern,
    List<int>? intensities,
  }) async {
    _hasVibrator ??= await Vibration.hasVibrator();
    if (_hasVibrator == true) {
      if (pattern != null && pattern.isNotEmpty) {
        // Solo pasar intensities si no es null y no está vacío
        if (intensities != null && intensities.isNotEmpty) {
          await Vibration.vibrate(
            pattern: pattern,
            intensities: intensities,
          );
        } else {
          await Vibration.vibrate(pattern: pattern);
        }
      } else if (duration != null) {
        await Vibration.vibrate(duration: duration);
      }
    }
  }

  /// Verificar si el dispositivo soporta vibración
  Future<bool> get hasVibrator async {
    _hasVibrator ??= await Vibration.hasVibrator();
    return _hasVibrator ?? false;
  }
}