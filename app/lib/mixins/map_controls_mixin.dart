import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../services/debug_logger.dart';

/// Mixin para gestión de controles del mapa (zoom, pan, rotation, centering)
/// 
/// Proporciona:
/// - Throttling de actualizaciones de mapa (100ms)
/// - Auto-centrado en ubicación del usuario
/// - Gestión de zoom adaptativo
/// - Control de rotación
/// - Animaciones suaves
/// 
/// Uso:
/// ```dart
/// class _MapScreenState extends State<MapScreen> 
///     with MapControlsMixin, TimerManagerMixin {
///   
///   @override
///   void initState() {
///     super.initState();
///     initMapControls();
///   }
/// }
/// ```
mixin MapControlsMixin<T extends StatefulWidget> on State<T> {
  // Debe ser implementado por el widget
  MapController get mapController;
  
  // Configuración
  static const Duration _throttleDuration = Duration(milliseconds: 100);
  static const double _defaultZoom = 17.0;
  static const double _minZoom = 10.0;
  static const double _maxZoom = 19.0;
  static const LatLng _defaultCenter = LatLng(-33.4489, -70.6693); // Santiago Centro

  // Estado interno
  Timer? _mapUpdateThrottle;
  bool _isMapReady = false;
  LatLng? _lastCenter;

  /// Inicializa los controles del mapa
  void initMapControls() {
    DebugLogger.info('🗺️ Inicializando controles del mapa', context: 'MapControls');
  }

  /// Marca el mapa como listo
  void markMapAsReady() {
    if (!mounted) return;
    setState(() {
      _isMapReady = true;
    });
    DebugLogger.success('✅ Mapa listo', context: 'MapControls');
  }

  /// Verifica si el mapa está listo
  bool get isMapReady => _isMapReady;

  /// Actualiza la posición del mapa con throttling
  /// 
  /// Evita actualizaciones excesivas que causan lag
  /// Máximo 10 FPS (cada 100ms)
  void updateMapPosition(
    LatLng position, {
    double? zoom,
    double? rotation,
    bool animated = true,
  }) {
    if (!_isMapReady) {
      DebugLogger.navigation('⚠️ Mapa no listo, guardando posición pendiente');
      // Guardar para aplicar cuando esté listo
      return;
    }

    // Throttling: solo actualizar cada 100ms
    if (_mapUpdateThrottle?.isActive ?? false) {
      return;
    }

    _mapUpdateThrottle = Timer(_throttleDuration, () {
      if (!mounted) return;

      try {
        final targetZoom = zoom ?? mapController.camera.zoom;
        final targetRotation = rotation ?? mapController.camera.rotation;

        if (animated) {
          mapController.move(position, targetZoom);
        } else {
          mapController.move(position, targetZoom);
        }

        _lastCenter = position;
      } catch (e) {
        DebugLogger.network('❌ Error actualizando mapa: $e');
      }
    });
  }

  /// Auto-centra el mapa en la ubicación del usuario
  void centerOnUserLocation(
    Position position, {
    double? zoom,
    bool animated = true,
  }) {
    final userLocation = LatLng(position.latitude, position.longitude);
    updateMapPosition(
      userLocation,
      zoom: zoom ?? _defaultZoom,
      animated: animated,
    );
  }

  /// Ajusta el zoom para mostrar dos puntos
  void fitBounds(
    LatLng point1,
    LatLng point2, {
    EdgeInsets padding = const EdgeInsets.all(50),
  }) {
    if (!_isMapReady) return;

    try {
      final bounds = LatLngBounds(point1, point2);
      mapController.fitCamera(
        CameraFit.bounds(
          bounds: bounds,
          padding: padding,
        ),
      );
    } catch (e) {
      DebugLogger.network('❌ Error ajustando bounds: $e');
    }
  }

  /// Ajusta el zoom para mostrar múltiples puntos
  void fitMultiplePoints(
    List<LatLng> points, {
    EdgeInsets padding = const EdgeInsets.all(50),
  }) {
    if (!_isMapReady || points.isEmpty) return;

    try {
      // Calcular bounds
      double minLat = points.first.latitude;
      double maxLat = points.first.latitude;
      double minLng = points.first.longitude;
      double maxLng = points.first.longitude;

      for (var point in points) {
        minLat = math.min(minLat, point.latitude);
        maxLat = math.max(maxLat, point.latitude);
        minLng = math.min(minLng, point.longitude);
        maxLng = math.max(maxLng, point.longitude);
      }

      final bounds = LatLngBounds(
        LatLng(minLat, minLng),
        LatLng(maxLat, maxLng),
      );

      mapController.fitCamera(
        CameraFit.bounds(
          bounds: bounds,
          padding: padding,
        ),
      );
    } catch (e) {
      DebugLogger.network('❌ Error ajustando múltiples puntos: $e');
    }
  }

  /// Hace zoom in (acercar)
  void zoomIn({bool animated = true}) {
    if (!_isMapReady) return;

    final currentZoom = mapController.camera.zoom;
    final newZoom = math.min(currentZoom + 1, _maxZoom);

    if (animated) {
      mapController.move(mapController.camera.center, newZoom);
    } else {
      mapController.move(mapController.camera.center, newZoom);
    }
  }

  /// Hace zoom out (alejar)
  void zoomOut({bool animated = true}) {
    if (!_isMapReady) return;

    final currentZoom = mapController.camera.zoom;
    final newZoom = math.max(currentZoom - 1, _minZoom);

    if (animated) {
      mapController.move(mapController.camera.center, newZoom);
    } else {
      mapController.move(mapController.camera.center, newZoom);
    }
  }

  /// Rota el mapa a un ángulo específico
  void rotateMap(double degrees) {
    if (!_isMapReady) return;

    try {
      mapController.rotate(degrees);
    } catch (e) {
      DebugLogger.network('❌ Error rotando mapa: $e');
    }
  }

  /// Resetea la rotación del mapa (norte arriba)
  void resetMapRotation() {
    rotateMap(0.0);
  }

  /// Obtiene el centro actual del mapa
  LatLng? get currentMapCenter {
    if (!_isMapReady) return null;
    return mapController.camera.center;
  }

  /// Obtiene el zoom actual del mapa
  double? get currentMapZoom {
    if (!_isMapReady) return null;
    return mapController.camera.zoom;
  }

  /// Obtiene la rotación actual del mapa
  double? get currentMapRotation {
    if (!_isMapReady) return null;
    return mapController.camera.rotation;
  }

  /// Calcula la distancia entre el centro actual y un punto
  double? distanceToPoint(LatLng point) {
    final center = currentMapCenter;
    if (center == null) return null;

    const distance = Distance();
    return distance.as(LengthUnit.Meter, center, point);
  }

  /// Verifica si un punto está visible en el viewport actual
  bool isPointVisible(LatLng point) {
    if (!_isMapReady) return false;

    try {
      final bounds = mapController.camera.visibleBounds;
      return bounds.contains(point);
    } catch (e) {
      return false;
    }
  }

  /// Obtiene el radio visible del mapa en metros
  double? get visibleRadius {
    if (!_isMapReady) return null;

    try {
      final bounds = mapController.camera.visibleBounds;
      final center = mapController.camera.center;

      const distance = Distance();
      return distance.as(
        LengthUnit.Meter,
        center,
        LatLng(bounds.north, bounds.east),
      );
    } catch (e) {
      return null;
    }
  }

  /// Anima la cámara a un punto específico
  Future<void> animateToPoint(
    LatLng point, {
    double? zoom,
    Duration duration = const Duration(milliseconds: 500),
  }) async {
    if (!_isMapReady || !mounted) return;

    final targetZoom = zoom ?? mapController.camera.zoom;

    // FlutterMap no tiene animación nativa, usar move con throttling
    updateMapPosition(point, zoom: targetZoom, animated: true);

    await Future.delayed(duration);
  }

  /// Calcula zoom óptimo para mostrar una distancia
  double calculateOptimalZoom(double radiusMeters) {
    // Fórmula aproximada: zoom = log2(40075017 / (radiusMeters * 256))
    // Donde 40075017 es la circunferencia de la tierra en metros
    final zoom = math.log(40075017 / (radiusMeters * 256)) / math.ln2;
    return zoom.clamp(_minZoom, _maxZoom);
  }

  /// Limpia recursos
  void disposeMapControls() {
    _mapUpdateThrottle?.cancel();
    _mapUpdateThrottle = null;
  }

  @override
  void dispose() {
    disposeMapControls();
    super.dispose();
  }
}
