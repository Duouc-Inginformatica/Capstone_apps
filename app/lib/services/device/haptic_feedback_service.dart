// ============================================================================
// HAPTIC FEEDBACK SERVICE - Centralización de Sistema de Vibración
// ============================================================================
// Servicio centralizado para gestionar toda la retroalimentación háptica
// de la aplicación con patrones predefinidos y configurables.
// ============================================================================

import 'package:vibration/vibration.dart';

/// Tipos de patrones de vibración predefinidos
enum HapticPattern {
  /// Vibración simple y corta (120ms) - para notificaciones ligeras
  light,
  
  /// Vibración media (200ms) - para confirmaciones
  medium,
  
  /// Vibración fuerte (300ms) - para alertas importantes
  strong,
  
  /// Patrón de notificación (200ms, pausa 100ms, 200ms)
  notification,
  
  /// Patrón de alerta (300ms, pausa 100ms, 300ms, pausa 100ms, 300ms)
  alert,
  
  /// Patrón de advertencia (200ms, pausa 100ms, 200ms, pausa 100ms, 200ms)
  warning,
  
  /// Patrón de error/desviación (400ms, pausa 200ms, 400ms)
  error,
  
  /// Patrón de éxito (500ms, pausa 200ms, 500ms, pausa 200ms, 500ms)
  success,
  
  /// Patrón de navegación crítica (500ms, pausa 200ms, 500ms)
  navigationCritical,
}

/// Servicio centralizado de retroalimentación háptica
class HapticFeedbackService {
  HapticFeedbackService._internal();
  static final HapticFeedbackService instance = HapticFeedbackService._internal();

  /// Cache del estado del vibrador del dispositivo
  bool? _hasVibrator;
  
  /// Indica si el servicio está habilitado globalmente
  bool _isEnabled = true;
  
  /// Intensidad global de vibración (0.0 a 1.0)
  double _intensity = 1.0;

  /// Obtiene si el servicio está habilitado
  bool get isEnabled => _isEnabled;
  
  /// Obtiene la intensidad actual
  double get intensity => _intensity;

  /// Habilita o deshabilita el servicio de vibración
  void setEnabled(bool enabled) {
    _isEnabled = enabled;
  }

  /// Establece la intensidad de vibración (0.0 a 1.0)
  void setIntensity(double intensity) {
    if (intensity < 0.0 || intensity > 1.0) {
      throw ArgumentError('La intensidad debe estar entre 0.0 y 1.0');
    }
    _intensity = intensity;
  }

  /// Verifica si el dispositivo tiene capacidad de vibración
  Future<bool> hasVibrator() async {
    if (_hasVibrator != null) {
      return _hasVibrator!;
    }

    try {
      _hasVibrator = await Vibration.hasVibrator() ?? false;
      return _hasVibrator!;
    } catch (e) {
      _hasVibrator = false;
      return false;
    }
  }

  /// Vibra con un patrón predefinido
  Future<void> vibrateWithPattern(
    HapticPattern pattern, {
    double? customIntensity,
  }) async {
    if (!_isEnabled) return;
    if (!await hasVibrator()) return;

    final effectiveIntensity = customIntensity ?? _intensity;
    
    try {
      switch (pattern) {
        case HapticPattern.light:
          await _vibrateDuration(120, effectiveIntensity);
          break;
          
        case HapticPattern.medium:
          await _vibrateDuration(200, effectiveIntensity);
          break;
          
        case HapticPattern.strong:
          await _vibrateDuration(300, effectiveIntensity);
          break;
          
        case HapticPattern.notification:
          await _vibratePattern(
            [0, 200, 100, 200],
            effectiveIntensity,
          );
          break;
          
        case HapticPattern.alert:
          await _vibratePattern(
            [0, 300, 100, 300, 100, 300],
            effectiveIntensity,
          );
          break;
          
        case HapticPattern.warning:
          await _vibratePattern(
            [0, 200, 100, 200, 100, 200],
            effectiveIntensity,
          );
          break;
          
        case HapticPattern.error:
          await _vibratePattern(
            [0, 400, 200, 400],
            effectiveIntensity,
          );
          break;
          
        case HapticPattern.success:
          await _vibratePattern(
            [0, 500, 200, 500, 200, 500],
            effectiveIntensity,
          );
          break;
          
        case HapticPattern.navigationCritical:
          await _vibratePattern(
            [0, 500, 200, 500],
            effectiveIntensity,
            intensities: [0, 255, 0, 255],
          );
          break;
      }
    } catch (e) {
      // Silenciar errores de vibración para no interrumpir la app
    }
  }

