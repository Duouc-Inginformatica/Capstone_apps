// ============================================================================
// INTEGRATED NAVIGATION SERVICE
// ============================================================================
// Combina Moovit scraping + GTFS data para navegación completa
// Detecta llegada a paraderos y guía al usuario en tiempo real
// ============================================================================

import 'dart:async';
import 'dart:math' as math;
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'red_bus_service.dart';
import 'api_client.dart';
import 'tts_service.dart';
import 'server_config.dart';

class NavigationStep {
  final String type; // 'walk', 'wait_bus', 'ride_bus', 'transfer', 'arrival'
  final String instruction;
  final LatLng? location;
  final String? stopId;
  final String? stopName;
  final String? busRoute;
  final List<String>? busOptions; // Para paraderos con múltiples buses
  final int estimatedDuration;
  final bool isCompleted;
  final int? totalStops; // Número total de paradas en el viaje
  final int? currentStop; // Parada actual (para contar progreso)
  final double? realDistanceMeters; // Distancia real por calles (de OSRM)
  final int? realDurationSeconds; // Duración real (de OSRM)
  final List<String>?
  streetInstructions; // Instrucciones detalladas por calle (de OSRM)

  NavigationStep({
    required this.type,
    required this.instruction,
    this.location,
    this.stopId,
    this.stopName,
    this.busRoute,
    this.busOptions,
    required this.estimatedDuration,
    this.isCompleted = false,
    this.totalStops,
    this.currentStop,
    this.realDistanceMeters,
    this.realDurationSeconds,
    this.streetInstructions,
  });

  NavigationStep copyWith({
    bool? isCompleted,
    int? currentStop,
    double? realDistanceMeters,
    int? realDurationSeconds,
    List<String>? streetInstructions,
  }) {
    return NavigationStep(
      type: type,
      instruction: instruction,
      location: location,
      stopId: stopId,
      stopName: stopName,
      busRoute: busRoute,
      busOptions: busOptions,
      estimatedDuration: estimatedDuration,
      isCompleted: isCompleted ?? this.isCompleted,
      totalStops: totalStops,
      currentStop: currentStop ?? this.currentStop,
      realDistanceMeters: realDistanceMeters ?? this.realDistanceMeters,
      realDurationSeconds: realDurationSeconds ?? this.realDurationSeconds,
      streetInstructions: streetInstructions ?? this.streetInstructions,
    );
  }
}

class ActiveNavigation {
  final String destination;
  final List<NavigationStep> steps;
  final List<LatLng> routeGeometry; // Geometría completa (para referencia)
  final Map<int, List<LatLng>> stepGeometries; // Geometría por cada paso
  final RedBusItinerary itinerary;
  final int estimatedDuration; // Duración total estimada en minutos
  int currentStepIndex;

  ActiveNavigation({
    required this.destination,
    required this.steps,
    required this.routeGeometry,
    required this.stepGeometries,
    required this.itinerary,
    required this.estimatedDuration,
    this.currentStepIndex = 0,
  });

  NavigationStep? get currentStep =>
      currentStepIndex < steps.length ? steps[currentStepIndex] : null;

  // Geometría solo del paso ACTUAL usando el mapa de geometrías
  List<LatLng> getCurrentStepGeometry(LatLng currentPosition) {
    final step = currentStep;
    if (step == null) {
      print('🔍 getCurrentStepGeometry: step es null');
      return [];
    }

    print(
      '🔍 getCurrentStepGeometry: Paso actual = ${step.type} (índice $currentStepIndex)',
    );
    print('🔍 Geometrías disponibles: ${stepGeometries.keys.toList()}');

    // Si tenemos geometría pre-calculada para este paso, usarla
    if (stepGeometries.containsKey(currentStepIndex)) {
      final geometry = stepGeometries[currentStepIndex]!;
      print(
        '🔍 Geometría encontrada para paso $currentStepIndex: ${geometry.length} puntos',
      );

      // Si es paso de walk o ride_bus, recortar geometría desde el punto más cercano al usuario
      if ((step.type == 'walk' || step.type == 'ride_bus') &&
          geometry.length >= 2) {
        print(
          '🔍 Paso ${step.type.toUpperCase()}: Recortando geometría desde posición actual',
        );

        // Encontrar el punto más cercano en la ruta al usuario
        int closestIndex = 0;
        double minDistance = double.infinity;

        for (int i = 0; i < geometry.length; i++) {
          final point = geometry[i];
          final distance = _calculateDistance(
            currentPosition.latitude,
            currentPosition.longitude,
            point.latitude,
            point.longitude,
          );

          if (distance < minDistance) {
            minDistance = distance;
            closestIndex = i;
          }
        }

        print(
          '🔍 Punto más cercano: índice $closestIndex (${minDistance.toStringAsFixed(0)}m)',
        );

        // Si el usuario está muy cerca del punto más cercano (< 10m), usar ese punto
        // Si no, agregar la posición actual como primer punto
        if (minDistance < 10) {
          // Usuario muy cerca de la ruta, usar desde el punto más cercano
          return geometry.sublist(closestIndex);
        } else {
          // Usuario lejos de la ruta, agregar su posición y continuar desde el punto más cercano
          return [currentPosition, ...geometry.sublist(closestIndex)];
        }
      }

      print('🔍 Retornando geometría pre-calculada');
      return geometry;
    }

    print('⚠️ No hay geometría pre-calculada para paso $currentStepIndex');

    // Fallback: generar geometría básica
    if (step.location != null) {
      if (step.type == 'walk') {
        print('🔍 Fallback: Creando geometría básica para WALK');
        return [currentPosition, step.location!];
      }
    }

    print('⚠️ Sin geometría para este paso');
    return []; // Sin geometría
  }

  /// Calcula distancia en metros entre dos coordenadas
  double _calculateDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const double earthRadius = 6371000; // Radio de la Tierra en metros
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);

    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRadians(lat1)) *
            math.cos(_toRadians(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);

    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadius * c;
  }

  double _toRadians(double degrees) {
    return degrees * math.pi / 180;
  }

  bool get isComplete => currentStepIndex >= steps.length;

  void advanceToNextStep() {
    if (!isComplete) {
      currentStepIndex++;
    }
  }
}

class IntegratedNavigationService {
  static final IntegratedNavigationService instance =
      IntegratedNavigationService._();
  IntegratedNavigationService._();

  final RedBusService _redBusService = RedBusService.instance;
  final ApiClient _apiClient = ApiClient();
  final Distance _distance = const Distance();

  ActiveNavigation? _activeNavigation;
  StreamSubscription<Position>? _positionStream;
  Position? _lastPosition; // Última posición GPS recibida

