import 'dart:async';
import 'package:flutter/material.dart' show Key;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_map/flutter_map.dart' hide MapEvent;
import 'map_event.dart';
import 'map_state.dart';
import '../../services/debug_logger.dart';

/// ============================================================================
/// MAP BLOC - Gestión del estado del mapa interactivo
/// ============================================================================
/// Maneja todo el estado visual del mapa:
/// - Markers (paraderos, ubicación, puntos de interés)
/// - Polylines (rutas de navegación)
/// - Circles (áreas de búsqueda, cobertura)
/// - Zoom, centro, bounds
/// - Capas del mapa (estándar, satélite)
///
/// Beneficios vs setState():
/// - Estado del mapa centralizado
/// - Testeable (mock markers/polylines)
/// - Reactive programming
/// - Rebuild selectivo (solo widgets que necesitan)

class MapBloc extends Bloc<MapEvent, MapState> {
  // Configuración
  static const LatLng _defaultCenter = LatLng(-33.4489, -70.6693); // Santiago
  static const double _defaultZoom = 13.0;
  static const double _minZoom = 10.0;
  static const double _maxZoom = 18.0;
  static const double _zoomStep = 1.0;

  MapBloc() : super(const MapLoading()) {
    on<MapInitialized>(_onMapInitialized);
    on<MapCenterChanged>(_onMapCenterChanged);
    on<MapZoomChanged>(_onMapZoomChanged);
    on<MapZoomInRequested>(_onMapZoomInRequested);
    on<MapZoomOutRequested>(_onMapZoomOutRequested);
    on<MapBoundsChanged>(_onMapBoundsChanged);
    on<MapMarkerAdded>(_onMapMarkerAdded);
    on<MapMarkersAdded>(_onMapMarkersAdded);
    on<MapMarkerRemoved>(_onMapMarkerRemoved);
    on<MapMarkersCleared>(_onMapMarkersCleared);
    on<MapPolylineAdded>(_onMapPolylineAdded);
    on<MapPolylinesUpdated>(_onMapPolylinesUpdated);
    on<MapPolylinesCleared>(_onMapPolylinesCleared);
    on<MapCircleAdded>(_onMapCircleAdded);
    on<MapCirclesCleared>(_onMapCirclesCleared);
    on<MapLayerChanged>(_onMapLayerChanged);
    on<MapUserLocationToggled>(_onMapUserLocationToggled);
    on<MapFollowUserLocationToggled>(_onMapFollowUserLocationToggled);
    on<MapCenterOnUserRequested>(_onMapCenterOnUserRequested);
    on<MapFitBoundsRequested>(_onMapFitBoundsRequested);
    on<MapErrorOccurred>(_onMapErrorOccurred);
    on<MapReset>(_onMapReset);
  }

  /// Inicializar mapa
  Future<void> _onMapInitialized(
    MapInitialized event,
    Emitter<MapState> emit,
  ) async {
    DebugLogger.info('Inicializando mapa', context: 'MapBloc');

    emit(
      MapLoaded(
        center: event.initialCenter,
        zoom: event.initialZoom,
        markers: [],
        polylines: [],
        circles: [],
      ),
    );

    DebugLogger.success('Mapa inicializado', context: 'MapBloc');
  }

  /// Cambiar centro
  Future<void> _onMapCenterChanged(
    MapCenterChanged event,
    Emitter<MapState> emit,
  ) async {
    final currentState = state;
    if (currentState is! MapLoaded) return;

    emit(
      currentState.copyWith(
        center: event.center,
        followUserLocation:
            false, // Detener seguimiento si se mueve manualmente
      ),
    );
  }

  /// Cambiar zoom
  Future<void> _onMapZoomChanged(
    MapZoomChanged event,
    Emitter<MapState> emit,
  ) async {
    final currentState = state;
    if (currentState is! MapLoaded) return;

    final clampedZoom = event.zoom.clamp(_minZoom, _maxZoom);

    emit(currentState.copyWith(zoom: clampedZoom));
  }

  /// Zoom in
  Future<void> _onMapZoomInRequested(
    MapZoomInRequested event,
    Emitter<MapState> emit,
  ) async {
    final currentState = state;
    if (currentState is! MapLoaded) return;

    final newZoom = (currentState.zoom + _zoomStep).clamp(_minZoom, _maxZoom);

    emit(currentState.copyWith(zoom: newZoom));
  }

