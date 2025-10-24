import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show SocketException;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../device/auth_storage.dart';
import 'server_config.dart';

// ============================================================================
// ROUTE CACHE SYSTEM - Sprint 3 CAP-18
// ============================================================================
class CachedRoute {
  CachedRoute({
    required this.routeData,
    required this.timestamp,
    required this.originLat,
    required this.originLon,
    required this.destLat,
    required this.destLon,
  });

  final Map<String, dynamic> routeData;
  final DateTime timestamp;
  final double originLat;
  final double originLon;
  final double destLat;
  final double destLon;

  bool isExpired({Duration ttl = const Duration(minutes: 30)}) {
    return DateTime.now().difference(timestamp) > ttl;
  }

  bool matchesRequest({
    required double originLat,
    required double originLon,
    required double destLat,
    required double destLon,
    double tolerance = 0.001, // ~100 metros
  }) {
    return (this.originLat - originLat).abs() < tolerance &&
        (this.originLon - originLon).abs() < tolerance &&
        (this.destLat - destLat).abs() < tolerance &&
        (this.destLon - destLon).abs() < tolerance;
  }

  Map<String, dynamic> toJson() {
    return {
      'routeData': routeData,
      'timestamp': timestamp.toIso8601String(),
      'originLat': originLat,
      'originLon': originLon,
      'destLat': destLat,
      'destLon': destLon,
    };
  }

  factory CachedRoute.fromJson(Map<String, dynamic> json) {
    return CachedRoute(
      routeData: json['routeData'] as Map<String, dynamic>,
      timestamp: DateTime.parse(json['timestamp'] as String),
      originLat: (json['originLat'] as num).toDouble(),
      originLon: (json['originLon'] as num).toDouble(),
      destLat: (json['destLat'] as num).toDouble(),
      destLon: (json['destLon'] as num).toDouble(),
    );
  }
}

class RouteCache {
  static final RouteCache instance = RouteCache._();
  RouteCache._();

  static const int maxCacheSize = 10;
  static const String cacheKey = 'route_cache';
  final List<CachedRoute> _cache = [];

  Future<void> loadCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheJson = prefs.getString(cacheKey);
      if (cacheJson != null) {
        final List<dynamic> cacheList = jsonDecode(cacheJson) as List;
        _cache.clear();
        for (var item in cacheList) {
          _cache.add(CachedRoute.fromJson(item as Map<String, dynamic>));
        }
        // Limpiar rutas expiradas
        _cache.removeWhere((route) => route.isExpired());
      }
    } catch (e) {
      developer.log('Error loading route cache: $e');
    }
  }

  Future<void> saveCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheJson = jsonEncode(_cache.map((r) => r.toJson()).toList());
      await prefs.setString(cacheKey, cacheJson);
    } catch (e) {
      developer.log('Error saving route cache: $e');
    }
  }

  Future<void> addRoute({
    required Map<String, dynamic> routeData,
    required double originLat,
    required double originLon,
    required double destLat,
    required double destLon,
  }) async {
    final cached = CachedRoute(
      routeData: routeData,
      timestamp: DateTime.now(),
      originLat: originLat,
      originLon: originLon,
      destLat: destLat,
      destLon: destLon,
    );

    _cache.insert(0, cached);

    // Mantener máximo 10 rutas
    if (_cache.length > maxCacheSize) {
      _cache.removeRange(maxCacheSize, _cache.length);
    }

    await saveCache();
  }

  Map<String, dynamic>? getCachedRoute({
    required double originLat,
    required double originLon,
    required double destLat,
    required double destLon,
  }) {
    for (var cached in _cache) {
      if (!cached.isExpired() &&
          cached.matchesRequest(
            originLat: originLat,
            originLon: originLon,
            destLat: destLat,
            destLon: destLon,
          )) {
        return cached.routeData;
      }
    }
    return null;
  }

  List<Map<String, dynamic>> getAlternativeRoutes({
    required double destLat,
    required double destLon,
    int limit = 3,
  }) {
    final alternatives = <Map<String, dynamic>>[];

    for (var cached in _cache) {
      if (!cached.isExpired() &&
          (cached.destLat - destLat).abs() < 0.005 && // ~500m del destino
          (cached.destLon - destLon).abs() < 0.005) {
        alternatives.add(cached.routeData);
        if (alternatives.length >= limit) break;
      }
    }

    return alternatives;
  }

  Future<void> clearCache() async {
    _cache.clear();
    await saveCache();
  }
}

