import 'dart:convert';
import 'package:latlong2/latlong.dart';
import '../models/transit_route.dart';
import 'debug_logger.dart';
import 'backend/dio_api_client.dart';

/// Servicio de routing para personas no videntes
/// Integra GraphHopper GTFS + Moovit para navegación accesible
class NavigationRouteService {
  final String baseUrl;

  NavigationRouteService(this.baseUrl);

  /// Calcula ruta de transporte público ÓPTIMA
  /// Prioriza: menos trasbordos > menos caminata > más rápida
  Future<TransitRoute?> getAccessibleRoute({
    required LatLng origin,
    required LatLng destination,
    DateTime? departureTime,
    bool minimizeTransfers = true,
    bool minimizeWalking = true,
  }) async {
    try {
      DebugLogger.navigation(
        '🚍 [ROUTE] Calculando ruta accesible de $origin a $destination',
      );

      // Endpoint correcto del backend
      final url = '$baseUrl/api/route/transit';
      
      final body = {
        'origin': {'lat': origin.latitude, 'lon': origin.longitude},
        'destination': {'lat': destination.latitude, 'lon': destination.longitude},
        'departure_time': (departureTime ?? DateTime.now().add(const Duration(minutes: 2)))
            .toIso8601String(),
        'max_walk_distance': minimizeWalking ? 500 : 1000, // 500m si minimiza caminata
      };

      DebugLogger.navigation('📤 Request: ${jsonEncode(body)}');

      final response = await DioApiClient.post(
        url,
        data: body,
      );

      if (response.statusCode == 200) {
        final data = response.data;
        
        if (data['route'] != null) {
          final route = TransitRoute.fromJson(data['route']);
          
          DebugLogger.navigation(
            '✅ Ruta calculada: ${route.durationText}, ${route.transfers} trasbordos, ${route.legs.length} segmentos',
          );
          
          return route;
        }
      }

      DebugLogger.navigation('⚠️ Sin rutas disponibles');
      return null;
    } catch (e, stack) {
      DebugLogger.navigation('❌ Error calculando ruta: $e');
      DebugLogger.navigation('Stack: $stack');
      return null;
    }
  }

  /// Obtiene TODAS las alternativas de ruta (para mostrar opciones)
  Future<List<TransitRoute>> getAllRouteOptions({
    required LatLng origin,
    required LatLng destination,
    DateTime? departureTime,
    int maxWalkDistance = 1000,
  }) async {
    try {
      DebugLogger.navigation(
        '🔍 [ROUTE] Buscando alternativas de $origin a $destination',
      );

      final url = '$baseUrl/api/route/transit';
      
      final body = {
        'origin': {'lat': origin.latitude, 'lon': origin.longitude},
        'destination': {'lat': destination.latitude, 'lon': destination.longitude},
        'departure_time': (departureTime ?? DateTime.now().add(const Duration(minutes: 2)))
            .toIso8601String(),
        'max_walk_distance': maxWalkDistance,
      };

      final response = await DioApiClient.post(
        url,
        data: body,
      );

      if (response.statusCode == 200) {
        final data = response.data;
        
        if (data['alternatives'] != null) {
          final alternatives = (data['alternatives'] as List)
              .map((alt) => TransitRoute.fromJson(alt))
              .toList();
          
          DebugLogger.navigation(
            '✅ ${alternatives.length} alternativas encontradas',
          );
          
          return alternatives;
        }
      }

      return [];
    } catch (e, stack) {
      DebugLogger.navigation('❌ Error buscando alternativas: $e');
      DebugLogger.navigation('Stack: $stack');
      return [];
    }
  }

  /// Ruta SOLO caminando (para primeros/últimos metros)
  Future<TransitRoute?> getWalkingRoute({
    required LatLng origin,
    required LatLng destination,
  }) async {
    try {
      final url = '$baseUrl/api/route/walking';
      
      final params = {
        'origin_lat': origin.latitude.toString(),
        'origin_lon': origin.longitude.toString(),
        'dest_lat': destination.latitude.toString(),
        'dest_lon': destination.longitude.toString(),
      };

      final response = await DioApiClient.get(
        url,
        queryParameters: params,
      );

      if (response.statusCode == 200) {
        final data = response.data;
        
        // Convertir respuesta de walking a formato TransitRoute
        final geometry = (data['geometry'] as List?)
                ?.map((coord) => LatLng(
                      (coord[1] as num).toDouble(),
                      (coord[0] as num).toDouble(),
                    ))
                .toList() ??
            [];

        final instructions = (data['instructions'] as List?)
                ?.map((inst) => WalkInstruction.fromJson(inst))
                .toList() ??
            [];

        final leg = RouteLeg(
          type: LegType.walk,
          geometry: geometry,
          distanceMeters: (data['distance_meters'] as num?)?.toDouble() ?? 0.0,
          durationSeconds: (data['duration_seconds'] as num?)?.toInt() ?? 0,
          walkInstructions: instructions,
        );

        return TransitRoute(
          legs: [leg],
          totalDistanceMeters: leg.distanceMeters,
          totalDurationSeconds: leg.durationSeconds,
          transfers: 0,
        );
      }

      return null;
    } catch (e) {
      DebugLogger.navigation('❌ Error ruta peatonal: $e');
      return null;
    }
  }