  // Callbacks
  Function(NavigationStep)? onStepChanged;
  Function(String)? onArrivalAtStop;
  Function()? onDestinationReached;
  Function(String)? onBusDetected;
  Function()? onGeometryUpdated; // Nuevo: se llama cuando la geometría cambia

  // Configuración de umbrales adaptativos
  static const double ARRIVAL_THRESHOLD_METERS =
      30.0; // 30m para considerar "llegada" (más estricto)
  static const double PROXIMITY_ALERT_METERS =
      150.0; // 150m para alertar proximidad
  static const double GPS_ACCURACY_THRESHOLD =
      20.0; // Precisión GPS mínima aceptable (metros)
  static const double MAX_ARRIVAL_THRESHOLD =
      50.0; // Umbral máximo incluso con GPS impreciso

  // Histórico de posiciones para suavizar detección
  final List<Position> _positionHistory = [];
  static const int MAX_POSITION_HISTORY = 5;

  // Control de anuncios duplicados
  int? _lastProximityAnnouncedStepIndex;
  int? _lastArrivalAnnouncedStepIndex;

  /// Inicia navegación completa desde ubicación actual a destino
  Future<ActiveNavigation> startNavigation({
    required double originLat,
    required double originLon,
    required double destLat,
    required double destLon,
    required String destinationName,
    RedBusItinerary? existingItinerary, // Usar itinerario ya obtenido si existe
  }) async {
    print('🚀 Iniciando navegación integrada a $destinationName');

    // Inicializar posición actual
    try {
      _lastPosition = await Geolocator.getCurrentPosition();
    } catch (e) {
      print('⚠️ No se pudo obtener posición actual: $e');
      // Usar coordenadas del origen como fallback
      _lastPosition = Position(
        latitude: originLat,
        longitude: originLon,
        timestamp: DateTime.now(),
        accuracy: 0,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );
    }

    // 1. Usar itinerario existente o solicitar uno nuevo
    final RedBusItinerary itinerary;
    if (existingItinerary != null) {
      print('♻️ Usando itinerario ya obtenido (evita llamada duplicada)');
      itinerary = existingItinerary;
    } else {
      print('🔄 Solicitando nuevo itinerario al backend...');
      itinerary = await _redBusService.getRedBusItinerary(
        originLat: originLat,
        originLon: originLon,
        destLat: destLat,
        destLon: destLon,
      );
    }

    print('📋 Itinerario obtenido: ${itinerary.summary}');
    print('🚌 Buses Red recomendados: ${itinerary.redBusRoutes.join(", ")}');

    // 2. Construir pasos de navegación detallados
    final steps = await _buildNavigationSteps(itinerary, originLat, originLon);

    // 3. Obtener geometría completa de la ruta
    final geometry = await _buildCompleteRouteGeometry(itinerary);

    // 4. Construir geometrías individuales para cada paso
    final stepGeometries = await _buildStepGeometries(
      steps,
      itinerary,
      LatLng(originLat, originLon),
    );

    // 5. Calcular duración total estimada
    final totalDuration = itinerary.legs.fold<int>(
      0,
      (sum, leg) => sum + leg.durationMinutes,
    );

    // 6. Crear navegación activa
    _activeNavigation = ActiveNavigation(
      destination: destinationName,
      steps: steps,
      routeGeometry: geometry,
      stepGeometries: stepGeometries,
      itinerary: itinerary,
      estimatedDuration: totalDuration,
    );

    // 7. Reiniciar control de anuncios
    _lastProximityAnnouncedStepIndex = null;
    _lastArrivalAnnouncedStepIndex = null;

    // 8. Anunciar inicio de navegación
    _announceNavigationStart(destinationName, itinerary);

    // 9. Iniciar seguimiento GPS
    _startLocationTracking();

    return _activeNavigation!;
  }

  /// Construye pasos de navegación detallados desde el itinerario
  Future<List<NavigationStep>> _buildNavigationSteps(
    RedBusItinerary itinerary,
    double currentLat,
    double currentLon,
  ) async {
    final steps = <NavigationStep>[];

    print('🚶 Construyendo pasos de navegación...');
    print('🚶 Legs del itinerario: ${itinerary.legs.length}');

    // Procesar TODOS los legs del itinerario tal como vienen del backend
    for (var i = 0; i < itinerary.legs.length; i++) {
      final leg = itinerary.legs[i];

      if (leg.type == 'walk') {
        // Obtener ruta peatonal detallada desde OSRM
        final walkFrom =
            leg.departStop?.location ?? LatLng(currentLat, currentLon);
        final walkTo = leg.arriveStop?.location;

        if (walkTo != null) {
          print('🚶 Obteniendo ruta peatonal detallada...');
          print('   Desde: ${walkFrom.latitude},${walkFrom.longitude}');
          print(
            '   Hasta: ${walkTo.latitude},${walkTo.longitude} (${leg.arriveStop?.name})',
          );

          // Solicitar ruta de OSRM en modo peatonal
          final osrmRoute = await _getOSRMWalkingRoute(walkFrom, walkTo);

          if (osrmRoute != null && osrmRoute['steps'] != null) {
            // Agregar cada paso de OSRM como un paso de navegación
            final osrmSteps = osrmRoute['steps'] as List<dynamic>;
            print('✅ ${osrmSteps.length} pasos OSRM obtenidos');

            for (var osrmStep in osrmSteps) {
              final instruction = osrmStep['instruction'] as String?;
              final duration = osrmStep['duration'] as num?;

              if (instruction != null &&
                  !instruction.toLowerCase().contains('arrive')) {
                steps.add(
                  NavigationStep(
                    type: 'walk',
                    instruction: instruction,
                    location: walkTo, // Usar destino como referencia
                    stopName: leg.arriveStop?.name,
                    estimatedDuration: duration != null
                        ? (duration / 60).ceil()
                        : 1,
                  ),
                );
              }
            }
            print('✅ Pasos WALK detallados agregados desde OSRM');
          } else {
            // Fallback: usar instrucción simple del backend
            steps.add(
              NavigationStep(
                type: 'walk',
                instruction: leg.instruction.isNotEmpty
                    ? leg.instruction
                    : 'Camina ${(leg.distanceKm * 1000).toInt()} metros hasta ${leg.arriveStop?.name}',
                location: walkTo,
                stopName: leg.arriveStop?.name,
                estimatedDuration: leg.durationMinutes,
              ),
            );
            print('⚠️ Paso WALK simple agregado (OSRM no disponible)');
          }
        }
      } else if (leg.type == 'bus' && leg.isRedBus) {
        // Esperar el bus
        final stopInfo = await _getStopInfoFromGTFS(leg.departStop?.name ?? '');
        final busOptions = await _getBusesAtStop(stopInfo?['stop_id'] ?? '');

        steps.add(
          NavigationStep(
            type: 'wait_bus',
            instruction:
                'Espera el bus Red ${leg.routeNumber} en ${leg.departStop?.name ?? 'este paradero'}',
            location:
                null, // NO tiene location - el usuario ya llegó en el paso 'walk'
            stopId: stopInfo?['stop_id'],
            stopName: leg.departStop?.name,
            busRoute: leg.routeNumber,
            busOptions: busOptions,
            estimatedDuration: 5, // Estimado de espera
          ),
        );

        // Viajar en el bus
        steps.add(
          NavigationStep(
            type: 'ride_bus',
            instruction:
                'Viaja en el bus Red ${leg.routeNumber} hasta ${leg.arriveStop?.name ?? 'tu parada de destino'}',
            location: leg.arriveStop?.location,
            stopId: await _getStopId(leg.arriveStop?.name ?? ''),
            stopName: leg.arriveStop?.name,
            busRoute: leg.routeNumber,
            estimatedDuration: leg.durationMinutes,
            totalStops: leg.stopCount, // Número de paradas desde el backend
          ),
        );
      }
    }

    // Paso final: llegada
    steps.add(
      NavigationStep(
        type: 'arrival',
        instruction: 'Has llegado a tu destino: ${itinerary.destination}',
        location: itinerary.destination,
        estimatedDuration: 0,
      ),
    );

    // Log de todos los pasos generados
    print('🚶 ===== PASOS DE NAVEGACIÓN GENERADOS =====');
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      print('🚶 Paso $i: ${step.type} - ${step.instruction}');
      if (step.type == 'wait_bus') {
        print('   └─ Bus: ${step.busRoute}, StopName: ${step.stopName}');
      }
    }
    print('🚶 ==========================================');

