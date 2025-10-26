// ============================================================================
// CUSTOM NOTIFICATIONS SERVICE - Sprint 6 CAP-32
// ============================================================================
// Sistema de notificaciones personalizables:
// - Distancia personalizada para alertas
// - Tipos de alerta configurables (audio, vibración, visual)
// - Preferencias de usuario
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import '../device/tts_service.dart';
import '../device/haptic_feedback_service.dart';
import '../debug_logger.dart';

enum NotificationType { audio, vibration, visual, all }

enum NotificationPriority { low, medium, high, critical }

class NotificationPreferences {
  NotificationPreferences({
    this.approachingDistance = 300,
    this.nearDistance = 150,
    this.veryNearDistance = 50,
    this.enableAudio = true,
    this.enableVibration = true,
    this.enableVisual = true,
    this.audioVolume = 1.0,
    this.vibrationIntensity = 1.0,
    this.minimumPriority = NotificationPriority.low,
  });

  double approachingDistance; // metros
  double nearDistance;
  double veryNearDistance;
  bool enableAudio;
  bool enableVibration;
  bool enableVisual;
  double audioVolume; // 0.0 - 1.0
  double vibrationIntensity; // 0.0 - 1.0 (afecta duración)
  NotificationPriority minimumPriority;

  Map<String, dynamic> toJson() => {
    'approachingDistance': approachingDistance,
    'nearDistance': nearDistance,
    'veryNearDistance': veryNearDistance,
    'enableAudio': enableAudio,
    'enableVibration': enableVibration,
    'enableVisual': enableVisual,
    'audioVolume': audioVolume,
    'vibrationIntensity': vibrationIntensity,
    'minimumPriority': minimumPriority.index,
  };

  factory NotificationPreferences.fromJson(Map<String, dynamic> json) {
    return NotificationPreferences(
      approachingDistance:
          (json['approachingDistance'] as num?)?.toDouble() ?? 300,
      nearDistance: (json['nearDistance'] as num?)?.toDouble() ?? 150,
      veryNearDistance: (json['veryNearDistance'] as num?)?.toDouble() ?? 50,
      enableAudio: json['enableAudio'] as bool? ?? true,
      enableVibration: json['enableVibration'] as bool? ?? true,
      enableVisual: json['enableVisual'] as bool? ?? true,
      audioVolume: (json['audioVolume'] as num?)?.toDouble() ?? 1.0,
      vibrationIntensity:
          (json['vibrationIntensity'] as num?)?.toDouble() ?? 1.0,
      minimumPriority:
          NotificationPriority.values[json['minimumPriority'] as int? ?? 0],
    );
  }
}

class CustomNotification {
  CustomNotification({
    required this.id,
    required this.title,
    required this.message,
    required this.priority,
    this.type = NotificationType.all,
    this.vibrationPattern,
    this.requiresUserAction = false,
  });

  final String id;
  final String title;
  final String message;
  final NotificationPriority priority;
  final NotificationType type;
  final List<int>? vibrationPattern;
  final bool requiresUserAction;

  String get fullMessage => '$title. $message';
}

class CustomNotificationsService {
  static final CustomNotificationsService instance =
      CustomNotificationsService._();
  CustomNotificationsService._();

  static const String _prefsKey = 'notification_preferences';

  NotificationPreferences _preferences = NotificationPreferences();
  final List<CustomNotification> _notificationHistory = [];
  final Map<String, DateTime> _lastNotificationTime = {};

  // Streams para notificaciones
  final _notificationController =
      StreamController<CustomNotification>.broadcast();
  Stream<CustomNotification> get notificationStream =>
      _notificationController.stream;

  // Callback para UI
  Function(CustomNotification)? onNotification;

  Timer? _monitoringTimer;
  LatLng? _targetLocation;
  String? _targetName;