  /// Obtiene paraderos cercanos al usuario
  /// Útil para comandos de voz: "ir al paradero más cercano"
  Future<List<BusStopInfo>> getNearbyStops({
    required LatLng location,
    double radiusMeters = 500,
  }) async {
    try {
      final url = '$baseUrl/api/stops/nearby';
      
      final params = {
        'lat': location.latitude.toString(),
        'lon': location.longitude.toString(),
        'radius': radiusMeters.toString(),
      };

      final response = await DioApiClient.get(
        url,
        queryParameters: params,
      );

      if (response.statusCode == 200) {
        final data = response.data;
        
        if (data['stops'] != null) {
          return (data['stops'] as List)
              .map((stop) => BusStopInfo.fromJson(stop))
              .toList();
        }
      }

      return [];
    } catch (e) {
      DebugLogger.navigation('❌ Error paraderos cercanos: $e');
      return [];
    }
  }

  /// Busca un lugar por nombre (geocoding)
  /// Para comandos de voz: "ir a Plaza de Armas", "ir a Bellavista"
  Future<SearchResult?> searchPlace(String query) async {
    try {
      DebugLogger.navigation('🔍 [GEOCODE] Buscando: "$query"');

      final url = '$baseUrl/api/geocode/search';
      
      final params = {
        'q': query,  // Nominatim usa 'q' no 'query'
        'limit': '5',
        'bounded': 'true',  // Limitar a Santiago
      };

      final response = await DioApiClient.get(
        url,
        queryParameters: params,
      );

      if (response.statusCode == 200) {
        final data = response.data;
        
        if (data['results'] != null && (data['results'] as List).isNotEmpty) {
          final firstResult = data['results'][0];
          
          final result = SearchResult(
            name: firstResult['display_name'] ?? query,
            location: LatLng(
              (firstResult['lat'] as num).toDouble(),
              (firstResult['lon'] as num).toDouble(),
            ),
            displayName: firstResult['display_name'] ?? '',
            relevance: (firstResult['importance'] as num?)?.toDouble() ?? 0.5,
          );
          
          DebugLogger.navigation(
            '✅ Encontrado: ${result.displayName}',
          );
          return result;
        }
      }

      DebugLogger.navigation('⚠️ No se encontró "$query"');
      return null;
    } catch (e) {
      DebugLogger.navigation('❌ Error geocoding: $e');
      return null;
    }
  }

  /// Geocoding inverso: coordenadas → nombre del lugar
  /// Para TTS: "Estás en [nombre del lugar]"
  Future<String?> getPlaceName(LatLng location) async {
    try {
      final url = '$baseUrl/api/geocode/reverse';
      
      final params = {
        'lat': location.latitude.toString(),
        'lon': location.longitude.toString(),
      };

      final response = await DioApiClient.get(
        url,
        queryParameters: params,
      );

      if (response.statusCode == 200) {
        final data = response.data;
        return data['display_name'] as String?;
      }

      return null;
    } catch (e) {
      DebugLogger.navigation('❌ Error reverse geocoding: $e');
      return null;
    }
  }
}

/// Resultado de búsqueda de lugar
class SearchResult {
  final String name;
  final String displayName;
  final LatLng location;
  final double relevance;

  SearchResult({
    required this.name,
    required this.displayName,
    required this.location,
    required this.relevance,
  });

  factory SearchResult.fromJson(Map<String, dynamic> json) {
    return SearchResult(
      name: json['name'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      location: LatLng(
        (json['lat'] as num).toDouble(),
        (json['lon'] as num).toDouble(),
      ),
      relevance: (json['relevance'] as num?)?.toDouble() ?? 0.0,
    );
  }
}