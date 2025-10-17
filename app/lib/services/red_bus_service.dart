// ============================================================================
// RED BUS SERVICE - Servicio para buses Red de Santiago
// ============================================================================
// Integra con Moovit scraping del backend para obtener:
// - Información de rutas de buses Red
// - Itinerarios con buses Red
// - Paradas y geometrías de rutas
// ============================================================================

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'api_client.dart';

class RedBusStop {
  final String name;
  final double latitude;
  final double longitude;
  final int sequence;

  RedBusStop({
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.sequence,
  });

  factory RedBusStop.fromJson(Map<String, dynamic> json) {
    return RedBusStop(
      name: json['name'] as String? ?? '',
      latitude: (json['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 0.0,
      sequence: json['sequence'] as int? ?? 0,
    );
  }

  LatLng get location => LatLng(latitude, longitude);
}

class RedBusRoute {
  final String routeNumber;
  final String routeName;
  final String direction;
  final List<RedBusStop> stops;
  final List<LatLng> geometry;
  final int durationMinutes;
  final double distanceKm;
  final String? firstService;
  final String? lastService;

  RedBusRoute({
    required this.routeNumber,
    required this.routeName,
    required this.direction,
    required this.stops,
    required this.geometry,
    required this.durationMinutes,
    required this.distanceKm,
    this.firstService,
    this.lastService,
  });

  factory RedBusRoute.fromJson(Map<String, dynamic> json) {
    final stopsData = json['stops'] as List<dynamic>? ?? [];
    final stops = stopsData
        .map((s) => RedBusStop.fromJson(s as Map<String, dynamic>))
        .toList();

    final geometryData = json['geometry'] as List<dynamic>? ?? [];
    final geometry = geometryData.map((coords) {
      final coordsList = coords as List<dynamic>;
      return LatLng(
        (coordsList[1] as num).toDouble(), // lat
        (coordsList[0] as num).toDouble(), // lon
      );
    }).toList();

    return RedBusRoute(
      routeNumber: json['route_number'] as String? ?? '',
      routeName: json['route_name'] as String? ?? '',
      direction: json['direction'] as String? ?? '',
      stops: stops,
      geometry: geometry,
      durationMinutes: json['duration_minutes'] as int? ?? 0,
      distanceKm: (json['distance_km'] as num?)?.toDouble() ?? 0.0,
      firstService: json['first_service'] as String?,
      lastService: json['last_service'] as String?,
    );
  }

  String get displayName => 'Red $routeNumber - $routeName';

  String get scheduleInfo {
    if (firstService != null && lastService != null) {
      return 'Horario: $firstService - $lastService';
    }
    return 'Horario: Consultar en paradero';
  }
}

class RedBusLeg {
  final String type; // "walk", "bus", "metro"
  final String mode; // "Red", "Metro", "walk"
  final String? routeNumber;
  final String from;
  final String to;
  final int durationMinutes;
  final double distanceKm;
  final String instruction;
  final List<LatLng>? geometry;
  final RedBusStop? departStop;
  final RedBusStop? arriveStop;
  final int? stopCount; // Número de paradas en el viaje

  RedBusLeg({
    required this.type,
    required this.mode,
    this.routeNumber,
    required this.from,
    required this.to,
    required this.durationMinutes,
    required this.distanceKm,
    required this.instruction,
    this.geometry,
    this.departStop,
    this.arriveStop,
    this.stopCount,
  });

  factory RedBusLeg.fromJson(Map<String, dynamic> json) {
    List<LatLng>? geometry;
    if (json['geometry'] != null) {
      final geometryData = json['geometry'] as List<dynamic>;
      geometry = geometryData.map((coords) {
        final coordsList = coords as List<dynamic>;
        return LatLng(
          (coordsList[1] as num).toDouble(),
          (coordsList[0] as num).toDouble(),
        );
      }).toList();
    }

    RedBusStop? departStop;
    if (json['depart_stop'] != null) {
      departStop = RedBusStop.fromJson(
        json['depart_stop'] as Map<String, dynamic>,
      );
    }

    RedBusStop? arriveStop;
    if (json['arrive_stop'] != null) {
      arriveStop = RedBusStop.fromJson(
        json['arrive_stop'] as Map<String, dynamic>,
      );
    }

    return RedBusLeg(
      type: json['type'] as String? ?? 'walk',
      mode: json['mode'] as String? ?? 'walk',
      routeNumber: json['route_number'] as String?,
      from: json['from'] as String? ?? '',
      to: json['to'] as String? ?? '',
      durationMinutes: json['duration_minutes'] as int? ?? 0,
      distanceKm: (json['distance_km'] as num?)?.toDouble() ?? 0.0,
      instruction: json['instruction'] as String? ?? '',
      geometry: geometry,
      departStop: departStop,
      arriveStop: arriveStop,
      stopCount: json['stop_count'] as int?,
    )..debugStopCount(); // Debug: imprimir stopCount
  }

  // Debug method para verificar el conteo de paradas
  void debugStopCount() {
    if (type == 'bus' && stopCount != null) {
      print('🚏 Leg de bus ${routeNumber ?? "?"} tiene $stopCount paradas');
    }
  }

  String get modeIcon {
    switch (type) {
      case 'walk':
        return '🚶';
      case 'bus':
        return '🚌';
      case 'metro':
        return '🚇';
      default:
        return '➡️';
    }
  }

  bool get isRedBus => mode == 'Red' && routeNumber != null;
}

class RedBusItinerary {
  final LatLng origin;
  final LatLng destination;
  final String departureTime;
  final String arrivalTime;
  final int totalDurationMinutes;
  final double totalDistanceKm;
  final List<RedBusLeg> legs;
  final List<String> redBusRoutes;

  RedBusItinerary({
    required this.origin,
    required this.destination,
    required this.departureTime,
    required this.arrivalTime,
    required this.totalDurationMinutes,
    required this.totalDistanceKm,
    required this.legs,
    required this.redBusRoutes,
  });

  factory RedBusItinerary.fromJson(Map<String, dynamic> json) {
    final originData = json['origin'] as Map<String, dynamic>;
    final destData = json['destination'] as Map<String, dynamic>;

    final legsData = json['legs'] as List<dynamic>? ?? [];
    final legs = legsData
        .map((l) => RedBusLeg.fromJson(l as Map<String, dynamic>))
        .toList();

    final routesData = json['red_bus_routes'] as List<dynamic>? ?? [];
    final routes = routesData.map((r) => r.toString()).toList();

    return RedBusItinerary(
      origin: LatLng(
        (originData['latitude'] as num).toDouble(),
        (originData['longitude'] as num).toDouble(),
      ),
      destination: LatLng(
        (destData['latitude'] as num).toDouble(),
        (destData['longitude'] as num).toDouble(),
      ),
      departureTime: json['departure_time'] as String? ?? '',
      arrivalTime: json['arrival_time'] as String? ?? '',
      totalDurationMinutes: json['total_duration_minutes'] as int? ?? 0,
      totalDistanceKm: (json['total_distance_km'] as num?)?.toDouble() ?? 0.0,
      legs: legs,
      redBusRoutes: routes,
    );
  }

  String get summary {
    final busCount = redBusRoutes.length;
    if (busCount == 0) {
      return 'Ruta directa - $totalDurationMinutes min';
    } else if (busCount == 1) {
      return 'Bus Red ${redBusRoutes[0]} - $totalDurationMinutes min';
    } else {
      return '$busCount buses - $totalDurationMinutes min';
    }
  }

  List<String> getVoiceInstructions() {
    return legs.map((leg) {
      if (leg.isRedBus) {
        return '${leg.instruction}. Duración aproximada: ${leg.durationMinutes} minutos.';
      }
      return '${leg.instruction}. ${leg.durationMinutes} minutos caminando.';
    }).toList();
  }
}

// ============================================================================
// ROUTE OPTIONS - Múltiples opciones de rutas para elegir
// ============================================================================

class RouteOptions {
  final LatLng origin;
  final LatLng destination;
  final List<RedBusItinerary> options;

  RouteOptions({
    required this.origin,
    required this.destination,
    required this.options,
  });

  factory RouteOptions.fromJson(Map<String, dynamic> json) {
    final originData = json['origin'] as Map<String, dynamic>;
    final destData = json['destination'] as Map<String, dynamic>;
    final optionsData = json['options'] as List<dynamic>? ?? [];

    final options = optionsData
        .map((o) => RedBusItinerary.fromJson(o as Map<String, dynamic>))
        .toList();

    return RouteOptions(
      origin: LatLng(
        (originData['latitude'] as num).toDouble(),
        (originData['longitude'] as num).toDouble(),
      ),
      destination: LatLng(
        (destData['latitude'] as num).toDouble(),
        (destData['longitude'] as num).toDouble(),
      ),
      options: options,
    );
  }

  bool get hasMultipleOptions => options.length > 1;

  int get optionsCount => options.length;

  RedBusItinerary? get firstOption => options.isNotEmpty ? options[0] : null;

  String getOptionSummary(int index) {
    if (index >= options.length) return '';
    final option = options[index];
    final routeInfo = option.redBusRoutes.isNotEmpty
        ? 'Bus ${option.redBusRoutes.join(", ")}'
        : 'Ruta directa';

    // Obtener el conteo total de paradas de los legs de bus
    int totalStops = 0;
    for (final leg in option.legs) {
      if (leg.type == 'bus' && leg.stopCount != null) {
        totalStops += leg.stopCount!;
      }
    }

    String summary =
        'Opción ${index + 1}: $routeInfo, ${option.totalDurationMinutes} minutos';
    if (totalStops > 0) {
      summary += ', $totalStops paradas';
    }
    return summary;
  }
}

// ============================================================================
// NUEVOS MODELOS PARA FLUJO DE DOS FASES (Selección por voz)
// ============================================================================

/// Opción ligera de ruta SIN geometría (para FASE 1: selección por voz)
class LightweightRouteOption {
  final int index; // 0, 1, 2 para "opción uno, dos, tres"
  final List<String> routeNumbers; // ["426"] o ["506", "210"]
  final int totalDuration; // minutos totales
  final String summary; // "Bus 426, 38 minutos"
  final int? walkingTime; // minutos de caminata (opcional)
  final int transfers; // número de transbordos

  LightweightRouteOption({
    required this.index,
    required this.routeNumbers,
    required this.totalDuration,
    required this.summary,
    this.walkingTime,
    required this.transfers,
  });

  factory LightweightRouteOption.fromJson(Map<String, dynamic> json) {
    final routeNumbersData = json['route_numbers'] as List<dynamic>? ?? [];
    final routeNumbers = routeNumbersData.map((r) => r.toString()).toList();

    return LightweightRouteOption(
      index: json['index'] as int? ?? 0,
      routeNumbers: routeNumbers,
      totalDuration: json['total_duration_minutes'] as int? ?? 0,
      summary: json['summary'] as String? ?? '',
      walkingTime: json['walking_time_minutes'] as int?,
      transfers: json['transfers'] as int? ?? 0,
    );
  }

  /// Genera texto para TTS: "Opción uno: Bus 426, 38 minutos"
  String get voiceAnnouncement {
    final optionNumber = _numberToSpanish(index + 1);
    return 'Opción $optionNumber: $summary';
  }

  /// Información adicional para TTS si hay caminata
  String get detailedAnnouncement {
    final base = voiceAnnouncement;
    if (walkingTime != null && walkingTime! > 0) {
      return '$base, incluye $walkingTime minutos de caminata';
    }
    if (transfers > 0) {
      return '$base, con $transfers ${transfers == 1 ? "transbordo" : "transbordos"}';
    }
    return base;
  }

  /// Convierte número a español para TTS
  static String _numberToSpanish(int number) {
    const numbers = {1: 'uno', 2: 'dos', 3: 'tres', 4: 'cuatro', 5: 'cinco'};
    return numbers[number] ?? number.toString();
  }
}

/// Conjunto de opciones ligeras (respuesta de FASE 1)
class LightweightRouteOptions {
  final LatLng origin;
  final LatLng destination;
  final List<LightweightRouteOption> options;

  LightweightRouteOptions({
    required this.origin,
    required this.destination,
    required this.options,
  });

  factory LightweightRouteOptions.fromJson(Map<String, dynamic> json) {
    final originData = json['origin'] as Map<String, dynamic>;
    final destData = json['destination'] as Map<String, dynamic>;
    final optionsData = json['options'] as List<dynamic>? ?? [];

    final options = optionsData
        .map((o) => LightweightRouteOption.fromJson(o as Map<String, dynamic>))
        .toList();

    return LightweightRouteOptions(
      origin: LatLng(
        (originData['latitude'] as num).toDouble(),
        (originData['longitude'] as num).toDouble(),
      ),
      destination: LatLng(
        (destData['latitude'] as num).toDouble(),
        (destData['longitude'] as num).toDouble(),
      ),
      options: options,
    );
  }

  bool get hasMultipleOptions => options.length > 1;
  int get optionsCount => options.length;
  LightweightRouteOption? get firstOption =>
      options.isNotEmpty ? options[0] : null;

  /// Genera anuncio TTS para todas las opciones
  String get fullVoiceAnnouncement {
    if (options.isEmpty) return 'No se encontraron rutas disponibles';
    if (options.length == 1) {
      return 'Se encontró una ruta: ${options[0].detailedAnnouncement}';
    }
    final announcements = options.map((o) => o.detailedAnnouncement).join('. ');
    return 'Se encontraron ${options.length} rutas. $announcements';
  }
}

// ============================================================================
// FIN DE NUEVOS MODELOS
// ============================================================================

class RedBusService {
  static final RedBusService instance = RedBusService._();
  RedBusService._();

  /// Obtiene información detallada de una ruta Red específica
  Future<RedBusRoute> getRedBusRoute(String routeNumber) async {
    try {
      final apiClient = ApiClient();
      final uri = Uri.parse('${apiClient.baseUrl}/api/red/route/$routeNumber');
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return RedBusRoute.fromJson(data);
      } else {
        throw Exception(
          'Error al obtener ruta Red $routeNumber: ${response.statusCode}',
        );
      }
    } catch (e) {
      print('Error en getRedBusRoute: $e');
      rethrow;
    }
  }

  /// Obtiene múltiples opciones de rutas usando buses Red
  Future<RouteOptions> getRouteOptions({
    required double originLat,
    required double originLon,
    required double destLat,
    required double destLon,
  }) async {
    try {
      final apiClient = ApiClient();
      final uri = Uri.parse('${apiClient.baseUrl}/api/red/itinerary');
      final body = {
        'origin_lat': originLat,
        'origin_lon': originLon,
        'dest_lat': destLat,
        'dest_lon': destLon,
      };

      print(
        '🚌 Solicitando opciones de rutas Red: origen($originLat, $originLon) -> destino($destLat, $destLon)',
      );

      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final routeOptions = RouteOptions.fromJson(data);
        print(
          '✅ Opciones de rutas obtenidas: ${routeOptions.optionsCount} opciones',
        );
        for (int i = 0; i < routeOptions.optionsCount; i++) {
          print('   ${routeOptions.getOptionSummary(i)}');
        }
        return routeOptions;
      } else {
        throw Exception(
          'Error al obtener opciones de rutas: ${response.statusCode}',
        );
      }
    } catch (e) {
      print('❌ Error en getRouteOptions: $e');
      rethrow;
    }
  }

