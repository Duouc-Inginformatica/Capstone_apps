import 'package:flutter/material.dart';
import '../../widgets/map/accessible_notification.dart';
import '../../services/device/tts_service.dart';
import '../../services/device/vibration_service.dart';

/// Mixin para el manejo de notificaciones y utilidades en la pantalla de mapa
mixin MapNotifications on State {
  // Campos requeridos
  List<NotificationData> get notifications;
  set notifications(List<NotificationData> value);
  
  void Function(VoidCallback fn) get setStateCallback;

  /// Muestra un anuncio de voz
  void announce(String message) {
    TtsService.instance.speak(message);
  }

  /// Muestra una notificación en pantalla
  void showNotification(NotificationData notification) {
    setStateCallback(() {
      notifications.add(notification);
    });

    // Auto-dismiss después de 3 segundos
    Future.delayed(const Duration(seconds: 3), () {
      dismissNotification(notification);
    });
  }

  /// Muestra una notificación de éxito
  void showSuccessNotification(String message, {bool withVibration = false}) {
    showNotification(NotificationData(
      message: message,
      type: NotificationType.success,
    ));
    if (withVibration) triggerVibration();
  }

  /// Muestra una notificación de error
  void showErrorNotification(String message, {bool withVibration = true}) {
    showNotification(NotificationData(
      message: message,
      type: NotificationType.error,
    ));
    if (withVibration) triggerVibration();
  }

  /// Muestra una notificación de navegación
  void showNavigationNotification(String message) {
    showNotification(NotificationData(
      message: message,
      type: NotificationType.navigation,
    ));
  }

  /// Muestra una notificación de advertencia
  void showWarningNotification(String message) {
    showNotification(NotificationData(
      message: message,
      type: NotificationType.warning,
    ));
  }

  /// Descarta una notificación
  void dismissNotification(NotificationData notification) {
    setStateCallback(() {
      notifications.remove(notification);
    });
  }

  /// Activa vibración háptica
  void triggerVibration() async {
    try {
      await VibrationService.instance.doubleVibration();
    } catch (e) {
      // Ignorar errores de vibración en dispositivos sin soporte
    }
  }
}