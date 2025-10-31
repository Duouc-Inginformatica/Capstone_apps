import 'package:latlong2/latlong.dart';
import 'backend/dio_api_client.dart';
import 'debug_logger.dart';

/// ============================================================================
/// ROUTING SERVICE - Integración con GraphHopper Local
/// ============================================================================
/// Servicio para calcular rutas usando el backend GraphHopper local
/// Conecta con el backend Go que expone GraphHopper en localhost:8080
///
/// Endpoints disponibles:
/// - GET  /api/route/walking       - Ruta peatonal completa
/// - GET  /api/route/driving       - Ruta vehicular
/// - GET  /api/geometry/walking    - Solo geometría peatonal
/// - POST /api/route/transit       - Ruta con transporte público

class RoutingService {
  static RoutingService? _instance;

  RoutingService._();

  static RoutingService get instance {
    _instance ??= RoutingService._();
    return _instance!;
  }

  /// ============================================================================
  /// CALCULAR RUTA PEATONAL
  /// ============================================================================
  /// Usa GraphHopper local a través del backend Go
  /// Perfil: foot (velocidad ~4.25 km/h para accesibilidad)
  Future<RouteResponse> getWalkingRoute({
    required LatLng origin,
    required LatLng destination,
  }) async {
    try {
      DebugLogger.info(
        '🚶 Calculando ruta peatonal: ${origin.latitude},${origin.longitude} → ${destination.latitude},${destination.longitude}',
        context: 'RoutingService',
      );

      final response = await DioApiClient.get(
        '/route/walking',
        queryParameters: {
          'origin_lat': origin.latitude,
          'origin_lon': origin.longitude,
          'dest_lat': destination.latitude,
          'dest_lon': destination.longitude,
        },
      );

      if (response.statusCode != 200) {
        throw Exception('Error del servidor: ${response.statusCode}');
      }

      final data = response.data;

      // Validar respuesta
      if (data == null || data['route'] == null) {
        throw Exception('Respuesta inválida del servidor');
      }

      DebugLogger.success(
        '✅ Ruta calculada: ${(data['route']['distance'] / 1000).toStringAsFixed(2)} km, ${_formatDuration(data['route']['time'])}',
        context: 'RoutingService',
      );

      return RouteResponse.fromJson(data);
    } catch (e, stackTrace) {
      DebugLogger.error(
        'Error calculando ruta peatonal',
        context: 'RoutingService',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// ============================================================================
  /// CALCULAR RUTA VEHICULAR
  /// ============================================================================
  Future<RouteResponse> getDrivingRoute({
    required LatLng origin,
    required LatLng destination,
  }) async {
    try {
      DebugLogger.info(
        '🚗 Calculando ruta vehicular: ${origin.latitude},${origin.longitude} → ${destination.latitude},${destination.longitude}',
        context: 'RoutingService',
      );

      final response = await DioApiClient.get(
        '/route/driving',
        queryParameters: {
          'origin_lat': origin.latitude,
          'origin_lon': origin.longitude,
          'dest_lat': destination.latitude,
          'dest_lon': destination.longitude,
        },
      );

      if (response.statusCode != 200) {
        throw Exception('Error del servidor: ${response.statusCode}');
      }

      final data = response.data;

      if (data == null || data['route'] == null) {
        throw Exception('Respuesta inválida del servidor');
      }

      DebugLogger.success(
        '✅ Ruta vehicular calculada: ${(data['route']['distance'] / 1000).toStringAsFixed(2)} km',
        context: 'RoutingService',
      );

      return RouteResponse.fromJson(data);
    } catch (e, stackTrace) {
      DebugLogger.error(
        'Error calculando ruta vehicular',
        context: 'RoutingService',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// ============================================================================
  /// CALCULAR SOLO DISTANCIA Y TIEMPO (SIN GEOMETRÍA)
  /// ============================================================================
  /// Endpoint ultra-rápido para obtener solo distancia/tiempo
  /// Útil cuando no necesitas el polyline completo
  Future<RouteQuickInfo> getWalkingDistance({
    required LatLng origin,
    required LatLng destination,
  }) async {
    try {
      final response = await DioApiClient.get(
        '/route/walking/distance',
        queryParameters: {
          'origin_lat': origin.latitude,
          'origin_lon': origin.longitude,
          'dest_lat': destination.latitude,
          'dest_lon': destination.longitude,
        },
      );

      if (response.statusCode != 200) {
        throw Exception('Error del servidor: ${response.statusCode}');
      }

      final data = response.data;

      return RouteQuickInfo(
        distance: (data['distance'] as num).toDouble(),
        duration: Duration(milliseconds: (data['time'] as num).toInt()),
      );
    } catch (e, stackTrace) {
      DebugLogger.error(
        'Error obteniendo distancia',
        context: 'RoutingService',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Formatear duración a texto legible
  String _formatDuration(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);

    if (hours > 0) {
      return '${hours}h ${minutes}min';
    }
    return '${minutes}min';
  }
}

/// ============================================================================
/// MODELOS DE RESPUESTA
/// ============================================================================

/// Respuesta completa de ruta con geometría e instrucciones
class RouteResponse {
  final RouteData route;

  const RouteResponse({required this.route});

  factory RouteResponse.fromJson(Map<String, dynamic> json) {
    return RouteResponse(
      route: RouteData.fromJson(json['route'] as Map<String, dynamic>),
    );
  }
}

/// Datos de la ruta
class RouteData {
  final double distance; // metros
  final int time; // milisegundos
  final List<LatLng> geometry; // Polyline como lista de puntos
  final List<RouteInstruction> instructions; // Instrucciones paso a paso

  const RouteData({
    required this.distance,
    required this.time,
    required this.geometry,
    required this.instructions,
  });

  factory RouteData.fromJson(Map<String, dynamic> json) {
    // Parsear geometría
    final geometryData = json['geometry'] as List<dynamic>;
    final geometry = geometryData.map((point) {
      final coords = point as List<dynamic>;
      return LatLng(
        (coords[1] as num).toDouble(), // lat
        (coords[0] as num).toDouble(), // lon
      );
    }).toList();

    // Parsear instrucciones
    final instructionsData = json['instructions'] as List<dynamic>? ?? [];
    final instructions = instructionsData.map((inst) {
      return RouteInstruction.fromJson(inst as Map<String, dynamic>);
    }).toList();

    return RouteData(
      distance: (json['distance'] as num).toDouble(),
      time: (json['time'] as num).toInt(),
      geometry: geometry,
      instructions: instructions,
    );
  }

  Duration get duration => Duration(milliseconds: time);
}

/// Instrucción de navegación
class RouteInstruction {
  final int sign; // Tipo de maniobra (GraphHopper sign codes)
  final String text; // Texto de la instrucción
  final double distance; // Distancia hasta siguiente instrucción (metros)
  final int time; // Tiempo hasta siguiente instrucción (ms)
  final int interval; // Índice en el array de geometry
  final String? streetName; // Nombre de la calle (opcional)

  const RouteInstruction({
    required this.sign,
    required this.text,
    required this.distance,
    required this.time,
    required this.interval,
    this.streetName,
  });

  factory RouteInstruction.fromJson(Map<String, dynamic> json) {
    return RouteInstruction(
      sign: (json['sign'] as num).toInt(),
      text: json['text'] as String,
      distance: (json['distance'] as num).toDouble(),
      time: (json['time'] as num).toInt(),
      interval: (json['interval'] as num?)?.toInt() ?? 0,
      streetName: json['street_name'] as String?,
    );
  }

  /// Convertir sign de GraphHopper a tipo de maniobra
  /// Códigos GraphHopper:
  /// 0 = Continue
  /// -2 = Turn left
  /// 2 = Turn right
  /// -3 = Sharp left
  /// 3 = Sharp right
  /// -1 = Slight left
  /// 1 = Slight right
  /// 4 = Finish/Destination
  /// 5 = Via reached
  /// 6 = Roundabout
  String get maneuverType {
    switch (sign) {
      case -3:
        return 'sharp_left';
      case -2:
        return 'turn_left';
      case -1:
        return 'slight_left';
      case 0:
        return 'continue';
      case 1:
        return 'slight_right';
      case 2:
        return 'turn_right';
      case 3:
        return 'sharp_right';
      case 4:
        return 'arrive';
      case 5:
        return 'waypoint';
      case 6:
        return 'roundabout';
      default:
        return 'continue';
    }
  }

  Duration get duration => Duration(milliseconds: time);
}

/// Info rápida de ruta (sin geometría)
class RouteQuickInfo {
  final double distance;
  final Duration duration;

  const RouteQuickInfo({required this.distance, required this.duration});
}