class ApiClient {
  // Singleton instance
  static final ApiClient instance = ApiClient._internal();

  ApiClient._internal() : _overrideBaseUrl = null;

  ApiClient({String? baseUrl})
    : _overrideBaseUrl = baseUrl != null && baseUrl.trim().isNotEmpty
          ? ServerConfig.instance.normalizeOrFallback(baseUrl)
          : null;

  ApiClient.override(String baseUrl)
    : _overrideBaseUrl = ServerConfig.instance.normalizeOrFallback(baseUrl);

  final String? _overrideBaseUrl;

  String get baseUrl {
    const envBase = String.fromEnvironment('API_BASE_URL');
    if (envBase.isNotEmpty) {
      return ServerConfig.instance.normalizeOrFallback(envBase);
    }
    return _overrideBaseUrl ?? ServerConfig.instance.baseUrl;
  }

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Uri _uriWithQuery(String path, Map<String, String> query) {
    return _uri(path).replace(queryParameters: query);
  }

  // Método para configurar URL personalizada para dispositivos físicos
  static String getPhysicalDeviceUrl(String hostIP, {int port = 8080}) {
    final uri = Uri(scheme: 'http', host: hostIP, port: port);
    return uri.toString();
  }

  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
  }) async {
    final uri = _uri('/api/login');
    final res = await _safeRequest(
      () => http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}),
      ),
    );
    final data =
        jsonDecode(res.body.isEmpty ? '{}' : res.body) as Map<String, dynamic>;
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final token = data['token']?.toString();
      if (token != null) {
        await AuthStorage.saveToken(token);
      }
      return data;
    }
    throw ApiException(
      message: data['error']?.toString() ?? 'login failed',
      statusCode: res.statusCode,
    );
  }

  Future<Map<String, dynamic>> register({
    required String username,
    required String email,
    required String password,
    required String name,
    String? biometricToken,
  }) async {
    final uri = _uri('/api/register');
    final body = {
      'username': username,
      'email': email,
      'password': password,
      'name': name,
    };

    if (biometricToken != null) {
      body['biometric_token'] = biometricToken;
    }

    final res = await _safeRequest(
      () => http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ),
    );
    final data =
        jsonDecode(res.body.isEmpty ? '{}' : res.body) as Map<String, dynamic>;
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final token = data['token']?.toString();
      if (token != null) {
        await AuthStorage.saveToken(token);
      }
      return data;
    }
    throw ApiException(
      message: data['error']?.toString() ?? 'register failed',
      statusCode: res.statusCode,
    );
  }

  /// Registra al usuario utilizando el flujo biométrico dedicado del backend
  Future<Map<String, dynamic>> biometricRegister({
    required String username,
    required String biometricToken,
    String? email,
    String? deviceInfo,
  }) async {
    final uri = _uri('/api/auth/biometric/register');
    final body = <String, dynamic>{
      'biometric_id': biometricToken,
      'username': username,
    };

    if (email != null && email.trim().isNotEmpty) {
      body['email'] = email.trim();
    }

    if (deviceInfo != null && deviceInfo.trim().isNotEmpty) {
      body['device_info'] = deviceInfo.trim();
    }

    final res = await _safeRequest(
      () => http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ),
    );

    final data =
        jsonDecode(res.body.isEmpty ? '{}' : res.body) as Map<String, dynamic>;

    if (res.statusCode >= 200 && res.statusCode < 300) {
      final token = data['token']?.toString();
      if (token != null) {
        await AuthStorage.saveToken(token);
      }
      return data;
    }

    throw ApiException(
      message: data['error']?.toString() ?? 'biometric register failed',
      statusCode: res.statusCode,
    );
  }

  /// Obtiene un token de sesión desde el backend usando solo biometría
  Future<Map<String, dynamic>> biometricLogin({
    required String biometricToken,
  }) async {
    final uri = _uri('/api/auth/biometric/login');
    final body = {
      'biometric_id': biometricToken,
    };

    final res = await _safeRequest(
      () => http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ),
    );

    final data =
        jsonDecode(res.body.isEmpty ? '{}' : res.body) as Map<String, dynamic>;

    if (res.statusCode >= 200 && res.statusCode < 300) {
      final token = data['token']?.toString();
      if (token != null) {
        await AuthStorage.saveToken(token);
      }
      return data;
    }

    throw ApiException(
      message: data['error']?.toString() ?? 'biometric login failed',
      statusCode: res.statusCode,
    );
  }

  /// Verifica si un token biométrico ya está registrado en el backend
  Future<bool> checkBiometricExists(String biometricToken) async {
    try {
      final uri = _uri('/api/biometric/check');
      final res = await _safeRequest(
        () => http.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'biometric_token': biometricToken}),
        ),
      );

      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data =
            jsonDecode(res.body.isEmpty ? '{}' : res.body)
                as Map<String, dynamic>;
        return data['exists'] == true;
      }

      return false;
    } catch (e) {
      developer.log('⚠️ [API] Error verificando huella biométrica: $e');
      // En caso de error, permitir continuar (modo offline)
      return false;
    }
  }

  Future<http.Response> getAuthorized(Uri uri) async {
    final token = await AuthStorage.readToken();
    final headers = <String, String>{'Accept': 'application/json'};
    if (token != null) headers['Authorization'] = 'Bearer $token';
    return http.get(uri, headers: headers);
  }

  Future<http.Response> postAuthorized(
    Uri uri,
    Map<String, dynamic> body,
  ) async {
    final token = await AuthStorage.readToken();
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (token != null) headers['Authorization'] = 'Bearer $token';
    return http.post(uri, headers: headers, body: jsonEncode(body));
  }

  // GTFS Services
  Future<List<dynamic>> getNearbyStops({
    required double lat,
    required double lon,
    double radius = 400,
    int limit = 20,
  }) async {
    final uri = _uriWithQuery('/api/stops', {
      'lat': lat.toString(),
      'lon': lon.toString(),
      'radius': radius.toString(),
      'limit': limit.toString(),
    });

    final res = await _safeRequest(() => getAuthorized(uri));
    final data =
        jsonDecode(res.body.isEmpty ? '{}' : res.body) as Map<String, dynamic>;

    if (res.statusCode >= 200 && res.statusCode < 300) {
      return data['stops'] as List<dynamic>? ?? [];
    }

    throw ApiException(
      message: data['error']?.toString() ?? 'Failed to fetch nearby stops',
      statusCode: res.statusCode,
    );
  }

  Future<Map<String, dynamic>> syncGTFS() async {
    final uri = _uri('/api/gtfs/sync');
    final res = await _safeRequest(() => postAuthorized(uri, {}));
    final data =
        jsonDecode(res.body.isEmpty ? '{}' : res.body) as Map<String, dynamic>;

    if (res.statusCode >= 200 && res.statusCode < 300) {
      return data;
    }

    throw ApiException(
      message: data['error']?.toString() ?? 'Failed to sync GTFS',
      statusCode: res.statusCode,
    );
  }

  // Public Transit Routing using GTFS data - NUEVO MÉTODO
  Future<Map<String, dynamic>> getPublicTransitRoute({
    required double originLat,
    required double originLon,
    required double destLat,
    required double destLon,
    DateTime? departureTime,
    bool arriveBy = false,
    bool includeGeometry = true,
    bool useCache = true,
  }) async {
    // Validar coordenadas antes de enviar la solicitud
    if (originLat.isNaN || originLon.isNaN || destLat.isNaN || destLon.isNaN) {
      throw ApiException(
        message:
            'Coordenadas inválidas (NaN): origin($originLat, $originLon), dest($destLat, $destLon)',
        statusCode: 400,
      );
    }

    if (originLat < -90 || originLat > 90 || destLat < -90 || destLat > 90) {
      throw ApiException(
        message:
            'Latitud fuera de rango: origin=$originLat, dest=$destLat (debe estar entre -90 y 90)',
        statusCode: 400,
      );
    }

    if (originLon < -180 ||
        originLon > 180 ||
        destLon < -180 ||
        destLon > 180) {
      throw ApiException(
        message:
            'Longitud fuera de rango: origin=$originLon, dest=$destLon (debe estar entre -180 y 180)',
        statusCode: 400,
      );
    }

    // Intentar obtener de caché primero
    if (useCache) {
      final cached = RouteCache.instance.getCachedRoute(
        originLat: originLat,
        originLon: originLon,
        destLat: destLat,
        destLon: destLon,
      );

      if (cached != null) {
        developer.log('✅ Ruta de transporte público encontrada en caché');
        cached['fromCache'] = true;
        return cached;
      }
    }

    final uri = _uri('/api/route/public-transit');
    final body = {
      'origin': {'lat': originLat, 'lon': originLon},
      'destination': {'lat': destLat, 'lon': destLon},
      'arrive_by': arriveBy,
      'include_geometry': includeGeometry,
    };

    if (departureTime != null) {
      body['departure_time'] = departureTime.toUtc().toIso8601String();
    }

    developer.log('🚌 Enviando solicitud de transporte público a: $uri');
    developer.log('📝 Body: $body');
    developer.log('📍 Origin: lat=$originLat, lon=$originLon');
    developer.log('📍 Destination: lat=$destLat, lon=$destLon');

    try {
      final headers = <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };

      final token = await AuthStorage.readToken();
      if (token != null) headers['Authorization'] = 'Bearer $token';

      final response = await http.post(
        uri,
        headers: headers,
        body: jsonEncode(body),
      );

      developer.log('📡 Status Code: ${response.statusCode}');
      developer.log('📄 Response: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;

        // Verificar si es un fallback a Moovit
        if (data['fallback'] == 'moovit') {
          developer.log(
            '🔄 Backend sugiere usar Moovit, consultando endpoint de Red...',
          );

          // Llamar al endpoint de Moovit/Red directamente
          final redUri = _uri('/api/red/itinerary');
          final redBody = {
            'origin_lat': originLat,
            'origin_lon': originLon,
            'dest_lat': destLat,
            'dest_lon': destLon,
          };

          final redResponse = await http.post(
            redUri,
            headers: headers,
            body: jsonEncode(redBody),
          );

          if (redResponse.statusCode == 200) {
            final redData =
                jsonDecode(redResponse.body) as Map<String, dynamic>;
            developer.log('✅ Ruta obtenida desde Moovit/Red');

            // Convertir formato de Moovit a formato GTFS para compatibilidad
            return _convertMoovitToGTFSFormat(redData);
          } else {
            developer.log(
              '⚠️ Error obteniendo ruta de Moovit: ${redResponse.statusCode}',
            );
            throw ApiException(
              statusCode: redResponse.statusCode,
              message: 'No se pudo obtener ruta de Moovit',
            );
          }
        }

        // Guardar en caché si la respuesta es válida
        if (useCache && data['paths'] != null) {
          await RouteCache.instance.addRoute(
            routeData: data,
            originLat: originLat,
            originLon: originLon,
            destLat: destLat,
            destLon: destLon,
          );
        }

        return data;
      } else {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        throw ApiException(
          statusCode: response.statusCode,
          message:
              data['error']?.toString() ?? 'Failed to get public transit route',
        );
      }
    } catch (e) {
      developer.log('❌ Error en solicitud de transporte público: $e');
      rethrow;
    }
  }

  /// Convierte el formato de Moovit al formato GTFS para compatibilidad
  Map<String, dynamic> _convertMoovitToGTFSFormat(
    Map<String, dynamic> moovitData,
  ) {
    return {
      'paths': [
        {
          'time': moovitData['total_duration'] ?? 0,
          'distance': moovitData['total_distance'] ?? 0,
          'legs': moovitData['legs'] ?? [],
          'source': 'moovit',
        },
      ],
    };
  }

  // Obtener múltiples rutas alternativas
  Future<List<Map<String, dynamic>>> getAlternativeRoutes({
    required double originLat,
    required double originLon,
    required double destLat,
    required double destLon,
  }) async {
    final routes = <Map<String, dynamic>>[];

    try {
      // Intentar obtener ruta principal
      final mainRoute = await getPublicTransitRoute(
        originLat: originLat,
        originLon: originLon,
        destLat: destLat,
        destLon: destLon,
        useCache: false, // Forzar consulta al servidor
      );
      routes.add(mainRoute);
    } catch (e) {
      developer.log('No se pudo obtener ruta principal: $e');
    }

    // Agregar rutas alternativas de caché
    final cachedAlternatives = RouteCache.instance.getAlternativeRoutes(
      destLat: destLat,
      destLon: destLon,
      limit: 5,
    );

    for (var alt in cachedAlternatives) {
      alt['isAlternative'] = true;
      routes.add(alt);
    }

    return routes;
  }

  Future<http.Response> _safeRequest(
    Future<http.Response> Function() request,
  ) async {
    try {
      return await request().timeout(const Duration(seconds: 15));
    } on SocketException catch (e) {
      // Error de conectividad específico
      String message = 'No se pudo conectar con el servidor.';
      if (e.message.contains('Network is unreachable')) {
        message = 'Sin conexión a internet. Verifica tu conexión.';
      } else if (e.message.contains('Connection refused')) {
        message =
            'Servidor no disponible. Verifica que el backend esté ejecutándose.';
      } else if (e.message.contains('Failed host lookup')) {
        message = 'No se pudo resolver la dirección del servidor.';
      }

      throw ApiException(message: message, statusCode: 0, isNetworkError: true);
    } on TimeoutException {
      throw ApiException(
        message: 'La petición tardó demasiado. Verifica tu conexión.',
        statusCode: 408,
        isNetworkError: true,
      );
    } on http.ClientException catch (e) {
      throw ApiException(
        message: 'Error de cliente HTTP: ${e.message}',
        statusCode: 0,
        isNetworkError: true,
      );
    } catch (e) {
      throw ApiException(
        message: 'Error inesperado: ${e.toString()}',
        statusCode: 0,
        isNetworkError: false,
      );
    }
  }

  // Método para probar conectividad
  Future<bool> testConnection() async {
    try {
      final uri = _uri('/api/health');
      final response = await http.get(uri).timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }
}

class ApiException implements Exception {
  ApiException({
    required this.message,
    required this.statusCode,
    this.isNetworkError = false,
  });

  final String message;
  final int statusCode;
  final bool isNetworkError;

  @override
  String toString() => 'ApiException($statusCode): $message';

  // Helper methods para diferentes tipos de errores
  bool get isConnectivityIssue =>
      isNetworkError && (statusCode == 0 || statusCode == 408);
  bool get isServerError => statusCode >= 500;
  bool get isClientError => statusCode >= 400 && statusCode < 500;
}
