import 'package:equatable/equatable.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_map/flutter_map.dart';

/// ============================================================================
/// MAP STATE - Estados del mapa interactivo
/// ============================================================================
/// Gestiona el estado visual del mapa:
/// - Markers (paraderos, ubicación, destino)
/// - Polylines (rutas, trayectorias)
/// - Zoom y centro
/// - Layers (tráfico, transporte público)

abstract class MapState extends Equatable {
  const MapState();

  @override
  List<Object?> get props => [];
}

/// Mapa cargándose
class MapLoading extends MapState {
  const MapLoading();
}

/// Mapa cargado y listo
class MapLoaded extends MapState {
  final LatLng center;
  final double zoom;
  final List<Marker> markers;
  final List<Polyline> polylines;
  final List<CircleMarker> circles; // Círculos de búsqueda, radio de cobertura
  final MapLayer activeLayer;
  final bool showUserLocation;
  final bool followUserLocation; // Si la cámara sigue al usuario
  final LatLngBounds? bounds; // Límites del mapa (opcional)

  const MapLoaded({
    required this.center,
    required this.zoom,
    this.markers = const [],
    this.polylines = const [],
    this.circles = const [],
    this.activeLayer = MapLayer.standard,
    this.showUserLocation = true,
    this.followUserLocation = false,
    this.bounds,
  });

  @override
  List<Object?> get props => [
    center,
    zoom,
    markers,
    polylines,
    circles,
    activeLayer,
    showUserLocation,
    followUserLocation,
    bounds,
  ];

  MapLoaded copyWith({
    LatLng? center,
    double? zoom,
    List<Marker>? markers,
    List<Polyline>? polylines,
    List<CircleMarker>? circles,
    MapLayer? activeLayer,
    bool? showUserLocation,
    bool? followUserLocation,
    LatLngBounds? bounds,
  }) {
    return MapLoaded(
      center: center ?? this.center,
      zoom: zoom ?? this.zoom,
      markers: markers ?? this.markers,
      polylines: polylines ?? this.polylines,
      circles: circles ?? this.circles,
      activeLayer: activeLayer ?? this.activeLayer,
      showUserLocation: showUserLocation ?? this.showUserLocation,
      followUserLocation: followUserLocation ?? this.followUserLocation,
      bounds: bounds ?? this.bounds,
    );
  }

  /// Helpers
  int get markersCount => markers.length;
  int get polylinesCount => polylines.length;
  bool get hasRoute => polylines.isNotEmpty;
}

/// Error del mapa
class MapError extends MapState {
  final String message;
  final MapErrorType errorType;

  const MapError({required this.message, required this.errorType});

  @override
  List<Object?> get props => [message, errorType];
}

// =============================================================================
// ENUMS Y CLASES
// =============================================================================

/// Capas del mapa
enum MapLayer {
  standard, // Mapa estándar
  satellite, // Vista satélite
  traffic, // Capa de tráfico (futuro)
  transit, // Transporte público (futuro)
}

/// Tipos de markers
enum MarkerType {
  userLocation, // Ubicación del usuario
  destination, // Destino de navegación
  busStop, // Paradero de bus
  metroStation, // Estación de metro
  searchResult, // Resultado de búsqueda
  poi, // Punto de interés
}

/// Metadata de marker personalizado
class MapMarkerData {
  final String id;
  final MarkerType type;
  final String? title;
  final String? subtitle;
  final Map<String, dynamic>? metadata; // Datos adicionales

  const MapMarkerData({
    required this.id,
    required this.type,
    this.title,
    this.subtitle,
    this.metadata,
  });
}

/// Tipos de errores del mapa
enum MapErrorType {
  loadFailed, // Error cargando tiles del mapa
  locationUnavailable, // Ubicación no disponible
  networkError, // Error de red
  unknown,
}