    return steps;
  }

  /// Calcula distancia en metros entre dos puntos geográficos (fórmula Haversine)
  double _calculateDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadius = 6371000; // Radio de la Tierra en metros
    final dLat = _degreesToRadians(lat2 - lat1);
    final dLon = _degreesToRadians(lon2 - lon1);

    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degreesToRadians(lat1)) *
            math.cos(_degreesToRadians(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);

    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadius * c;
  }

  double _degreesToRadians(double degrees) {
    return degrees * math.pi / 180;
  }

  /// Encuentra el paradero más cercano usando GTFS
  Future<Map<String, dynamic>?> _findNearestStop(double lat, double lon) async {
    try {
      final stops = await _apiClient.getNearbyStops(
        lat: lat,
        lon: lon,
        radius: 500,
        limit: 1,
      );

      if (stops.isNotEmpty) {
        return stops.first as Map<String, dynamic>;
      }
    } catch (e) {
      print('Error buscando paradero cercano: $e');
    }
    return null;
  }

  /// Obtiene información del paradero desde GTFS por nombre
  Future<Map<String, dynamic>?> _getStopInfoFromGTFS(String stopName) async {
    // En producción, esto debería hacer una búsqueda en el backend
    // Por ahora, retornamos datos simulados
    return {
      'stop_id': 'PJ178',
      'stop_name': stopName,
      'stop_lat': -33.437,
      'stop_lon': -70.650,
    };
  }

  /// Obtiene lista de buses que pasan por un paradero
  Future<List<String>> _getBusesAtStop(String stopId) async {
    // Consultar GTFS para obtener rutas que pasan por este paradero
    // Por ahora retornamos los de ejemplo
    return ['426', '406', '422'];
  }

  /// Obtiene el ID del paradero por nombre
  Future<String?> _getStopId(String stopName) async {
    final stopInfo = await _getStopInfoFromGTFS(stopName);
    return stopInfo?['stop_id'];
  }

  /// Construye la geometría completa de la ruta
  Future<List<LatLng>> _buildCompleteRouteGeometry(
    RedBusItinerary itinerary,
  ) async {
    final geometry = <LatLng>[];

    for (var leg in itinerary.legs) {
      if (leg.geometry != null && leg.geometry!.isNotEmpty) {
        geometry.addAll(leg.geometry!);
      } else if (leg.departStop != null && leg.arriveStop != null) {
        // Si no hay geometría, crear línea recta entre puntos
        geometry.add(leg.departStop!.location);
        geometry.add(leg.arriveStop!.location);
      }
    }

    return geometry;
  }

  /// Obtiene geometría de ruta peatonal usando OSRM
  /// Retorna: (geometría, distancia en metros, duración en segundos, instrucciones detalladas)
  Future<
    ({
      List<LatLng> geometry,
      double distance,
      int duration,
      List<String> streetInstructions,
    })?
  >
  _getWalkingRouteGeometry(LatLng origin, LatLng destination) async {
    try {
      // Solicitar múltiples rutas alternativas y elegir la mejor
      // alternatives=true: pide hasta 3 rutas alternativas
      // continue_straight=true: prefiere rutas sin giros innecesarios
      final baseUrl = ServerConfig.instance.osrmUrl;
      final profile = ServerConfig.instance.osrmProfile;
      final url =
          '$baseUrl/route/v1/$profile/${origin.longitude},${origin.latitude};${destination.longitude},${destination.latitude}?overview=full&geometries=geojson&steps=true&annotations=true&alternatives=true&continue_straight=true';

      print('🗺️ [OSRM] Solicitando mejores rutas alternativas...');
      print('🗺️ [OSRM] URL: $baseUrl');

      final response = await http
          .get(Uri.parse(url))
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              throw TimeoutException('OSRM request timeout');
            },
          );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['code'] == 'Ok' &&
            data['routes'] != null &&
            data['routes'].isNotEmpty) {
          // Analizar todas las rutas alternativas
          final routes = data['routes'] as List;
          print(
            '🗺️ [OSRM] Se encontraron ${routes.length} rutas alternativas',
          );

          // Seleccionar la mejor ruta basándose en criterios
          var bestRoute = routes[0];
          var bestScore = double.infinity;

          for (var i = 0; i < routes.length; i++) {
            final route = routes[i];
            final distance = (route['distance'] as num).toDouble();
            final duration = (route['duration'] as num).toInt();
            final steps = (route['legs'][0]['steps'] as List).length;

            // Calcular score: priorizar distancia (70%) y tiempo (30%)
            // Menos giros (steps) es un bonus
            final distanceScore = distance / 1000; // normalizar a km
            final durationScore = duration / 60; // normalizar a minutos
            final turnsScore = steps * 0.5; // penalizar giros extras

            final score =
                (distanceScore * 0.5) +
                (durationScore * 0.3) +
                (turnsScore * 0.2);

            print(
              '🗺️ [OSRM] Ruta $i: ${distance.toInt()}m, ${duration}s, $steps pasos, score: ${score.toStringAsFixed(2)}',
            );

            if (score < bestScore) {
              bestScore = score;
              bestRoute = route;
            }
          }

          final coordinates = bestRoute['geometry']['coordinates'] as List;

          // Convertir de [lon, lat] a LatLng
          final geometry = coordinates.map<LatLng>((coord) {
            return LatLng(coord[1] as double, coord[0] as double);
          }).toList();

          // Extraer distancia y duración de OSRM
          final distanceMeters = (bestRoute['distance'] as num).toDouble();
          final durationSeconds = (bestRoute['duration'] as num).toInt();

          // Extraer instrucciones paso a paso con nombres de calles
          final streetInstructions = <String>[];
          if (bestRoute['legs'] != null && bestRoute['legs'].isNotEmpty) {
            final legs = bestRoute['legs'] as List;
            for (var leg in legs) {
              if (leg['steps'] != null) {
                final steps = leg['steps'] as List;
                for (var step in steps) {
                  final name = step['name'] ?? '';
                  final maneuver = step['maneuver'];
                  if (maneuver != null && name.isNotEmpty && name != '-') {
                    final type = maneuver['type'] ?? '';
                    final modifier = maneuver['modifier'] ?? '';
                    final distance =
                        (step['distance'] as num?)?.toDouble() ?? 0;

                    // Crear instrucción legible
                    String instruction = _buildStreetInstruction(
                      type,
                      modifier,
                      name,
                      distance,
                    );
                    if (instruction.isNotEmpty) {
                      streetInstructions.add(instruction);
                    }
                  }
                }
              }
            }
          }

          print('🗺️ [OSRM] Ruta obtenida: ${geometry.length} puntos');
          print('🗺️ [OSRM] Instrucciones: ${streetInstructions.length} pasos');

          // Mostrar todas las instrucciones para debugging
          if (streetInstructions.isNotEmpty) {
            print('📍 [OSRM] Instrucciones detalladas:');
            for (int i = 0; i < streetInstructions.length; i++) {
              print('   ${i + 1}. ${streetInstructions[i]}');
            }
          }

          final distanceKm = distanceMeters / 1000;
          final durationMin = durationSeconds / 60;
          print(
            '🗺️ [OSRM] Distancia: ${distanceKm.toStringAsFixed(2)}km, Duración: ${durationMin.toStringAsFixed(1)}min',
          );

          return (
            geometry: geometry,
            distance: distanceMeters,
            duration: durationSeconds,
            streetInstructions: streetInstructions,
          );
        }
      }

      print('⚠️ [OSRM] Error HTTP: ${response.statusCode}');
    } catch (e) {
      print('❌ [OSRM] Error obteniendo ruta: $e');
    }

    // Fallback: línea recta si falla OSRM
    print('⚠️ [OSRM] Usando fallback: línea recta');
    return null;
  }

  /// Obtiene geometría de ruta vehicular usando OSRM (para buses)
  /// Usa el perfil 'driving' para seguir calles vehiculares
  Future<({List<LatLng> geometry, double distance, int duration})?>
  _getBusRouteGeometry(LatLng origin, LatLng destination) async {
    try {
      // Solicitar rutas alternativas y elegir la mejor para buses
      final baseUrl = ServerConfig.instance.osrmUrl;
      final url =
          '$baseUrl/route/v1/driving/${origin.longitude},${origin.latitude};${destination.longitude},${destination.latitude}?overview=full&geometries=geojson&alternatives=true&continue_straight=true';

      print('🚌 [OSRM-BUS] Solicitando mejores rutas vehiculares...');
      print('🚌 [OSRM-BUS] De: ${origin.latitude},${origin.longitude}');
      print(
        '🚌 [OSRM-BUS] A: ${destination.latitude},${destination.longitude}',
      );

      final response = await http
          .get(Uri.parse(url))
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              throw TimeoutException('OSRM bus route timeout');
            },
          );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['routes'] != null && data['routes'].isNotEmpty) {
          final routes = data['routes'] as List;
          print(
            '🚌 [OSRM-BUS] Se encontraron ${routes.length} rutas alternativas',
          );

          // Para buses, priorizar la ruta más rápida (tiempo es más importante)
          var bestRoute = routes[0];
          var bestDuration = double.infinity;

          for (var i = 0; i < routes.length; i++) {
            final route = routes[i];
            final distance = (route['distance'] as num).toDouble();
            final duration = (route['duration'] as num).toInt();

            print(
              '🚌 [OSRM-BUS] Ruta $i: ${(distance / 1000).toStringAsFixed(2)}km, ${(duration / 60).toStringAsFixed(1)}min',
            );

            // Para buses, priorizar tiempo sobre distancia
            if (duration < bestDuration) {
              bestDuration = duration.toDouble();
              bestRoute = route;
            }
          }

          final geometryData = bestRoute['geometry'];

          // Extraer distancia y duración
          final distanceMeters = (bestRoute['distance'] as num).toDouble();
          final durationSeconds = (bestRoute['duration'] as num).toInt();

          // Decodificar geometría
          final coordinates = geometryData['coordinates'] as List;
          final geometry = coordinates
              .map((coord) => LatLng(coord[1] as double, coord[0] as double))
              .toList();

          print('🚌 [OSRM-BUS] ✅ Mejor ruta: ${geometry.length} puntos');
          print(
            '🚌 [OSRM-BUS] Distancia: ${(distanceMeters / 1000).toStringAsFixed(2)}km, Duración: ${(durationSeconds / 60).toStringAsFixed(1)}min',
          );

          return (
            geometry: geometry,
            distance: distanceMeters,
            duration: durationSeconds,
          );
        }
      }

      print('⚠️ [OSRM-BUS] Error HTTP: ${response.statusCode}');
    } catch (e) {
      print('❌ [OSRM-BUS] Error obteniendo ruta: $e');
    }

    // Fallback: retornar null para usar geometría del backend
    print('⚠️ [OSRM-BUS] Usando fallback');
    return null;
  }

  /// Construye una instrucción legible en español desde los datos de OSRM
  String _buildStreetInstruction(
    String type,
    String modifier,
    String name,
    double distance,
  ) {
    String action = '';

    switch (type) {
      case 'depart':
        action = 'Comienza en';
        break;
      case 'arrive':
        action = 'Llegas a';
        break;
      case 'turn':
        if (modifier.contains('left')) {
          action = 'Gira a la izquierda en';
        } else if (modifier.contains('right')) {
          action = 'Gira a la derecha en';
        } else if (modifier.contains('straight')) {
          action = 'Continúa recto por';
        } else {
          action = 'Gira en';
        }
        break;
      case 'new name':
        action = 'Continúa por';
        break;
      case 'continue':
        action = 'Continúa por';
        break;
      case 'merge':
        action = 'Incorpórate a';
        break;
      case 'roundabout':
        action = 'Toma la rotonda hacia';
        break;
      default:
        action = 'Continúa por';
    }

    if (distance > 0 && distance < 10) {
      return '$action $name';
    } else if (distance >= 10) {
      return '$action $name (${distance.toStringAsFixed(0)}m)';
    }

    return '$action $name';
  }

  /// Construye geometrías individuales para cada paso de navegación
  Future<Map<int, List<LatLng>>> _buildStepGeometries(
    List<NavigationStep> steps,
    RedBusItinerary itinerary,
    LatLng origin,
  ) async {
    final geometries = <int, List<LatLng>>{};

    print('🗺️ Construyendo geometrías para ${steps.length} pasos');

    for (int i = 0; i < steps.length; i++) {
      final step = steps[i];
      final stepGeometry = <LatLng>[];

      print('🗺️ Paso $i: ${step.type}');

      switch (step.type) {
        case 'walk':
          // Geometría de caminata: obtener ruta peatonal real usando OSRM
          if (step.location != null) {
            print('   🚶 WALK: Obteniendo ruta peatonal desde OSRM...');
            final walkRoute = await _getWalkingRouteGeometry(
              origin,
              step.location!,
            );

            if (walkRoute != null) {
              stepGeometry.addAll(walkRoute.geometry);
              print(
                '   ✅ WALK: Ruta peatonal obtenida (${walkRoute.geometry.length} puntos, ${walkRoute.distance.toStringAsFixed(0)}m, ${walkRoute.duration}s)',
              );
              print(
                '   📍 Instrucciones: ${walkRoute.streetInstructions.length} pasos',
              );

              // Actualizar step con distancia, duración e instrucciones reales de OSRM
              steps[i] = step.copyWith(
                realDistanceMeters: walkRoute.distance,
                realDurationSeconds: walkRoute.duration,
                streetInstructions: walkRoute.streetInstructions,
              );
            } else {
              // Fallback: línea recta si OSRM falla
              stepGeometry.add(origin);
              stepGeometry.add(step.location!);
              print(
                '   ⚠️ WALK: Usando fallback línea recta ${origin.latitude},${origin.longitude} → ${step.location!.latitude},${step.location!.longitude}',
              );
            }
          }
          break;

        case 'ride_bus':
          // Geometría del bus: PRIORIZAR geometría del backend (paraderos reales)
          print('   🚌 RIDE_BUS: Buscando geometría de paraderos reales...');

          // PRIMERO: Intentar usar geometría del backend con paraderos reales
          bool foundBackendGeometry = false;
          for (var leg in itinerary.legs) {
            if (leg.type == 'bus' &&
                leg.routeNumber == step.busRoute &&
                leg.geometry != null &&
                leg.geometry!.isNotEmpty) {
              stepGeometry.addAll(leg.geometry!);
              print(
                '   ✅ RIDE_BUS: Geometría con paraderos reales del backend (${leg.geometry!.length} puntos)',
              );
              foundBackendGeometry = true;
              break;
            }
          }

          // SOLO si no hay geometría del backend, usar OSRM como fallback
          if (!foundBackendGeometry) {
            print(
              '   ⚠️ RIDE_BUS: No hay geometría del backend, intentando OSRM...',
            );

            // Encontrar paradero de inicio (del paso anterior wait_bus)
            LatLng? busStartLocation;
            if (i > 0) {
              final prevStep = steps[i - 1];
              if (prevStep.type == 'wait_bus') {
                // Buscar la ubicación del paradero de partida
                for (var leg in itinerary.legs) {
                  if (leg.type == 'bus' &&
                      leg.routeNumber == step.busRoute &&
                      leg.departStop != null) {
                    busStartLocation = leg.departStop!.location;
                    print('   🚌 Paradero inicio: ${leg.departStop!.name}');
                    break;
                  }
                }
              }
            }

            if (busStartLocation != null && step.location != null) {
              // Usar OSRM con perfil 'driving' para obtener ruta vehicular
              print('   🚌 Solicitando ruta vehicular a OSRM como fallback...');

              final busRoute = await _getBusRouteGeometry(
                busStartLocation,
                step.location!,
              );

              if (busRoute != null && busRoute.geometry.length > 2) {
                stepGeometry.addAll(busRoute.geometry);
                print(
                  '   ✅ RIDE_BUS: Ruta OSRM obtenida (${busRoute.geometry.length} puntos, ${(busRoute.distance / 1000).toStringAsFixed(2)}km)',
                );
              } else {
                // Si OSRM también falla, usar línea recta
                if (stepGeometry.isEmpty) {
                  stepGeometry.add(busStartLocation);
                  stepGeometry.add(step.location!);
                  print('   ⚠️ RIDE_BUS: OSRM falló, usando línea recta');
                }
              }
            } else {
              // Sin ubicación de inicio o destino, no se puede calcular ruta
              print(
                '   ⚠️ RIDE_BUS: No se pudo determinar ubicaciones para OSRM',
              );
            }
          }
          break;

        case 'wait_bus':
          // No hay geometría para esperar en el paradero
          print('   ℹ️ WAIT_BUS: Sin geometría (correcto)');
          break;
      }

      if (stepGeometry.isNotEmpty) {
        geometries[i] = stepGeometry;
        print(
          '   📍 Guardada geometría para paso $i con ${stepGeometry.length} puntos',
        );
      }
    }

    print('🗺️ Total de geometrías creadas: ${geometries.length}');
    print('🗺️ Índices con geometría: ${geometries.keys.toList()}');

    return geometries;
  }

  /// Anuncia el inicio de navegación por voz
  void _announceNavigationStart(String destination, RedBusItinerary itinerary) {
    print('🔊 [TTS] _announceNavigationStart llamado');
    print('🔊 [TTS] _activeNavigation != null? ${_activeNavigation != null}');

    // Construir mensaje detallado del viaje
    final busLegs = itinerary.legs.where((leg) => leg.type == 'bus').toList();

    String busInfo = '';
    String arrivalInfo = '';
    if (busLegs.isNotEmpty) {
      final firstBusLeg = busLegs.first;
      busInfo = 'Debes tomar el bus ${firstBusLeg.routeNumber}';

      // Calcular tiempo de llegada de la micro (estimado en base al tiempo de caminata)
      int walkTimeMinutes = 0;
      if (_activeNavigation?.currentStep?.type == 'walk') {
        walkTimeMinutes = _activeNavigation!.currentStep!.estimatedDuration;
      }

      // Tiempo estimado hasta que llegue la micro (caminata + espera promedio de 5-10 min)
      final estimatedArrivalMinutes =
          walkTimeMinutes + 7; // Promedio 7 min de espera
      arrivalInfo =
          'La micro llegará en aproximadamente $estimatedArrivalMinutes minutos';

      if (busLegs.length > 1) {
        busInfo += ' y luego harás ${busLegs.length - 1} transbordo';
        if (busLegs.length > 2) busInfo += 's';
      }
      busInfo += '. ';
    }

    // SOLO construir instrucción del primer paso si es caminata
    String firstStepInstruction = '';
    if (_activeNavigation?.currentStep != null) {
      final step = _activeNavigation!.currentStep!;
      print('🔊 [TTS] currentStep.type = ${step.type}');
      print('🔊 [TTS] currentStep.stopName = ${step.stopName}');
      print('🔊 [TTS] currentStep.instruction = ${step.instruction}');

      // SOLO anunciar el primer paso si es 'walk'
      if (step.type == 'walk' && step.stopName != null) {
        final distance = (step.estimatedDuration * 80).toInt();
        firstStepInstruction =
            'Dirígete caminando hacia el paradero ${step.stopName}. '
            'Distancia aproximada: $distance metros. '
            'Tiempo estimado: ${step.estimatedDuration} minuto';
        if (step.estimatedDuration > 1) firstStepInstruction += 's';
        firstStepInstruction += '. ';

        // Agregar info de la micro
        firstStepInstruction += '$busInfo$arrivalInfo. ';

        // Agregar instrucciones de calle si están disponibles
        if (step.streetInstructions != null &&
            step.streetInstructions!.isNotEmpty) {
          final firstStreetInstruction = step.streetInstructions!.first;
          firstStepInstruction += 'Comienza así: $firstStreetInstruction. ';
        }

        print('🔊 [TTS] firstStepInstruction creado: $firstStepInstruction');
      } else {
        print(
          '🔊 [TTS] NO se creó firstStepInstruction (type=${step.type}, stopName=${step.stopName})',
        );
      }
    } else {
      print('🔊 [TTS] currentStep es NULL');
    }

    // Mensaje inicial completo y directo
    String message;
    if (firstStepInstruction.isNotEmpty) {
      message = firstStepInstruction.trim();
    } else {
      // Caso sin caminata (raro): anunciar info completa
      message =
          '''
Ruta calculada hacia $destination. 
$busInfo$arrivalInfo
Duración total estimada: ${itinerary.totalDurationMinutes} minutos. 
Te iré guiando paso a paso.
''';
    }

    print('🔊 [TTS] Mensaje completo a anunciar:');
    print('🔊 [TTS] ===========================');
    print(message);
    print('🔊 [TTS] ===========================');

    // Una sola llamada TTS para todo el anuncio inicial
    TtsService.instance.speak(message, urgent: true);
  }

  /// Anuncia el paso actual con detalles
  void _announceCurrentStep(NavigationStep step) {
    String announcement = '';

    switch (step.type) {
      case 'walk':
        if (step.stopName != null) {
          final distance = (step.estimatedDuration * 80)
              .toInt(); // ~80m/min velocidad caminata
          announcement =
              'Dirígete caminando hacia el paradero ${step.stopName}. '
              'Distancia aproximada: $distance metros. '
              'Tiempo estimado: ${step.estimatedDuration} minuto';
          if (step.estimatedDuration > 1) announcement += 's';
        } else {
          announcement = step.instruction;
        }
        break;

      case 'wait_bus':
        announcement =
            'Has llegado al paradero ${step.stopName ?? ""}. '
            'Espera el bus ${step.busRoute}. ';

        if (step.busOptions != null && step.busOptions!.length > 1) {
          announcement +=
              'Otros buses que pasan por aquí: ${step.busOptions!.join(", ")}. ';
        }

        announcement += 'Te avisaré cuando llegue tu bus.';
        break;

      case 'ride_bus':
        announcement =
            'Sube al bus ${step.busRoute}. '
            'Debes bajar en ${step.stopName ?? "tu parada de destino"}. ';

        if (step.totalStops != null && step.totalStops! > 0) {
          announcement += 'Son ${step.totalStops} paradas. ';
        }

        announcement +=
            'Tiempo estimado: ${step.estimatedDuration} minutos. '
            'Te avisaré cuando estés cerca de tu parada.';
        break;

      case 'arrival':
        announcement =
            'Has llegado a tu destino: ${step.stopName ?? ""}. '
            'Navegación completada. ¡Buen viaje!';
        break;

      default:
        announcement = step.instruction;
    }

    TtsService.instance.announceNavigation(announcement, urgent: true);
  }

  /// Inicia seguimiento GPS en tiempo real
  void _startLocationTracking() {
    _positionStream?.cancel();

    _positionStream =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10, // Actualizar cada 10 metros
          ),
        ).listen((Position position) {
          _onLocationUpdate(position);
        });
  }

  /// Maneja actualizaciones de ubicación
  void _onLocationUpdate(Position position) {
    if (_activeNavigation == null || _activeNavigation!.isComplete) return;

    // Guardar última posición
    _lastPosition = position;

    // Notificar cambio de geometría (para actualizar el mapa en tiempo real)
    if (onGeometryUpdated != null) {
      onGeometryUpdated!();
    }

    // Filtrar posiciones con baja precisión GPS
    if (position.accuracy > GPS_ACCURACY_THRESHOLD) {
      print(
        '⚠️ GPS con baja precisión: ${position.accuracy.toStringAsFixed(1)}m - Ignorando',
      );
      return;
    }

    // Agregar al histórico de posiciones
    _positionHistory.add(position);
    if (_positionHistory.length > MAX_POSITION_HISTORY) {
      _positionHistory.removeAt(0);
    }

    // Usar posición promediada para mayor estabilidad
    final smoothedPosition = _getSmoothPosition();

    final currentStep = _activeNavigation!.currentStep;
    if (currentStep == null) return;

    final userLocation = LatLng(
      smoothedPosition.latitude,
      smoothedPosition.longitude,
    );

    // Verificar si llegó a la ubicación del paso actual
    if (currentStep.location != null) {
      double distanceToTarget;

      // Si el paso tiene distancia real calculada por OSRM, usarla
      // Para pasos de caminata, OSRM da la distancia real por calles
      if (currentStep.type == 'walk' &&
          currentStep.realDistanceMeters != null) {
        // Para pasos walk con OSRM: calcular distancia restante basada en geometría de ruta
        final geometry = _activeNavigation!.getCurrentStepGeometry(
          userLocation,
        );
        if (geometry.isNotEmpty) {
          // Sumar distancia punto a punto en la geometría restante
          distanceToTarget = 0;
          for (int i = 0; i < geometry.length - 1; i++) {
            distanceToTarget += _distance.as(
              LengthUnit.Meter,
              geometry[i],
              geometry[i + 1],
            );
          }
          print(
            '🗺️ Distancia real restante (OSRM): ${distanceToTarget.toStringAsFixed(1)}m',
          );
        } else {
          // Fallback: línea recta
          distanceToTarget = _distance.as(
            LengthUnit.Meter,
            userLocation,
            currentStep.location!,
          );
          print(
            '⚠️ Usando distancia línea recta (sin geometría): ${distanceToTarget.toStringAsFixed(1)}m',
          );
        }
      } else {
        // Para otros tipos de paso o sin OSRM: línea recta
        distanceToTarget = _distance.as(
          LengthUnit.Meter,
          userLocation,
          currentStep.location!,
        );
        print(
          '📍 Distancia línea recta: ${distanceToTarget.toStringAsFixed(1)}m',
        );
      }

      print(
        '📍 Distancia al objetivo: ${distanceToTarget.toStringAsFixed(1)}m (GPS: ${position.accuracy.toStringAsFixed(1)}m)',
      );

      // Alerta de proximidad (solo si no se ha anunciado antes)
      if (distanceToTarget <= PROXIMITY_ALERT_METERS &&
          distanceToTarget > ARRIVAL_THRESHOLD_METERS) {
        _announceProximity(currentStep);
      }

      // Llegada al objetivo (ajustar threshold según precisión GPS, pero con límite máximo)
      final adjustedThreshold = math.min(
        ARRIVAL_THRESHOLD_METERS + (position.accuracy * 0.3),
        MAX_ARRIVAL_THRESHOLD,
      );

      print(
        '🎯 Umbral ajustado: ${adjustedThreshold.toStringAsFixed(1)}m (GPS accuracy: ${position.accuracy.toStringAsFixed(1)}m)',
      );

      if (distanceToTarget <= adjustedThreshold) {
        _handleStepArrival(currentStep);
      }
    }

    // Si está esperando un bus, detectar buses cercanos
    if (currentStep.type == 'wait_bus') {
      _detectNearbyBuses(currentStep, userLocation);
    }
  }

  /// Obtiene una posición suavizada usando el promedio de las últimas posiciones
  Position _getSmoothPosition() {
    if (_positionHistory.isEmpty) {
      return _positionHistory.last;
    }

    double sumLat = 0;
    double sumLon = 0;
    int count = _positionHistory.length;

    for (var pos in _positionHistory) {
      sumLat += pos.latitude;
      sumLon += pos.longitude;
    }

    return Position(
      latitude: sumLat / count,
      longitude: sumLon / count,
      timestamp: _positionHistory.last.timestamp,
      accuracy: _positionHistory.last.accuracy,
      altitude: _positionHistory.last.altitude,
      heading: _positionHistory.last.heading,
      speed: _positionHistory.last.speed,
      speedAccuracy: _positionHistory.last.speedAccuracy,
      altitudeAccuracy: _positionHistory.last.altitudeAccuracy,
      headingAccuracy: _positionHistory.last.headingAccuracy,
    );
  }

  /// Anuncia proximidad al objetivo
  void _announceProximity(NavigationStep step) {
    // Evitar anuncios duplicados para el mismo paso
    if (_lastProximityAnnouncedStepIndex ==
        _activeNavigation?.currentStepIndex) {
      return;
    }

    String message = '';

    switch (step.type) {
      case 'walk':
        message = 'Te estás acercando al paradero ${step.stopName}';
        break;
      case 'wait_bus':
        message = 'Has llegado al paradero. Espera el bus ${step.busRoute}';
        break;
      case 'ride_bus':
        message = 'Próxima parada: ${step.stopName}';
        break;
      case 'arrival':
        message = 'Estás cerca de tu destino';
        break;
    }

    if (message.isNotEmpty) {
      TtsService.instance.speak(message);
      _lastProximityAnnouncedStepIndex = _activeNavigation?.currentStepIndex;
    }
  }

  /// Maneja llegada a un paso
  void _handleStepArrival(NavigationStep step) {
    print('✅ Llegada al paso: ${step.type}');

    // Evitar anuncios duplicados para el mismo paso
    if (_lastArrivalAnnouncedStepIndex == _activeNavigation?.currentStepIndex) {
      return;
    }

    String announcement = '';

    switch (step.type) {
      case 'walk':
        announcement = 'Has llegado al paradero ${step.stopName}. ';
        if (step.busOptions != null && step.busOptions!.isNotEmpty) {
          announcement += 'Buses disponibles: ${step.busOptions!.join(", ")}';
        }
        onArrivalAtStop?.call(step.stopId ?? '');
        break;

      case 'wait_bus':
        announcement =
            'Estás en el paradero correcto. Espera el bus Red ${step.busRoute}';
        break;

      case 'ride_bus':
        announcement = 'Bájate aquí. Has llegado a ${step.stopName}';
        break;

      case 'arrival':
        announcement = '¡Felicitaciones! Has llegado a tu destino';
        onDestinationReached?.call();
        stopNavigation();
        break;
    }

    // Marcar que se anunció este paso
    _lastArrivalAnnouncedStepIndex = _activeNavigation?.currentStepIndex;

    // Avanzar al siguiente paso
    _activeNavigation!.advanceToNextStep();
    onStepChanged?.call(_activeNavigation!.currentStep ?? step);

    // Combinar anuncio actual con el siguiente paso
    String fullAnnouncement = announcement;

    if (!_activeNavigation!.isComplete && fullAnnouncement.isNotEmpty) {
      final nextStep = _activeNavigation!.currentStep!;
      fullAnnouncement += ' Ahora, ${nextStep.instruction}';
    }

    if (fullAnnouncement.isNotEmpty) {
      TtsService.instance.speak(fullAnnouncement);
    }
  }

  /// Detecta buses cercanos (simulado - en producción usar GPS del bus)
  void _detectNearbyBuses(NavigationStep step, LatLng userLocation) {
    // En producción, esto consultaría la API de tiempo real de buses
    // Por ahora, simulamos la detección

    // Este método se llamaría cuando se detecte que un bus está llegando
    // usando datos de GPS de los buses o información de la API de Transantiago
  }

  /// Detiene la navegación activa
  void stopNavigation() {
    _positionStream?.cancel();
    _activeNavigation = null;
    print('🛑 Navegación detenida');
  }

  /// Obtiene el paso actual
  NavigationStep? get currentStep => _activeNavigation?.currentStep;

  /// Verifica si hay navegación activa
  bool get hasActiveNavigation => _activeNavigation != null;

  /// Obtiene la navegación activa
  ActiveNavigation? get activeNavigation => _activeNavigation;

  /// Obtiene la última posición GPS conocida
  Position? get lastPosition => _lastPosition;

  // Geometría del paso actual usando la última posición GPS
  List<LatLng> get currentStepGeometry {
    if (_activeNavigation == null || _lastPosition == null) {
      print('🗺️ [GEOMETRY] activeNavigation o lastPosition es null');
      return [];
    }

    final currentPos = LatLng(
      _lastPosition!.latitude,
      _lastPosition!.longitude,
    );

    final geometry = _activeNavigation!.getCurrentStepGeometry(currentPos);
    print(
      '🗺️ [GEOMETRY] Retornando geometría del paso ${_activeNavigation!.currentStepIndex}: ${geometry.length} puntos',
    );

    return geometry;
  }

  /// Repite la instrucción actual
  void repeatCurrentInstruction() {
    final step = _activeNavigation?.currentStep;
    if (step != null) {
      TtsService.instance.speak(step.instruction);
    }
  }

  /// Cancela la navegación
  void cancelNavigation() {
    stopNavigation();
    TtsService.instance.speak('Navegación cancelada');
  }

  /// Obtiene ruta peatonal detallada desde OSRM
  Future<Map<String, dynamic>?> _getOSRMWalkingRoute(
    LatLng from,
    LatLng to,
  ) async {
    try {
      // Usar servidor OSRM público o local
      final url = Uri.parse(
        'https://router.project-osrm.org/route/v1/foot/${from.longitude},${from.latitude};${to.longitude},${to.latitude}?steps=true&overview=full&geometries=geojson',
      );

      final response = await http.get(url).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final routes = data['routes'] as List<dynamic>?;

        if (routes != null && routes.isNotEmpty) {
          final route = routes[0] as Map<String, dynamic>;
          final legs = route['legs'] as List<dynamic>?;

          if (legs != null && legs.isNotEmpty) {
            final leg = legs[0] as Map<String, dynamic>;
            final steps = leg['steps'] as List<dynamic>?;

            if (steps != null) {
              // Convertir pasos de OSRM a formato simple
              final simpleSteps = <Map<String, dynamic>>[];

              for (var step in steps) {
                final maneuver = step['maneuver'] as Map<String, dynamic>?;
                final type = maneuver?['type'] as String?;
                final modifier = maneuver?['modifier'] as String?;
                final distance = step['distance'] as num?;
                final duration = step['duration'] as num?;
                final name = step['name'] as String?;

                // Generar instrucción legible
                String instruction = _formatOSRMInstruction(
                  type,
                  modifier,
                  name,
                  distance,
                );

                simpleSteps.add({
                  'instruction': instruction,
                  'distance': distance,
                  'duration': duration,
                });
              }

              return {'steps': simpleSteps};
            }
          }
        }
      }

      print('⚠️ OSRM no retornó ruta válida');
      return null;
    } catch (e) {
      print('❌ Error obteniendo ruta OSRM: $e');
      return null;
    }
  }

  /// Formatea instrucción de OSRM a texto legible en español
  String _formatOSRMInstruction(
    String? type,
    String? modifier,
    String? street,
    num? distance,
  ) {
    String instruction = '';

    // Interpretar tipo de maniobra
    switch (type) {
      case 'turn':
        if (modifier == 'left')
          instruction = 'Gira a la izquierda';
        else if (modifier == 'right')
          instruction = 'Gira a la derecha';
        else if (modifier == 'slight left')
          instruction = 'Gira ligeramente a la izquierda';
        else if (modifier == 'slight right')
          instruction = 'Gira ligeramente a la derecha';
        else if (modifier == 'sharp left')
          instruction = 'Gira bruscamente a la izquierda';
        else if (modifier == 'sharp right')
          instruction = 'Gira bruscamente a la derecha';
        else
          instruction = 'Gira';
        break;
      case 'new name':
      case 'continue':
        instruction = 'Continúa';
        break;
      case 'depart':
        instruction = 'Sal';
        break;
      case 'arrive':
        instruction = 'Has llegado';
        break;
      case 'roundabout':
        instruction = 'Toma la rotonda';
        break;
      default:
        instruction = 'Continúa recto';
    }

    // Agregar nombre de calle si existe
    if (street != null && street.isNotEmpty && street != 'unknown') {
      instruction += ' por $street';
    }

    // Agregar distancia
    if (distance != null && distance > 0) {
      if (distance < 100) {
        instruction += ' durante ${distance.round()} metros';
      } else {
        instruction += ' durante ${(distance / 100).round() * 100} metros';
      }
    }

    return instruction;
  }

  /// Avanza al siguiente paso de navegación
  void advanceToNextStep() {
    if (_activeNavigation == null) {
      print('⚠️ No hay navegación activa');
      return;
    }

    final currentIndex = _activeNavigation!.currentStepIndex;
    if (currentIndex + 1 >= _activeNavigation!.steps.length) {
      print('⚠️ Ya estás en el último paso de navegación');
      return;
    }

    _activeNavigation!.currentStepIndex++;
    final newStep = _activeNavigation!.currentStep;

    print(
      '📍 [STEP] Avanzando paso: $currentIndex → ${_activeNavigation!.currentStepIndex}',
    );
    print('📍 [STEP] Nuevo paso: ${newStep?.type} - ${newStep?.instruction}');

    // Notificar cambio de paso
    if (newStep != null && onStepChanged != null) {
      onStepChanged!(newStep);
    }
  }

  /// TEST: Simula una posición GPS para testing
  /// Útil para probar la navegación sin caminar físicamente
  void simulatePosition(Position position) {
    print(
      '🧪 [TEST] Inyectando posición simulada: ${position.latitude}, ${position.longitude}',
    );
    _onLocationUpdate(position);
  }
}