  /// Cargar preferencias guardadas
  Future<void> loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_prefsKey);

      if (json != null) {
        final decoded = jsonDecode(json);
        if (decoded is Map<String, dynamic>) {
          _preferences = NotificationPreferences.fromJson(decoded);
        }
      }
    } catch (e) {
      DebugLogger.error('[CustomNotificationsService] Error loading notification preferences: $e');
    }
  }

  /// Guardar preferencias
  Future<void> savePreferences(NotificationPreferences preferences) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _preferences = preferences;

      final payload = jsonEncode({
        'approachingDistance': preferences.approachingDistance,
        'nearDistance': preferences.nearDistance,
        'veryNearDistance': preferences.veryNearDistance,
        'enableAudio': preferences.enableAudio,
        'enableVibration': preferences.enableVibration,
        'enableVisual': preferences.enableVisual,
        'audioVolume': preferences.audioVolume,
        'vibrationIntensity': preferences.vibrationIntensity,
        'minimumPriority': preferences.minimumPriority.index,
      });

      await prefs.setString(_prefsKey, payload);
    } catch (e) {
      DebugLogger.error('[CustomNotificationsService] Error saving notification preferences: $e');
    }
  }

  /// Obtener preferencias actuales
  NotificationPreferences getPreferences() => _preferences;

  /// Enviar notificación
  Future<void> notify(CustomNotification notification) async {
    // Verificar prioridad mínima
    if (notification.priority.index < _preferences.minimumPriority.index) {
      return;
    }

    // Prevenir spam (máximo 1 notificación del mismo tipo cada 5 segundos)
    final now = DateTime.now();
    if (_lastNotificationTime.containsKey(notification.id)) {
      final lastTime = _lastNotificationTime[notification.id]!;
      if (now.difference(lastTime).inSeconds < 5) {
        return;
      }
    }
    _lastNotificationTime[notification.id] = now;

    // Agregar a historial
    _notificationHistory.insert(0, notification);
    if (_notificationHistory.length > 50) {
      _notificationHistory.removeRange(50, _notificationHistory.length);
    }

    // Ejecutar según tipo y preferencias
    if (_shouldPlayAudio(notification)) {
      await _playAudio(notification);
    }

    if (_shouldVibrate(notification)) {
      await _vibrate(notification);
    }

    if (_shouldShowVisual(notification)) {
      _showVisual(notification);
    }

    // Emitir evento
    _notificationController.add(notification);
    onNotification?.call(notification);
  }

  /// Iniciar monitoreo de proximidad a ubicación
  Future<void> startProximityMonitoring({
    required LatLng targetLocation,
    String? targetName,
    Duration checkInterval = const Duration(seconds: 5),
  }) async {
    _targetLocation = targetLocation;
    _targetName = targetName ?? 'destino';

    _monitoringTimer?.cancel();
    _monitoringTimer = Timer.periodic(checkInterval, (_) async {
      await _checkProximity();
    });
  }

  /// Detener monitoreo
  void stopProximityMonitoring() {
    _monitoringTimer?.cancel();
    _monitoringTimer = null;
    _targetLocation = null;
    _targetName = null;
  }

  /// Obtener historial de notificaciones
  List<CustomNotification> getHistory({int limit = 10}) {
    return _notificationHistory.take(limit).toList();
  }

  /// Limpiar historial
  void clearHistory() {
    _notificationHistory.clear();
  }

  // ============================================================================
  // MÉTODOS PRIVADOS
  // ============================================================================

  Future<void> _checkProximity() async {
    if (_targetLocation == null) return;

    try {
      final position = await Geolocator.getCurrentPosition();
      final currentLocation = LatLng(position.latitude, position.longitude);

      const distance = Distance();
      final distanceMeters = distance.as(
        LengthUnit.Meter,
        currentLocation,
        _targetLocation!,
      );

      // Verificar distancias configuradas
      if (distanceMeters <= _preferences.veryNearDistance) {
        await notify(
          CustomNotification(
            id: 'very_near',
            title: 'Muy cerca de $_targetName',
            message: 'Estás a ${distanceMeters.round()} metros. ¡Prepárate!',
            priority: NotificationPriority.high,
            vibrationPattern: [0, 300, 100, 300, 100, 300],
          ),
        );
      } else if (distanceMeters <= _preferences.nearDistance) {
        await notify(
          CustomNotification(
            id: 'near',
            title: 'Cerca de $_targetName',
            message: 'Estás a ${distanceMeters.round()} metros',
            priority: NotificationPriority.medium,
            vibrationPattern: [0, 200, 100, 200],
          ),
        );
      } else if (distanceMeters <= _preferences.approachingDistance) {
        await notify(
          CustomNotification(
            id: 'approaching',
            title: 'Acercándose a $_targetName',
            message: 'Estás a ${distanceMeters.round()} metros',
            priority: NotificationPriority.low,
            vibrationPattern: [0, 200],
          ),
        );
      }
    } catch (e) {
      DebugLogger.error('[CustomNotificationsService] Error checking proximity: $e');
    }
  }

  bool _shouldPlayAudio(CustomNotification notification) {
    return _preferences.enableAudio &&
        (notification.type == NotificationType.audio ||
            notification.type == NotificationType.all);
  }

  bool _shouldVibrate(CustomNotification notification) {
    return _preferences.enableVibration &&
        (notification.type == NotificationType.vibration ||
            notification.type == NotificationType.all);
  }

  bool _shouldShowVisual(CustomNotification notification) {
    return _preferences.enableVisual &&
        (notification.type == NotificationType.visual ||
            notification.type == NotificationType.all);
  }

  Future<void> _playAudio(CustomNotification notification) async {
    final message = notification.fullMessage;
    await TtsService.instance.speak(message);
  }

  Future<void> _vibrate(CustomNotification notification) async {
    final haptic = HapticFeedbackService.instance;
    
    // Verificar si el servicio está habilitado
    if (!await haptic.hasVibrator()) return;

    // Aplicar intensidad configurada
    haptic.setIntensity(_preferences.vibrationIntensity);

    if (notification.vibrationPattern != null) {
      // Usar patrón personalizado de la notificación
      await haptic.vibrateCustomPattern(
        notification.vibrationPattern!,
      );
    } else {
      // Vibración por defecto basada en prioridad
      switch (notification.priority) {
        case NotificationPriority.low:
          await haptic.vibrateWithPattern(HapticPattern.medium);
          break;
        case NotificationPriority.medium:
          await haptic.vibrateWithPattern(HapticPattern.notification);
          break;
        case NotificationPriority.high:
          await haptic.vibrateWithPattern(HapticPattern.alert);
          break;
        case NotificationPriority.critical:
          await haptic.vibrateWithPattern(HapticPattern.success);
          break;
      }
    }
  }

  void _showVisual(CustomNotification notification) {
    // Este método será implementado en la UI
    // Aquí solo emitimos el evento para que la UI lo capture
    DebugLogger.info('[CustomNotificationsService] 📢 Visual Notification: ${notification.fullMessage}');
  }

  void dispose() {
    stopProximityMonitoring();
    _notificationController.close();
  }
}