  /// Zoom out
  Future<void> _onMapZoomOutRequested(
    MapZoomOutRequested event,
    Emitter<MapState> emit,
  ) async {
    final currentState = state;
    if (currentState is! MapLoaded) return;

    final newZoom = (currentState.zoom - _zoomStep).clamp(_minZoom, _maxZoom);

    emit(currentState.copyWith(zoom: newZoom));
  }

  /// Bounds cambiados
  Future<void> _onMapBoundsChanged(
    MapBoundsChanged event,
    Emitter<MapState> emit,
  ) async {
    final currentState = state;
    if (currentState is! MapLoaded) return;

    emit(currentState.copyWith(bounds: event.bounds));
  }

  /// Agregar marker
  Future<void> _onMapMarkerAdded(
    MapMarkerAdded event,
    Emitter<MapState> emit,
  ) async {
    final currentState = state;
    if (currentState is! MapLoaded) return;

    final markers = List<Marker>.from(currentState.markers)..add(event.marker);

    emit(currentState.copyWith(markers: markers));

    DebugLogger.info(
      'Marker agregado (total: ${markers.length})',
      context: 'MapBloc',
    );
  }

  /// Agregar múltiples markers
  Future<void> _onMapMarkersAdded(
    MapMarkersAdded event,
    Emitter<MapState> emit,
  ) async {
    final currentState = state;
    if (currentState is! MapLoaded) return;

    final markers = event.clearExisting
        ? event.markers
        : [...currentState.markers, ...event.markers];

    emit(currentState.copyWith(markers: markers));

    DebugLogger.info(
      'Markers ${event.clearExisting ? "reemplazados" : "agregados"}: ${event.markers.length} (total: ${markers.length})',
      context: 'MapBloc',
    );
  }

  /// Remover marker
  Future<void> _onMapMarkerRemoved(
    MapMarkerRemoved event,
    Emitter<MapState> emit,
  ) async {
    final currentState = state;
    if (currentState is! MapLoaded) return;

    final markers = currentState.markers
        .where((m) => m.key != Key(event.markerId))
        .toList();

    emit(currentState.copyWith(markers: markers));
  }

  /// Limpiar markers
  Future<void> _onMapMarkersCleared(
    MapMarkersCleared event,
    Emitter<MapState> emit,
  ) async {
    final currentState = state;
    if (currentState is! MapLoaded) return;

    // TODO: Implementar filtro por tipo de marker si event.markerType != null

    emit(currentState.copyWith(markers: []));

    DebugLogger.info('Markers limpiados', context: 'MapBloc');
  }

  /// Agregar polyline
  Future<void> _onMapPolylineAdded(
    MapPolylineAdded event,
    Emitter<MapState> emit,
  ) async {
    final currentState = state;
    if (currentState is! MapLoaded) return;

    final polylines = List<Polyline>.from(currentState.polylines)
      ..add(event.polyline);

    emit(currentState.copyWith(polylines: polylines));

    DebugLogger.info('Polyline agregada', context: 'MapBloc');
  }

  /// Actualizar polylines
  Future<void> _onMapPolylinesUpdated(
    MapPolylinesUpdated event,
    Emitter<MapState> emit,
  ) async {
    final currentState = state;
    if (currentState is! MapLoaded) return;

    emit(currentState.copyWith(polylines: event.polylines));

    DebugLogger.info(
      'Polylines actualizadas: ${event.polylines.length}',
      context: 'MapBloc',
    );
  }

  /// Limpiar polylines
  Future<void> _onMapPolylinesCleared(
    MapPolylinesCleared event,
    Emitter<MapState> emit,
  ) async {
    final currentState = state;
    if (currentState is! MapLoaded) return;

    emit(currentState.copyWith(polylines: []));

    DebugLogger.info('Polylines limpiadas', context: 'MapBloc');
  }

  /// Agregar círculo
  Future<void> _onMapCircleAdded(
    MapCircleAdded event,
    Emitter<MapState> emit,
  ) async {
    final currentState = state;
    if (currentState is! MapLoaded) return;

    final circles = List<CircleMarker>.from(currentState.circles)
      ..add(event.circle);

    emit(currentState.copyWith(circles: circles));
  }

