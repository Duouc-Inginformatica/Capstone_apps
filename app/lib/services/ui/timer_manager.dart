import 'dart:async';
import 'package:flutter/material.dart';

/// Gestor centralizado de timers para evitar memory leaks
/// 
/// Uso:
/// ```dart
/// class MyWidget extends StatefulWidget {
///   @override
///   State<MyWidget> createState() => _MyWidgetState();
/// }
/// 
/// class _MyWidgetState extends State<MyWidget> with TimerManagerMixin {
///   @override
///   void initState() {
///     super.initState();
///     
///     // Crear timer que se limpiará automáticamente
///     createTimer(
///       Duration(seconds: 5),
///       () => print('Timer ejecutado'),
///       name: 'my_timeout_timer',
///     );
///   }
///   
///   // dispose() se maneja automáticamente por el mixin
/// }
/// ```
class TimerManager {
  final Map<String, Timer> _timers = {};
  final Map<String, StreamSubscription> _subscriptions = {};

  /// Crea un timer con nombre único
  /// Si ya existe un timer con ese nombre, lo cancela y crea uno nuevo
  Timer createTimer(
    Duration duration,
    VoidCallback callback, {
    String? name,
  }) {
    final timerName = name ?? 'timer_${DateTime.now().millisecondsSinceEpoch}';
    
    // Cancelar timer existente con el mismo nombre
    _timers[timerName]?.cancel();
    
    final timer = Timer(duration, () {
      callback();
      _timers.remove(timerName);
    });
    
    _timers[timerName] = timer;
    return timer;
  }

  /// Crea un timer periódico con nombre único
  Timer createPeriodicTimer(
    Duration duration,
    void Function(Timer) callback, {
    String? name,
  }) {
    final timerName = name ?? 'periodic_${DateTime.now().millisecondsSinceEpoch}';
    
    // Cancelar timer existente con el mismo nombre
    _timers[timerName]?.cancel();
    
    final timer = Timer.periodic(duration, callback);
    
    _timers[timerName] = timer;
    return timer;
  }

  /// Cancela un timer específico por nombre
  void cancelTimer(String name) {
    _timers[name]?.cancel();
    _timers.remove(name);
  }

  /// Registra una subscription con nombre único
  /// Útil para streams, listeners, etc.
  void registerSubscription(
    String name,
    StreamSubscription subscription,
  ) {
    _subscriptions[name]?.cancel();
    _subscriptions[name] = subscription;
  }

  /// Cancela una subscription específica por nombre
  void cancelSubscription(String name) {
    _subscriptions[name]?.cancel();
    _subscriptions.remove(name);
  }

  /// Verifica si un timer está activo
  bool isTimerActive(String name) {
    return _timers[name]?.isActive ?? false;
  }

  /// Obtiene el número de timers activos
  int get activeTimersCount => _timers.length;

  /// Obtiene el número de subscriptions activas
  int get activeSubscriptionsCount => _subscriptions.length;

  /// Cancela todos los timers y subscriptions
  /// Debe llamarse en dispose()
  void dispose() {
    // Cancelar todos los timers
    for (var timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();

    // Cancelar todas las subscriptions
    for (var subscription in _subscriptions.values) {
      subscription.cancel();
    }
    _subscriptions.clear();
  }

  /// Lista los nombres de todos los timers activos (debug)
  List<String> get activeTimerNames => _timers.keys.toList();

  /// Lista los nombres de todas las subscriptions activas (debug)
  List<String> get activeSubscriptionNames => _subscriptions.keys.toList();
}

/// Mixin para usar TimerManager en StatefulWidgets
/// 
/// Proporciona gestión automática de timers y subscriptions
/// con limpieza automática en dispose()
mixin TimerManagerMixin<T extends StatefulWidget> on State<T> {
  final TimerManager _timerManager = TimerManager();

  /// Crea un timer que se limpiará automáticamente
  Timer createTimer(
    Duration duration,
    VoidCallback callback, {
    String? name,
  }) {
    return _timerManager.createTimer(duration, callback, name: name);
  }

  /// Crea un timer periódico que se limpiará automáticamente
  Timer createPeriodicTimer(
    Duration duration,
    void Function(Timer) callback, {
    String? name,
  }) {
    return _timerManager.createPeriodicTimer(duration, callback, name: name);
  }

  /// Cancela un timer específico
  void cancelTimer(String name) {
    _timerManager.cancelTimer(name);
  }

  /// Registra una subscription que se limpiará automáticamente
  void registerSubscription(String name, StreamSubscription subscription) {
    _timerManager.registerSubscription(name, subscription);
  }

  /// Cancela una subscription específica
  void cancelSubscription(String name) {
    _timerManager.cancelSubscription(name);
  }

  /// Verifica si un timer está activo
  bool isTimerActive(String name) {
    return _timerManager.isTimerActive(name);
  }

  /// Obtiene estadísticas de timers activos (debug)
  void debugTimerStats() {
    if (_timerManager.activeTimersCount > 0) {
      print('⏰ Timers activos: ${_timerManager.activeTimersCount}');
      print('   Nombres: ${_timerManager.activeTimerNames}');
    }
    if (_timerManager.activeSubscriptionsCount > 0) {
      print('📡 Subscriptions activas: ${_timerManager.activeSubscriptionsCount}');
      print('   Nombres: ${_timerManager.activeSubscriptionNames}');
    }
  }

  @override
  void dispose() {
    // Limpieza automática de todos los timers y subscriptions
    _timerManager.dispose();
    super.dispose();
  }
}
