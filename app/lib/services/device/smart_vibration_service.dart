// ============================================================================
// SMART VIBRATION SERVICE
// ============================================================================
// Proporciona patrones de vibración distintivos para diferentes eventos
// Ayuda a usuarios no videntes a identificar eventos sin mirar el teléfono
// ============================================================================

import 'package:vibration/vibration.dart';

/// Tipos de eventos que pueden generar vibraciones
enum VibrationType {
  /// Cambio de instrucción de navegación (1 vibración corta)
  instructionChange,
  
  /// Giro importante próximo - 50m de distancia (2 vibraciones cortas)
  nearTurn,
  
  /// Giro crítico - ejecutar ahora (3 vibraciones rápidas)
  criticalTurn,
  
  /// Llegada al destino (1 vibración larga)
  arrival,
  
  /// Bus llegando al paradero (patrón alternado)
  busBoarding,
  
  /// Metro llegando a estación (patrón distintivo más suave)
  metroBoarding,
  
  /// Usuario se desvió de la ruta (vibración intermitente)
  deviation,
  
  /// Confirmación exitosa (2 vibraciones muy cortas)
  success,
  
  /// Alerta importante (vibración continua)
  alert,
}

/// Patrones de vibración predefinidos (compatibilidad con HapticFeedbackService)
enum HapticPattern {
  light,
  medium,
  strong,
  notification,
  alert,
  warning,
  error,
  success,
  navigationCritical,
}

/// Servicio singleton para gestionar vibraciones inteligentes
class SmartVibrationService {
  SmartVibrationService._();
  static final SmartVibrationService instance = SmartVibrationService._();
  
  bool _isVibrationEnabled = true;
  double _intensity = 1.0;
  
  /// Habilitar o deshabilitar vibraciones globalmente
  void setEnabled(bool enabled) {
    _isVibrationEnabled = enabled;
  }
  
  /// Establece la intensidad de vibración (0.0 a 1.0)
  void setIntensity(double intensity) {
    if (intensity < 0.0 || intensity > 1.0) {
      throw ArgumentError('La intensidad debe estar entre 0.0 y 1.0');
    }
    _intensity = intensity;
  }
  
  /// Verifica si el dispositivo soporta vibración
  Future<bool> get hasVibrator async {
    try {
      final result = await Vibration.hasVibrator();
      return result == true;
    } catch (e) {
      return false;
    }
  }
  
  /// Ejecuta un patrón de vibración según el tipo de evento
  Future<void> vibrate(VibrationType type) async {
    if (!_isVibrationEnabled) return;
    
    final hasVib = await hasVibrator;
    if (!hasVib) return;
    
    try {
      switch (type) {
        case VibrationType.instructionChange:
          // 1 vibración corta - nueva instrucción
          await Vibration.vibrate(duration: 100);
          break;
          
        case VibrationType.nearTurn:
          // 2 vibraciones cortas - giro en 50m
          await Vibration.vibrate(duration: 100);
          await Future.delayed(const Duration(milliseconds: 150));
          await Vibration.vibrate(duration: 100);
          break;
          
        case VibrationType.criticalTurn:
          // 3 vibraciones rápidas - giro AHORA
          await Vibration.vibrate(duration: 150);
          await Future.delayed(const Duration(milliseconds: 100));
          await Vibration.vibrate(duration: 150);
          await Future.delayed(const Duration(milliseconds: 100));
          await Vibration.vibrate(duration: 150);
          break;
          
        case VibrationType.arrival:
          // 1 vibración larga - llegaste al destino
          await Vibration.vibrate(duration: 500);
          break;
          
        case VibrationType.busBoarding:
          // Patrón alternado - bus llegando
          await Vibration.vibrate(duration: 200);
          await Future.delayed(const Duration(milliseconds: 200));
          await Vibration.vibrate(duration: 200);
          await Future.delayed(const Duration(milliseconds: 200));
          await Vibration.vibrate(duration: 300);
          break;
          
        case VibrationType.metroBoarding:
          // Patrón más suave y continuo - metro llegando a estación
          // Diferente al bus para que el usuario pueda distinguir
          await Vibration.vibrate(duration: 150);
          await Future.delayed(const Duration(milliseconds: 150));
          await Vibration.vibrate(duration: 150);
          await Future.delayed(const Duration(milliseconds: 150));
          await Vibration.vibrate(duration: 250);
          break;
          
        case VibrationType.deviation:
          // Vibración intermitente - desviación de ruta
          for (int i = 0; i < 4; i++) {
            await Vibration.vibrate(duration: 100);
            await Future.delayed(const Duration(milliseconds: 100));
          }
          break;
          
        case VibrationType.success:
          // 2 vibraciones muy cortas - confirmación
          await Vibration.vibrate(duration: 50);
          await Future.delayed(const Duration(milliseconds: 100));
          await Vibration.vibrate(duration: 50);
          break;
          
        case VibrationType.alert:
          // Vibración continua - alerta importante
          await Vibration.vibrate(duration: 1000);
          break;
      }
    } catch (e) {
      // Error de vibración - dispositivo no compatible
      // No hacer nada, la app debe seguir funcionando
    }
  }
  