  // ==========================================================================
  // NUEVOS MÉTODOS PARA FLUJO DE DOS FASES (Selección por voz)
  // ==========================================================================

  /// FASE 1: Obtiene opciones LIGERAS sin geometría (rápido)
  /// Úsalo cuando el usuario pida rutas por primera vez
  /// Ejemplo:
  /// ```dart
  /// final options = await RedBusService.instance.getRouteOptionsLightweight(
  ///   originLat: -33.4489,
  ///   originLon: -70.6693,
  ///   destLat: -33.4372,
  ///   destLon: -70.6506,
  /// );
  /// // TTS lee: "Opción uno: Bus 426, 38 minutos. Opción dos: ..."
  /// ```
  Future<LightweightRouteOptions> getRouteOptionsLightweight({
    required double originLat,
    required double originLon,
    required double destLat,
    required double destLon,
  }) async {
    try {
      final apiClient = ApiClient();
      final uri = Uri.parse('${apiClient.baseUrl}/api/red/itinerary/options');
      final body = {
        'origin_lat': originLat,
        'origin_lon': originLon,
        'dest_lat': destLat,
        'dest_lon': destLon,
      };

      print(
        '🚌 FASE 1: Solicitando opciones ligeras de ($originLat, $originLon) a ($destLat, $destLon)',
      );

      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final lightweightOptions = LightweightRouteOptions.fromJson(data);
        print(
          '✅ Opciones ligeras obtenidas: ${lightweightOptions.optionsCount} opciones',
        );
        for (final option in lightweightOptions.options) {
          print('   ${option.voiceAnnouncement}');
        }
        return lightweightOptions;
      } else {
        throw Exception(
          'Error al obtener opciones ligeras: ${response.statusCode}',
        );
      }
    } catch (e) {
      print('❌ Error en getRouteOptionsLightweight: $e');
      rethrow;
    }
  }

  /// FASE 2: Obtiene geometría detallada DESPUÉS de que usuario selecciona
  /// Úsalo después de que el usuario diga "opción uno" por voz
  /// Ejemplo:
  /// ```dart
  /// // Usuario dice "opción uno" (index 0)
  /// final detailed = await RedBusService.instance.getDetailedItinerary(
  ///   originLat: -33.4489,
  ///   originLon: -70.6693,
  ///   destLat: -33.4372,
  ///   destLon: -70.6506,
  ///   selectedOptionIndex: 0, // "opción uno" = index 0
  /// );
  /// // Ahora tienes geometría completa para mostrar en mapa
  /// ```
  Future<RedBusItinerary> getDetailedItinerary({
    required double originLat,
    required double originLon,
    required double destLat,
    required double destLon,
    required int selectedOptionIndex,
  }) async {
    try {
      final apiClient = ApiClient();
      final uri = Uri.parse('${apiClient.baseUrl}/api/red/itinerary/detail');
      final body = {
        'origin_lat': originLat,
        'origin_lon': originLon,
        'dest_lat': destLat,
        'dest_lon': destLon,
        'selected_option_index': selectedOptionIndex,
      };

      print(
        '🚌 FASE 2: Obteniendo geometría detallada para opción $selectedOptionIndex',
      );

      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final detailedItinerary = RedBusItinerary.fromJson(data);
        print(
          '✅ Geometría detallada obtenida: ${detailedItinerary.legs.length} segmentos',
        );
        return detailedItinerary;
      } else {
        throw Exception(
          'Error al obtener geometría detallada: ${response.statusCode}',
        );
      }
    } catch (e) {
      print('❌ Error en getDetailedItinerary: $e');
      rethrow;
    }
  }

  // ==========================================================================
  // FIN DE NUEVOS MÉTODOS
  // ==========================================================================

  /// Obtiene un itinerario completo usando buses Red (DEPRECATED - usar getRouteOptions)
  @Deprecated('Use getRouteOptions instead to get multiple route options')
  Future<RedBusItinerary> getRedBusItinerary({
    required double originLat,
    required double originLon,
    required double destLat,
    required double destLon,
  }) async {
    try {
      // Llamar a getRouteOptions y retornar la primera opción
      final routeOptions = await getRouteOptions(
        originLat: originLat,
        originLon: originLon,
        destLat: destLat,
        destLon: destLon,
      );

      if (routeOptions.firstOption != null) {
        return routeOptions.firstOption!;
      } else {
        throw Exception('No se encontraron opciones de ruta');
      }
    } catch (e) {
      print('❌ Error en getRedBusItinerary: $e');
      rethrow;
    }
  }

  /// Lista rutas Red comunes
  Future<List<Map<String, dynamic>>> getCommonRedRoutes() async {
    try {
      final apiClient = ApiClient();
      final uri = Uri.parse('${apiClient.baseUrl}/api/red/routes/common');
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final routes = data['routes'] as List<dynamic>;
        return routes.map((r) => r as Map<String, dynamic>).toList();
      } else {
        throw Exception(
          'Error al obtener rutas comunes: ${response.statusCode}',
        );
      }
    } catch (e) {
      print('Error en getCommonRedRoutes: $e');
      return [];
    }
  }

  /// Obtiene las paradas de una ruta Red
  Future<List<RedBusStop>> getRedBusStops(String routeNumber) async {
    try {
      final apiClient = ApiClient();
      final uri = Uri.parse(
        '${apiClient.baseUrl}/api/red/route/$routeNumber/stops',
      );
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final stopsData = data['stops'] as List<dynamic>;
        return stopsData
            .map((s) => RedBusStop.fromJson(s as Map<String, dynamic>))
            .toList();
      } else {
        throw Exception('Error al obtener paradas: ${response.statusCode}');
      }
    } catch (e) {
      print('Error en getRedBusStops: $e');
      return [];
    }
  }

  /// Obtiene la geometría de una ruta Red para visualización en mapa
  Future<Map<String, dynamic>> getRedBusGeometry(String routeNumber) async {
    try {
      final apiClient = ApiClient();
      final uri = Uri.parse(
        '${apiClient.baseUrl}/api/red/route/$routeNumber/geometry',
      );
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      } else {
        throw Exception('Error al obtener geometría: ${response.statusCode}');
      }
    } catch (e) {
      print('Error en getRedBusGeometry: $e');
      return {};
    }
  }

  /// Busca rutas Red por query
  Future<List<Map<String, dynamic>>> searchRedRoutes(String query) async {
    try {
      final apiClient = ApiClient();
      final uri = Uri.parse(
        '${apiClient.baseUrl}/api/red/routes/search?q=$query',
      );
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final results = data['results'] as List<dynamic>;
        return results.map((r) => r as Map<String, dynamic>).toList();
      } else {
        return [];
      }
    } catch (e) {
      print('Error en searchRedRoutes: $e');
      return [];
    }
  }
}