  /// Vibra con una duración específica
  Future<void> vibrate({
    int duration = 200,
    double? customIntensity,
  }) async {
    if (!_isEnabled) return;
    if (!await hasVibrator()) return;

    final effectiveIntensity = customIntensity ?? _intensity;
    await _vibrateDuration(duration, effectiveIntensity);
  }

  /// Vibra con un patrón personalizado
  /// 
  /// [pattern] - Array de duraciones en milisegundos
  /// El primer elemento es el delay antes de empezar
  /// Los elementos pares son pausas, los impares son vibraciones
  Future<void> vibrateCustomPattern(
    List<int> pattern, {
    double? customIntensity,
    List<int>? intensities,
  }) async {
    if (!_isEnabled) return;
    if (!await hasVibrator()) return;

    final effectiveIntensity = customIntensity ?? _intensity;
    await _vibratePattern(pattern, effectiveIntensity, intensities: intensities);
  }

  /// Detiene cualquier vibración en curso
  Future<void> cancel() async {
    try {
      await Vibration.cancel();
    } catch (e) {
      // Silenciar errores
    }
  }

  // ========== Métodos Privados ==========

  /// Vibra por una duración ajustada por intensidad
  Future<void> _vibrateDuration(int duration, double intensity) async {
    try {
      final adjustedDuration = (duration * intensity).round();
      if (adjustedDuration > 0) {
        await Vibration.vibrate(duration: adjustedDuration);
      }
    } catch (e) {
      // Silenciar errores
    }
  }

  /// Vibra con un patrón ajustado por intensidad
  Future<void> _vibratePattern(
    List<int> pattern,
    double intensity, {
    List<int>? intensities,
  }) async {
    try {
      final adjustedPattern = pattern.map((duration) {
        return (duration * intensity).round();
      }).toList();

      // Vibration.vibrate expects intensities as List<int>? (nullable) depending on platform
      if (intensities != null) {
        await Vibration.vibrate(
          pattern: adjustedPattern,
          intensities: intensities,
        );
      } else {
        await Vibration.vibrate(
          pattern: adjustedPattern,
        );
      }
    } catch (e) {
      // Silenciar errores
    }
  }

  // ========== Compatibilidad con llamadas existentes en MapScreen ==========
  /// Efecto de impacto medio
  Future<void> mediumImpact() async => vibrateWithPattern(HapticPattern.medium);

  /// Alerta rápida (alias)
  Future<void> alert() async => vibrateWithPattern(HapticPattern.alert);

  // ========== Métodos de Conveniencia ==========

  /// Feedback para inicio de navegación
  Future<void> navigationStart() => vibrateWithPattern(HapticPattern.medium);

  /// Feedback para aproximación a destino (300m)
  Future<void> approachingDestination() => vibrateWithPattern(HapticPattern.medium);

  /// Feedback para cercanía a destino (150m)
  Future<void> nearDestination() => vibrateWithPattern(HapticPattern.notification);

  /// Feedback para llegada a destino (50m)
  Future<void> arrivedAtDestination() => vibrateWithPattern(HapticPattern.alert);

  /// Feedback para alerta de bus correcto
  Future<void> correctBusAlert() => vibrateWithPattern(HapticPattern.warning);

  /// Feedback para desviación de ruta
  Future<void> routeDeviation() => vibrateWithPattern(HapticPattern.error);

  /// Feedback para desviación de navegación crítica
  Future<void> navigationDeviationCritical() => 
      vibrateWithPattern(HapticPattern.navigationCritical);

  /// Feedback ligero para notificaciones generales
  Future<void> lightNotification() => vibrateWithPattern(HapticPattern.light);

  /// Feedback de confirmación
  Future<void> confirmation() => vibrateWithPattern(HapticPattern.medium);

  /// Feedback de error
  Future<void> error() => vibrateWithPattern(HapticPattern.error);

  /// Feedback de éxito
  Future<void> success() => vibrateWithPattern(HapticPattern.success);
}