  /// Limpiar círculos
  Future<void> _onMapCirclesCleared(
    MapCirclesCleared event,
    Emitter<MapState> emit,
  ) async {
    final currentState = state;
    if (currentState is! MapLoaded) return;

    emit(currentState.copyWith(circles: []));
  }

  /// Cambiar capa
  Future<void> _onMapLayerChanged(
    MapLayerChanged event,
    Emitter<MapState> emit,
  ) async {
    final currentState = state;
    if (currentState is! MapLoaded) return;

    emit(currentState.copyWith(activeLayer: event.layer));

    DebugLogger.info('Capa cambiada a: ${event.layer}', context: 'MapBloc');
  }

  /// Toggle ubicación del usuario
  Future<void> _onMapUserLocationToggled(
    MapUserLocationToggled event,
    Emitter<MapState> emit,
  ) async {
    final currentState = state;
    if (currentState is! MapLoaded) return;

    emit(currentState.copyWith(showUserLocation: event.show));
  }

  /// Toggle seguimiento del usuario
  Future<void> _onMapFollowUserLocationToggled(
    MapFollowUserLocationToggled event,
    Emitter<MapState> emit,
  ) async {
    final currentState = state;
    if (currentState is! MapLoaded) return;

    emit(currentState.copyWith(followUserLocation: event.follow));

    DebugLogger.info(
      'Seguimiento de usuario: ${event.follow ? "activado" : "desactivado"}',
      context: 'MapBloc',
    );
  }

  /// Centrar en usuario
  Future<void> _onMapCenterOnUserRequested(
    MapCenterOnUserRequested event,
    Emitter<MapState> emit,
  ) async {
    final currentState = state;
    if (currentState is! MapLoaded) return;

    // TODO: Obtener posición del usuario desde LocationBloc
    final userPosition = _defaultCenter; // Mock

    emit(currentState.copyWith(center: userPosition, followUserLocation: true));

    DebugLogger.info('Centrando en usuario', context: 'MapBloc');
  }

  /// Ajustar bounds para mostrar puntos
  Future<void> _onMapFitBoundsRequested(
    MapFitBoundsRequested event,
    Emitter<MapState> emit,
  ) async {
    final currentState = state;
    if (currentState is! MapLoaded) return;

    if (event.points.isEmpty) return;

    // Calcular bounds
    final bounds = _calculateBounds(event.points);

    emit(currentState.copyWith(bounds: bounds, followUserLocation: false));

    DebugLogger.info(
      'Ajustando bounds para ${event.points.length} puntos',
      context: 'MapBloc',
    );
  }

  /// Error del mapa
  Future<void> _onMapErrorOccurred(
    MapErrorOccurred event,
    Emitter<MapState> emit,
  ) async {
    DebugLogger.error(
      'Error del mapa',
      context: 'MapBloc',
      error: event.message,
    );

    emit(MapError(message: event.message, errorType: event.errorType));
  }

  /// Reset
  Future<void> _onMapReset(MapReset event, Emitter<MapState> emit) async {
    DebugLogger.info('Reseteando mapa', context: 'MapBloc');

    emit(
      MapLoaded(
        center: _defaultCenter,
        zoom: _defaultZoom,
        markers: [],
        polylines: [],
        circles: [],
      ),
    );
  }

  // ===========================================================================
  // HELPERS PRIVADOS
  // ===========================================================================

  /// Calcular bounds para lista de puntos
  LatLngBounds _calculateBounds(List<LatLng> points) {
    if (points.isEmpty) {
      return LatLngBounds(
        const LatLng(-33.5, -70.7),
        const LatLng(-33.4, -70.6),
      );
    }

    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLng = points.first.longitude;
    double maxLng = points.first.longitude;

    for (final point in points) {
      if (point.latitude < minLat) minLat = point.latitude;
      if (point.latitude > maxLat) maxLat = point.latitude;
      if (point.longitude < minLng) minLng = point.longitude;
      if (point.longitude > maxLng) maxLng = point.longitude;
    }

    return LatLngBounds(LatLng(minLat, minLng), LatLng(maxLat, maxLng));
  }
}
