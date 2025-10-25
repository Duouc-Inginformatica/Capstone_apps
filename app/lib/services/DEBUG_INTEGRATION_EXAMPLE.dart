// EJEMPLO DE INTEGRACIÓN DEL DEBUG DASHBOARD EN map_screen.dart
// Agrega estos imports al inicio del archivo:

import 'package:wayfindcl/services/debug_dashboard_service.dart';

// ============================================================================
// INICIALIZACIÓN
// ============================================================================
// En el initState() o en el onMount del mapa:

@override
void initState() {
  super.initState();
  
  // Inicializar el servicio de debug dashboard
  DebugDashboardService.initialize();
  
  // ... resto del código
}

// ============================================================================
// EJEMPLOS DE USO EN DIFERENTES EVENTOS
// ============================================================================

// 1. Al iniciar navegación:
void _startNavigation() {
  // ... código existente ...
  
  DebugDashboardService.sendNavigationEvent(
    eventType: 'navigation_start',
    totalSteps: activeNav.steps.length,
    currentStep: 0,
    currentLat: _currentPosition?.latitude,
    currentLng: _currentPosition?.longitude,
  );
  
  DebugDashboardService.info(
    'Navegación iniciada',
    {
      'origin': '${origin.latitude}, ${origin.longitude}',
      'destination': '${destination.latitude}, ${destination.longitude}',
      'busRoute': activeNav.itinerary.redBusRoutes.join(', '),
    },
  );
}

// 2. Al avanzar de paso:
void _advanceToNextStep() {
  // ... código existente ...
  
  DebugDashboardService.sendNavigationEvent(
    eventType: 'step_completed',
    currentStep: activeNav.currentStepIndex,
    totalSteps: activeNav.steps.length,
    stopName: currentStep.stopName,
    busRoute: currentStep.busRoute,
  );
}

// 3. Al llegar al paradero:
void _onArrivalAtStop() {
  // ... código existente ...
  
  DebugDashboardService.sendNavigationEvent(
    eventType: 'stop_arrival',
    currentStep: activeNav.currentStepIndex,
    stopName: currentStep.stopName,
    busRoute: currentStep.busRoute,
    currentLat: _currentPosition?.latitude,
    currentLng: _currentPosition?.longitude,
  );
  
  DebugDashboardService.info(
    '🚏 Llegaste al paradero',
    {
      'stopName': currentStep.stopName,
      'busRoute': currentStep.busRoute,
    },
  );
}

// 4. Al subir al bus:
void _onBoardBus() {
  // ... código existente ...
  
  DebugDashboardService.sendNavigationEvent(
    eventType: 'bus_boarded',
    currentStep: activeNav.currentStepIndex,
    busRoute: currentStep.busRoute,
    stopName: currentStep.stopName,
  );
}

// 5. Durante ride_bus (cada N segundos):
void _updateBusProgress() {
  // ... código existente ...
  
  DebugDashboardService.sendNavigationEvent(
    eventType: 'bus_progress',
    currentStep: activeNav.currentStepIndex,
    busRoute: currentStep.busRoute,
    currentLat: _currentPosition?.latitude,
    currentLng: _currentPosition?.longitude,
    distanceRemaining: distanceToDestination,
  );
}

// 6. Al completar navegación:
void _completeNavigation() {
  // ... código existente ...
  
  DebugDashboardService.sendNavigationEvent(
    eventType: 'navigation_completed',
    currentStep: activeNav.steps.length - 1,
    totalSteps: activeNav.steps.length,
  );
  
  DebugDashboardService.info(
    '✅ Navegación completada exitosamente',
    {
      'duration': duration.toString(),
      'distance': totalDistance.toString(),
    },
  );
}

// 7. En caso de error:
void _handleNavigationError(dynamic error, StackTrace stackTrace) {
  DebugDashboardService.sendError(
    errorType: 'navigation_error',
    message: error.toString(),
    stackTrace: stackTrace.toString(),
    metadata: {
      'currentStep': activeNav?.currentStepIndex,
      'navigationActive': _isNavigating,
    },
  );
  
  DebugDashboardService.error(
    '❌ Error en navegación: $error',
    {'stackTrace': stackTrace.toString()},
  );
}

// 8. Métricas de GPS (periódicamente):
void _updateGPSMetrics() {
  if (_currentPosition != null) {
    DebugDashboardService.sendMetrics(
      gpsAccuracy: _currentPosition!.accuracy,
      navigationActive: _isNavigating,
    );
  }
}

// 9. Métricas de TTS:
Future<void> _speakWithMetrics(String text) async {
  final startTime = DateTime.now();
  
  await TtsService.instance.speak(text);
  
  final responseTime = DateTime.now().difference(startTime).inMilliseconds;
  DebugDashboardService.sendMetrics(
    ttsResponseTime: responseTime,
    navigationActive: _isNavigating,
  );
}

// 10. Logs de markers (ejemplo de depuración):
void _updateNavigationMarkers() {
  // ... código existente ...
  
  DebugDashboardService.debug(
    '🗺️ Markers actualizados',
    {
      'totalMarkers': _markers.length,
      'currentStep': activeNav?.currentStep?.type,
      'isRidingBus': activeNav?.currentStep?.type == 'ride_bus',
    },
  );
}

// ============================================================================
// INTEGRACIÓN EN EL SIMULADOR
// ============================================================================

void _simulateNavigation() async {
  // ... código existente ...
  
  // Al iniciar simulación
  DebugDashboardService.sendEvent(
    eventType: 'simulation_start',
    metadata: {
      'currentStep': activeNav.currentStepIndex,
      'stepType': currentStep.type,
    },
  );
  
  // Por cada punto simulado
  for (var i = 0; i < geometry.length; i++) {
    // ... código de simulación ...
    
    if (i % 10 == 0) { // Cada 10 puntos
      DebugDashboardService.sendNavigationEvent(
        eventType: 'simulation_progress',
        currentStep: activeNav.currentStepIndex,
        currentLat: geometry[i].latitude,
        currentLng: geometry[i].longitude,
      );
    }
  }
}

// ============================================================================
// NOTAS DE IMPLEMENTACIÓN
// ============================================================================
/*
1. El servicio se inicializa automáticamente y detecta si el dashboard está habilitado
2. Todos los métodos son silenciosos - no interrumpen la app si hay errores
3. Los logs se envían de forma asíncrona sin bloquear la UI
4. Se incluye automáticamente el userId si está disponible
5. Los eventos se pueden filtrar y buscar en el dashboard web

EVENTOS SUGERIDOS:
- navigation_start: Inicio de navegación
- step_completed: Paso completado
- stop_arrival: Llegada a paradero
- bus_boarded: Subida al bus
- bus_progress: Progreso durante viaje en bus
- navigation_completed: Navegación completada
- simulation_start: Inicio de simulación
- simulation_progress: Progreso de simulación
- navigation_error: Error durante navegación

NIVELES DE LOG:
- debug: Información detallada para debugging
- info: Información general
- warn: Advertencias
- error: Errores
*/
