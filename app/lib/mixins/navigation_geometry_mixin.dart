// ============================================================================
// Navigation Geometry Mixin - WayFindCL
// ============================================================================
// Mixin centralizado para gestionar toda la lógica de geometrías de navegación
// - Obtención de geometrías desde backend
// - Dibujado de polilíneas (walk: roja, bus: roja)
// - Gestión de marcadores
// - Coherencia en toda la app
// ============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../services/navigation/integrated_navigation_service.dart';
import '../services/backend/bus_geometry_service.dart';
import '../services/polyline_compression.dart';
import '../services/debug_logger.dart';

/// Mixin para gestionar geometrías de navegación de forma centralizada
mixin NavigationGeometryMixin<T extends StatefulWidget> on State<T> {
  // ══════════════════════════════════════════════════════════════════════
  // ESTADO INTERNO DEL MIXIN
  // ══════════════════════════════════════════════════════════════════════
  
  /// Polilíneas activas en el mapa
  List<Polyline> _navigationPolylines = [];
  
  /// Caché de geometría del paso actual
  List<LatLng> _cachedGeometry = [];
  int _cachedStepIndex = -1;
  
  // ══════════════════════════════════════════════════════════════════════
  // GETTERS PÚBLICOS
  // ══════════════════════════════════════════════════════════════════════
  
  /// Obtiene las polilíneas actuales para mostrar en el mapa
  List<Polyline> get navigationPolylines => _navigationPolylines;
  
  // ══════════════════════════════════════════════════════════════════════
  // MÉTODO PRINCIPAL: ACTUALIZAR GEOMETRÍA
  // ══════════════════════════════════════════════════════════════════════
  
  /// Actualiza la geometría del mapa según el paso actual de navegación
  /// 
  /// Este es el ÚNICO punto de entrada para actualizar geometrías
  /// Garantiza coherencia en toda la app
  Future<void> updateNavigationGeometry({
    required ActiveNavigation navigation,
    bool forceRefresh = false,
  }) async {
    final currentStep = navigation.currentStep;
    if (currentStep == null) {
      _clearGeometry();
      return;
    }
    
    final stepType = currentStep.type;
    final currentIndex = navigation.currentStepIndex;
    
    DebugLogger.info(
      '🗺️ [GEOMETRY] Actualizando geometría: paso $currentIndex ($stepType)',
      context: 'NavigationGeometryMixin',
    );
    
    // ══════════════════════════════════════════════════════════════════
    // LÓGICA SEGÚN TIPO DE PASO
    // ══════════════════════════════════════════════════════════════════
    
    switch (stepType) {
      case 'walk':
        await _updateWalkGeometry(navigation, currentIndex, forceRefresh);
        break;
        
      case 'wait_bus':
        _updateWaitBusGeometry();
        break;
        
      case 'ride_bus':
        await _updateRideBusGeometry(navigation, currentIndex, forceRefresh);
        break;
        
      default:
        DebugLogger.warning(
          'Tipo de paso desconocido: $stepType',
          context: 'NavigationGeometryMixin',
        );
        _clearGeometry();
    }
  }
  
  // ══════════════════════════════════════════════════════════════════════
  // LÓGICA POR TIPO DE PASO
  // ══════════════════════════════════════════════════════════════════════
  
  /// Actualiza geometría para paso de caminata
  Future<void> _updateWalkGeometry(
    ActiveNavigation navigation,
    int stepIndex,
    bool forceRefresh,
  ) async {
    // Usar caché si no cambió el paso
    if (!forceRefresh && _cachedStepIndex == stepIndex && _cachedGeometry.isNotEmpty) {
      _drawWalkPolyline(_cachedGeometry);
      DebugLogger.info(
        '💾 [GEOMETRY] Usando geometría cacheada (${_cachedGeometry.length} puntos)',
        context: 'NavigationGeometryMixin',
      );
      return;
    }
    
    // Obtener geometría del paso actual
    final geometry = IntegratedNavigationService.instance.currentStepGeometry;
    
    if (geometry.isEmpty) {
      DebugLogger.warning(
        'Geometría vacía para paso walk',
        context: 'NavigationGeometryMixin',
      );
      _clearGeometry();
      return;
    }
    
    // Comprimir si tiene muchos puntos
    final compressed = _compressGeometryIfNeeded(geometry);
    
    // Actualizar caché
    _cachedGeometry = compressed;
    _cachedStepIndex = stepIndex;
    
    // Dibujar polilínea roja
    _drawWalkPolyline(compressed);
    
    DebugLogger.success(
      '✅ [GEOMETRY] Geometría walk actualizada (${compressed.length} puntos)',
      context: 'NavigationGeometryMixin',
    );
  }
  
  /// Actualiza geometría para paso de espera de bus
  void _updateWaitBusGeometry() {
    // NO mostrar geometría mientras espera el bus
    // Solo cuando confirme que subió (pasa a ride_bus)
    _clearGeometry();
    
    DebugLogger.info(
      '🚏 [GEOMETRY] Wait bus: geometría limpia (esperando confirmación)',
      context: 'NavigationGeometryMixin',
    );
  }
  
  /// Actualiza geometría para viaje en bus
  Future<void> _updateRideBusGeometry(
    ActiveNavigation navigation,
    int stepIndex,
    bool forceRefresh,
  ) async {
    // Usar caché si no cambió el paso
    if (!forceRefresh && _cachedStepIndex == stepIndex && _cachedGeometry.isNotEmpty) {
      _drawBusPolyline(_cachedGeometry);
      DebugLogger.info(
        '💾 [GEOMETRY] Usando geometría bus cacheada (${_cachedGeometry.length} puntos)',
        context: 'NavigationGeometryMixin',
      );
      return;
    }
    
    // ══════════════════════════════════════════════════════════════════
    // ESTRATEGIA: Obtener geometría exacta desde backend
    // ══════════════════════════════════════════════════════════════════
    
    List<LatLng> busGeometry = [];
    
    // 1. Intentar desde backend (GTFS shapes - MÁS PRECISO)
    busGeometry = await _fetchBusGeometryFromBackend(navigation);
    
    // 2. Fallback: Usar geometría del itinerario
    if (busGeometry.isEmpty) {
      busGeometry = _getBusGeometryFromItinerary(navigation);
    }
    
    // 3. Validar que la geometría sea válida
    if (busGeometry.isEmpty) {
      DebugLogger.error(
        'No se pudo obtener geometría del bus',
        context: 'NavigationGeometryMixin',
      );
      _clearGeometry();
      return;
    }
    
    // Comprimir si es necesario
    final compressed = _compressGeometryIfNeeded(busGeometry);
    
    // Actualizar caché
    _cachedGeometry = compressed;
    _cachedStepIndex = stepIndex;
    
    // Dibujar polilínea roja (mismo color que walk para coherencia)
    _drawBusPolyline(compressed);
    
    DebugLogger.success(
      '✅ [GEOMETRY] Geometría bus actualizada (${compressed.length} puntos)',
      context: 'NavigationGeometryMixin',
    );
  }
  
  // ══════════════════════════════════════════════════════════════════════
  // OBTENCIÓN DE GEOMETRÍAS DE BUS
  // ══════════════════════════════════════════════════════════════════════
  
  /// Obtiene geometría del bus desde el backend (GTFS shapes)
  Future<List<LatLng>> _fetchBusGeometryFromBackend(ActiveNavigation navigation) async {
    try {
      final currentStep = navigation.currentStep!;
      final previousStep = navigation.currentStepIndex > 0
          ? navigation.steps[navigation.currentStepIndex - 1]
          : null;
      
      final busRoute = currentStep.busRoute;
      final fromStopId = previousStep?.stopId; // Paradero de subida
      final toStopId = currentStep.stopId; // Paradero de bajada
      
      if (busRoute == null || fromStopId == null || toStopId == null) {
        DebugLogger.warning(
          'Datos insuficientes para obtener geometría desde backend',
          context: 'NavigationGeometryMixin',
        );
        return [];
      }
      
      DebugLogger.info(
        '🌐 [GEOMETRY] Solicitando geometría al backend: Ruta $busRoute ($fromStopId → $toStopId)',
        context: 'NavigationGeometryMixin',
      );
      
      final result = await BusGeometryService.instance.getBusSegmentGeometry(
        routeNumber: busRoute,
        fromStopCode: fromStopId,
        toStopCode: toStopId,
        fromLat: previousStep?.location?.latitude,
        fromLon: previousStep?.location?.longitude,
        toLat: currentStep.location?.latitude,
        toLon: currentStep.location?.longitude,
      );
      
      if (result != null && BusGeometryService.instance.isValidGeometry(result.geometry)) {
        DebugLogger.success(
          '✅ [GEOMETRY] Geometría obtenida desde backend (${result.source})',
          context: 'NavigationGeometryMixin',
        );
        DebugLogger.info(
          '   Puntos: ${result.geometry.length}, Distancia: ${result.distanceMeters.toStringAsFixed(0)}m',
          context: 'NavigationGeometryMixin',
        );
        return result.geometry;
      }
      
      DebugLogger.warning(
        'Backend no retornó geometría válida',
        context: 'NavigationGeometryMixin',
      );
      return [];
    } catch (e, stackTrace) {
      DebugLogger.error(
        'Error obteniendo geometría desde backend: $e',
        context: 'NavigationGeometryMixin',
        error: e,
        stackTrace: stackTrace,
      );
      return [];
    }
  }
  
  /// Obtiene geometría del bus desde el itinerario (fallback)
  List<LatLng> _getBusGeometryFromItinerary(ActiveNavigation navigation) {
    try {
      final busLeg = navigation.itinerary.legs.firstWhere(
        (leg) => leg.type == 'bus' && leg.isRedBus,
        orElse: () => throw Exception('No bus leg found'),
      );
      
      final geometry = busLeg.geometry ?? [];
      
      if (geometry.isEmpty) {
        DebugLogger.warning(
          'Geometría vacía en itinerario',
          context: 'NavigationGeometryMixin',
        );
        return [];
      }
      
      DebugLogger.info(
        '🔄 [GEOMETRY] Usando geometría del itinerario (${geometry.length} puntos)',
        context: 'NavigationGeometryMixin',
      );
      
      return geometry;
    } catch (e) {
      DebugLogger.error(
        'Error obteniendo geometría del itinerario: $e',
        context: 'NavigationGeometryMixin',
      );
      return [];
    }
  }
  
  // ══════════════════════════════════════════════════════════════════════
  // COMPRESIÓN DE GEOMETRÍAS
  // ══════════════════════════════════════════════════════════════════════
  
  /// Comprime geometría si tiene muchos puntos (optimización)
  List<LatLng> _compressGeometryIfNeeded(List<LatLng> geometry) {
    if (geometry.length <= 50) {
      return geometry; // No comprimir si es pequeña
    }
    
    // Epsilon adaptativo según cantidad de puntos
    double epsilon;
    if (geometry.length > 500) {
      epsilon = 0.0002; // Más compresión para rutas muy largas
    } else if (geometry.length > 200) {
      epsilon = 0.00015;
    } else {
      epsilon = 0.0001; // Compresión mínima
    }
    
    final compressed = PolylineCompression.compress(
      points: geometry,
      epsilon: epsilon,
    );
    
    final reduction = ((1 - compressed.length / geometry.length) * 100);
    
    DebugLogger.info(
      '🗜️ [GEOMETRY] Compresión: ${geometry.length} → ${compressed.length} pts (${reduction.toStringAsFixed(1)}%)',
      context: 'NavigationGeometryMixin',
    );
    
    return compressed;
  }
  
  // ══════════════════════════════════════════════════════════════════════
  // DIBUJADO DE POLILÍNEAS
  // ══════════════════════════════════════════════════════════════════════
  
  /// Dibuja polilínea roja para caminata
  void _drawWalkPolyline(List<LatLng> geometry) {
    _navigationPolylines = [
      Polyline(
        points: geometry,
        color: const Color(0xFFE30613), // Rojo RED
        strokeWidth: 5.0,
      ),
    ];
    
    DebugLogger.info(
      '🎨 [GEOMETRY] Polilínea WALK dibujada (${geometry.length} puntos)',
      context: 'NavigationGeometryMixin',
    );
  }
  
  /// Dibuja polilínea roja para bus (mismo color que walk para coherencia)
  void _drawBusPolyline(List<LatLng> geometry) {
    _navigationPolylines = [
      Polyline(
        points: geometry,
        color: const Color(0xFFE30613), // Rojo RED (coherente con walk)
        strokeWidth: 5.0,
      ),
    ];
    
    DebugLogger.info(
      '🎨 [GEOMETRY] Polilínea BUS dibujada (${geometry.length} puntos)',
      context: 'NavigationGeometryMixin',
    );
  }
  
  /// Limpia todas las polilíneas
  void _clearGeometry() {
    _navigationPolylines = [];
    
    DebugLogger.info(
      '🧹 [GEOMETRY] Geometría limpiada',
      context: 'NavigationGeometryMixin',
    );
  }
  
  // ══════════════════════════════════════════════════════════════════════
  // UTILIDADES
  // ══════════════════════════════════════════════════════════════════════
  
  /// Limpia el caché de geometrías
  void clearGeometryCache() {
    _cachedGeometry = [];
    _cachedStepIndex = -1;
    
    DebugLogger.info(
      '🗑️ [GEOMETRY] Caché limpiado',
      context: 'NavigationGeometryMixin',
    );
  }
  
  /// Obtiene la geometría cacheada actual (para uso en simulación, etc.)
  List<LatLng> get cachedGeometry => _cachedGeometry;
}