  /// Vibración simple para compatibilidad con código existente
  Future<void> simple({int duration = 200}) async {
    if (!_isVibrationEnabled) return;
    
    final hasVib = await hasVibrator;
    if (!hasVib) return;
    
    try {
      await Vibration.vibrate(duration: duration);
    } catch (e) {
      // Ignorar errores de vibración
    }
  }
  
  // ========== Métodos de compatibilidad con HapticFeedbackService ==========
  
  /// Vibra con un patrón personalizado (para compatibilidad)
  Future<void> vibrateCustomPattern(List<int> pattern) async {
    if (!_isVibrationEnabled) return;
    
    final hasVib = await hasVibrator;
    if (!hasVib) return;
    
    try {
      await Vibration.vibrate(pattern: pattern);
    } catch (e) {
      // Ignorar errores de vibración
    }
  }
  
  /// Vibra con un patrón predefinido (compatibilidad con HapticFeedbackService)
  Future<void> vibrateWithPattern(HapticPattern pattern) async {
    if (!_isVibrationEnabled) return;
    
    final hasVib = await hasVibrator;
    if (!hasVib) return;
    
    try {
      switch (pattern) {
        case HapticPattern.light:
          await Vibration.vibrate(duration: (120 * _intensity).round());
          break;
        case HapticPattern.medium:
          await Vibration.vibrate(duration: (200 * _intensity).round());
          break;
        case HapticPattern.strong:
          await Vibration.vibrate(duration: (300 * _intensity).round());
          break;
        case HapticPattern.notification:
          await Vibration.vibrate(pattern: [0, 200, 100, 200]);
          break;
        case HapticPattern.alert:
          await Vibration.vibrate(pattern: [0, 300, 100, 300, 100, 300]);
          break;
        case HapticPattern.warning:
          await Vibration.vibrate(pattern: [0, 200, 100, 200, 100, 200]);
          break;
        case HapticPattern.error:
          await Vibration.vibrate(pattern: [0, 400, 200, 400]);
          break;
        case HapticPattern.success:
          await Vibration.vibrate(pattern: [0, 500, 200, 500, 200, 500]);
          break;
        case HapticPattern.navigationCritical:
          await Vibration.vibrate(pattern: [0, 500, 200, 500]);
          break;
      }
    } catch (e) {
      // Ignorar errores de vibración
    }
  }
  
  /// Feedback para inicio de navegación
  Future<void> navigationStart() => vibrate(VibrationType.instructionChange);
  
  /// Feedback ligero para notificaciones generales
  Future<void> lightNotification() => simple(duration: 100);
  
  /// Feedback para desviación de navegación crítica
  Future<void> navigationDeviationCritical() => vibrate(VibrationType.deviation);
}
