import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../services/debug_logger.dart';

/// Mixin para gestión de visualización de rutas y geometrías en el mapa
/// 
/// Proporciona:
/// - Renderizado de polylines (rutas peatonales, buses, etc.)
/// - Gestión de marcadores (origen, destino, paradas)
/// - Caché de geometrías para optimizar
/// - Colores y estilos predefinidos
/// 
/// Uso:
/// ```dart
/// class _MapScreenState extends State<MapScreen> 
///     with RouteDisplayMixin {
///   
///   void showRoute(List<LatLng> geometry) {
///     final polyline = createWalkingPolyline(geometry);
///     addPolyline(polyline);
///   }
/// }
/// ```
mixin RouteDisplayMixin<T extends StatefulWidget> on State<T> {
  // Estado interno
  final List<Polyline> _polylines = [];
  final List<Marker> _markers = [];
  final Map<String, List<LatLng>> _geometryCache = {};

  // Configuración de colores
  static const Color _walkingRouteColor = Color(0xFF4285F4); // Azul Google
  static const Color _busRouteColor = Color(0xFFEA4335); // Rojo Google
  static const Color _metroRouteColor = Color(0xFFFBBC05); // Amarillo Google
  static const Color _highlightRouteColor = Color(0xFF34A853); // Verde Google

  /// Obtiene todas las polylines actuales
  List<Polyline> get polylines => List.unmodifiable(_polylines);

  /// Obtiene todos los marcadores actuales
  List<Marker> get markers => List.unmodifiable(_markers);

  /// Crea una polyline para ruta peatonal
  Polyline createWalkingPolyline(
    List<LatLng> points, {
    String? id,
    double width = 5.0,
    Color? color,
  }) {
    return Polyline(
      points: points,
      strokeWidth: width,
      color: color ?? _walkingRouteColor,
      borderStrokeWidth: 2.0,
      borderColor: Colors.white,
    );
  }

  /// Crea una polyline para ruta de bus
  Polyline createBusPolyline(
    List<LatLng> points, {
    String? id,
    String? routeNumber,
    double width = 6.0,
    Color? color,
  }) {
    return Polyline(
      points: points,
      strokeWidth: width,
      color: color ?? _busRouteColor,
      borderStrokeWidth: 2.0,
      borderColor: Colors.white,
    );
  }

  /// Crea una polyline para ruta de metro
  Polyline createMetroPolyline(
    List<LatLng> points, {
    String? id,
    String? lineName,
    double width = 7.0,
    Color? color,
  }) {
    return Polyline(
      points: points,
      strokeWidth: width,
      color: color ?? _metroRouteColor,
      borderStrokeWidth: 2.0,
      borderColor: Colors.white,
    );
  }

  /// Crea una polyline resaltada (para instrucción actual)
  Polyline createHighlightPolyline(
    List<LatLng> points, {
    double width = 8.0,
  }) {
    return Polyline(
      points: points,
      strokeWidth: width,
      color: _highlightRouteColor,
      borderStrokeWidth: 3.0,
      borderColor: Colors.white,
    );
  }

  /// Agrega una polyline al mapa
  void addPolyline(Polyline polyline) {
    if (!mounted) return;

    setState(() {
      _polylines.add(polyline);
    });

    DebugLogger.navigation('➕ Polyline agregada (total: ${_polylines.length})');
  }

  /// Agrega múltiples polylines
  void addPolylines(List<Polyline> polylines) {
    if (!mounted || polylines.isEmpty) return;

    setState(() {
      _polylines.addAll(polylines);
    });

    DebugLogger.navigation('➕ ${polylines.length} polylines agregadas (total: ${_polylines.length})');
  }

  /// Remueve todas las polylines
  void clearPolylines() {
    if (!mounted) return;

    setState(() {
      _polylines.clear();
    });

    DebugLogger.navigation('🗑️ Polylines limpiadas');
  }

  /// Remueve polylines que coincidan con un predicado
  void removePolylinesWhere(bool Function(Polyline) test) {
    if (!mounted) return;

    setState(() {
      _polylines.removeWhere(test);
    });
  }

  /// Crea un marcador de origen (verde)
  Marker createOriginMarker(
    LatLng position, {
    String? label,
    double size = 40.0,
  }) {
    return Marker(
      point: position,
      width: size,
      height: size,
      child: Icon(
        Icons.location_on,
        color: Colors.green,
        size: size,
      ),
    );
  }

  /// Crea un marcador de destino (rojo)
  Marker createDestinationMarker(
    LatLng position, {
    String? label,
    double size = 40.0,
  }) {
    return Marker(
      point: position,
      width: size,
      height: size,
      child: Icon(
        Icons.location_on,
        color: Colors.red,
        size: size,
      ),
    );
  }

  /// Crea un marcador de parada de bus
  Marker createBusStopMarker(
    LatLng position, {
    String? stopCode,
    String? stopName,
    double size = 30.0,
    bool isHighlighted = false,
  }) {
    return Marker(
      point: position,
      width: size,
      height: size,
      child: Container(
        decoration: BoxDecoration(
          color: isHighlighted ? Colors.orange : Colors.blue,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: Icon(
          Icons.directions_bus,
          color: Colors.white,
          size: size * 0.6,
        ),
      ),
    );
  }

  /// Crea un marcador de ubicación actual
  Marker createUserLocationMarker(
    LatLng position, {
    double size = 20.0,
    double? accuracy,
  }) {
    return Marker(
      point: position,
      width: size,
      height: size,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.blue.withOpacity(0.8),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: [
            BoxShadow(
              color: Colors.blue.withOpacity(0.3),
              blurRadius: 10,
              spreadRadius: 5,
            ),
          ],
        ),
      ),
    );
  }

  /// Agrega un marcador al mapa
  void addMarker(Marker marker) {
    if (!mounted) return;

    setState(() {
      _markers.add(marker);
    });

    DebugLogger.navigation('📍 Marcador agregado (total: ${_markers.length})');
  }

  /// Agrega múltiples marcadores
  void addMarkers(List<Marker> markers) {
    if (!mounted || markers.isEmpty) return;

    setState(() {
      _markers.addAll(markers);
    });

    DebugLogger.navigation('📍 ${markers.length} marcadores agregados (total: ${_markers.length})');
  }

  /// Remueve todos los marcadores
  void clearMarkers() {
    if (!mounted) return;

    setState(() {
      _markers.clear();
    });

    DebugLogger.navigation('🗑️ Marcadores limpiados');
  }

  /// Remueve marcadores que coincidan con un predicado
  void removeMarkersWhere(bool Function(Marker) test) {
    if (!mounted) return;

    setState(() {
      _markers.removeWhere(test);
    });
  }

  /// Limpia todo el mapa (polylines + marcadores)
  void clearAllMapOverlays() {
    clearPolylines();
    clearMarkers();
    _geometryCache.clear();
    DebugLogger.navigation('🗑️ Mapa limpiado completamente');
  }

  /// Cachea una geometría con una clave
  void cacheGeometry(String key, List<LatLng> geometry) {
    _geometryCache[key] = geometry;
    DebugLogger.navigation('💾 Geometría cacheada: $key (${geometry.length} puntos)');
  }

  /// Obtiene una geometría del caché
  List<LatLng>? getCachedGeometry(String key) {
    return _geometryCache[key];
  }

  /// Verifica si una geometría está en caché
  bool hasGeometryInCache(String key) {
    return _geometryCache.containsKey(key);
  }

  /// Limpia el caché de geometrías
  void clearGeometryCache() {
    _geometryCache.clear();
    DebugLogger.navigation('🗑️ Caché de geometrías limpiado');
  }

  /// Muestra una ruta completa (origen → destino) con múltiples segmentos
  void displayRoute({
    required LatLng origin,
    required LatLng destination,
    required List<RouteSegment> segments,
  }) {
    clearAllMapOverlays();

    // Marcador de origen
    addMarker(createOriginMarker(origin));

    // Marcador de destino
    addMarker(createDestinationMarker(destination));

    // Agregar cada segmento
    for (var segment in segments) {
      final polyline = _createPolylineForSegment(segment);
      if (polyline != null) {
        addPolyline(polyline);
      }

      // Agregar marcadores de paradas si es segmento de transporte
      if (segment.stops != null) {
        for (var stop in segment.stops!) {
          addMarker(createBusStopMarker(stop));
        }
      }
    }

    DebugLogger.success('✅ Ruta mostrada con ${segments.length} segmentos');
  }

  /// Crea polyline según el tipo de segmento
  Polyline? _createPolylineForSegment(RouteSegment segment) {
    if (segment.geometry.isEmpty) return null;

    switch (segment.type) {
      case RouteSegmentType.walk:
        return createWalkingPolyline(segment.geometry);
      case RouteSegmentType.bus:
        return createBusPolyline(segment.geometry);
      case RouteSegmentType.metro:
        return createMetroPolyline(segment.geometry);
    }
  }

  /// Resalta un segmento específico de la ruta
  void highlightRouteSegment(int segmentIndex, List<RouteSegment> segments) {
    if (segmentIndex < 0 || segmentIndex >= segments.length) return;

    final segment = segments[segmentIndex];
    if (segment.geometry.isEmpty) return;

    // Agregar polyline resaltada
    addPolyline(createHighlightPolyline(segment.geometry));

    DebugLogger.navigation('🔆 Segmento $segmentIndex resaltado');
  }
}

/// Tipo de segmento de ruta
enum RouteSegmentType {
  walk,
  bus,
  metro,
}

/// Segmento de una ruta
class RouteSegment {
  final RouteSegmentType type;
  final List<LatLng> geometry;
  final String? routeNumber;
  final List<LatLng>? stops;
  final String? instruction;

  const RouteSegment({
    required this.type,
    required this.geometry,
    this.routeNumber,
    this.stops,
    this.instruction,
  });
}
