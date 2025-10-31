import 'package:equatable/equatable.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_map/flutter_map.dart';
import 'map_state.dart';

/// ============================================================================
/// MAP EVENT - Eventos del mapa
/// ============================================================================

abstract class MapEvent extends Equatable {
  const MapEvent();

  @override
  List<Object?> get props => [];
}

/// Inicializar mapa
class MapInitialized extends MapEvent {
  final LatLng initialCenter;
  final double initialZoom;

  const MapInitialized({required this.initialCenter, this.initialZoom = 13.0});

  @override
  List<Object?> get props => [initialCenter, initialZoom];
}

/// Actualizar centro del mapa
class MapCenterChanged extends MapEvent {
  final LatLng center;
  final bool animate;

  const MapCenterChanged({required this.center, this.animate = true});

  @override
  List<Object?> get props => [center, animate];
}

/// Cambiar zoom
class MapZoomChanged extends MapEvent {
  final double zoom;
  final bool animate;

  const MapZoomChanged({required this.zoom, this.animate = true});

  @override
  List<Object?> get props => [zoom, animate];
}

/// Zoom in/out
class MapZoomInRequested extends MapEvent {
  const MapZoomInRequested();
}

class MapZoomOutRequested extends MapEvent {
  const MapZoomOutRequested();
}

/// Actualizar bounds del mapa
class MapBoundsChanged extends MapEvent {
  final LatLngBounds bounds;

  const MapBoundsChanged({required this.bounds});

  @override
  List<Object?> get props => [bounds];
}

/// Agregar marker
class MapMarkerAdded extends MapEvent {
  final Marker marker;

  const MapMarkerAdded({required this.marker});

  @override
  List<Object?> get props => [marker];
}

/// Agregar múltiples markers
class MapMarkersAdded extends MapEvent {
  final List<Marker> markers;
  final bool clearExisting; // Si true, reemplaza markers existentes

  const MapMarkersAdded({required this.markers, this.clearExisting = false});

  @override
  List<Object?> get props => [markers, clearExisting];
}

/// Remover marker
class MapMarkerRemoved extends MapEvent {
  final String markerId;

  const MapMarkerRemoved({required this.markerId});

  @override
  List<Object?> get props => [markerId];
}

/// Limpiar markers
class MapMarkersCleared extends MapEvent {
  final MarkerType? markerType; // Si es null, limpia todos

  const MapMarkersCleared({this.markerType});

  @override
  List<Object?> get props => [markerType];
}

/// Agregar polyline (ruta)
class MapPolylineAdded extends MapEvent {
  final Polyline polyline;

  const MapPolylineAdded({required this.polyline});

  @override
  List<Object?> get props => [polyline];
}

/// Actualizar polylines
class MapPolylinesUpdated extends MapEvent {
  final List<Polyline> polylines;

  const MapPolylinesUpdated({required this.polylines});

  @override
  List<Object?> get props => [polylines];
}

/// Limpiar polylines
class MapPolylinesCleared extends MapEvent {
  const MapPolylinesCleared();
}

/// Agregar círculo
class MapCircleAdded extends MapEvent {
  final CircleMarker circle;

  const MapCircleAdded({required this.circle});

  @override
  List<Object?> get props => [circle];
}

/// Limpiar círculos
class MapCirclesCleared extends MapEvent {
  const MapCirclesCleared();
}

/// Cambiar capa del mapa
class MapLayerChanged extends MapEvent {
  final MapLayer layer;

  const MapLayerChanged({required this.layer});

  @override
  List<Object?> get props => [layer];
}

/// Toggle ubicación del usuario
class MapUserLocationToggled extends MapEvent {
  final bool show;

  const MapUserLocationToggled({required this.show});

  @override
  List<Object?> get props => [show];
}

/// Toggle seguimiento del usuario
class MapFollowUserLocationToggled extends MapEvent {
  final bool follow;

  const MapFollowUserLocationToggled({required this.follow});

  @override
  List<Object?> get props => [follow];
}

/// Centrar en ubicación del usuario
class MapCenterOnUserRequested extends MapEvent {
  const MapCenterOnUserRequested();
}

/// Ajustar mapa para mostrar todos los markers
class MapFitBoundsRequested extends MapEvent {
  final List<LatLng> points;
  final double padding; // En pixeles

  const MapFitBoundsRequested({required this.points, this.padding = 50.0});

  @override
  List<Object?> get props => [points, padding];
}

/// Error del mapa
class MapErrorOccurred extends MapEvent {
  final String message;
  final MapErrorType errorType;

  const MapErrorOccurred({required this.message, required this.errorType});

  @override
  List<Object?> get props => [message, errorType];
}

/// Reset del mapa (volver a estado inicial)
class MapReset extends MapEvent {
  const MapReset();
}
