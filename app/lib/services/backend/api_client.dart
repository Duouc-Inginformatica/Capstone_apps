import 'dart:async';
import 'dart:convert';
import '../debug_logger.dart';
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

// ============================================================================
// ENHANCED ROUTE CACHE - MEJORA #2
// ============================================================================
// Caché mejorado con:
// - 50 rutas (vs 10 anterior)
// - Persistencia entre sesiones
// - Métricas de uso (hit rate, rutas frecuentes)
// - Priorización por frecuencia de acceso (LRU + frecuencia)
// ============================================================================

class RouteCache {
  static final RouteCache instance = RouteCache._();
  RouteCache._();

  static const int maxCacheSize = 50; // ✅ Aumentado de 10 a 50
  static const String cacheKey = 'route_cache_v2';
  static const String metricsKey = 'route_cache_metrics';

  final List<CachedRoute> _cache = [];

  // Métricas
  int _hits = 0;
  int _misses = 0;
  final Map<String, int> _routeAccessCount = {}; // Frecuencia de uso por ruta

  Future<void> loadCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Cargar rutas
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

      // Cargar métricas
      final metricsJson = prefs.getString(metricsKey);
      if (metricsJson != null) {
        final metrics = jsonDecode(metricsJson) as Map<String, dynamic>;
        _hits = metrics['hits'] ?? 0;
        _misses = metrics['misses'] ?? 0;
        final accessCount = metrics['access_count'] as Map<String, dynamic>?;
        if (accessCount != null) {
          _routeAccessCount.addAll(
            accessCount.map((k, v) => MapEntry(k, v as int)),
          );
        }
      }

      DebugLogger.network(
        '✅ [CACHE] Cargado: ${_cache.length} rutas, Hit rate: ${hitRate.toStringAsFixed(1)}%',
      );
    } catch (e) {
      DebugLogger.network('❌ Error loading route cache: $e');
    }
  }

  Future<void> saveCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Guardar rutas
      final cacheJson = jsonEncode(_cache.map((r) => r.toJson()).toList());
      await prefs.setString(cacheKey, cacheJson);

      // Guardar métricas
      final metricsJson = jsonEncode({
        'hits': _hits,
        'misses': _misses,
        'access_count': _routeAccessCount,
      });
      await prefs.setString(metricsKey, metricsJson);
    } catch (e) {
      DebugLogger.network('❌ Error saving route cache: $e');
    }
  }

  Future<void> addRoute({
    required Map<String, dynamic> routeData,
    required double originLat,
    required double originLon,
    required double destLat,
    required double destLon,
  }) async {
    final key = _generateKey(originLat, originLon, destLat, destLon);

    // Evitar duplicados - remover si ya existe
    _cache.removeWhere(
      (c) => c.matchesRequest(
        originLat: originLat,
        originLon: originLon,
        destLat: destLat,
        destLon: destLon,
      ),
    );

    final cached = CachedRoute(
      routeData: routeData,
      timestamp: DateTime.now(),
      originLat: originLat,
      originLon: originLon,
      destLat: destLat,
      destLon: destLon,
    );

    _cache.insert(0, cached);
    _routeAccessCount[key] = 1;

    // Mantener máximo 50 rutas (priorizar más frecuentes)
    if (_cache.length > maxCacheSize) {
      _pruneCache();
    }

    await saveCache();
  }

  Map<String, dynamic>? getCachedRoute({
    required double originLat,
    required double originLon,
    required double destLat,
    required double destLon,
  }) {
    final key = _generateKey(originLat, originLon, destLat, destLon);

    for (var cached in _cache) {
      if (!cached.isExpired() &&
          cached.matchesRequest(
            originLat: originLat,
            originLon: originLon,
            destLat: destLat,
            destLon: destLon,
          )) {
        // Métricas
        _hits++;
        _routeAccessCount[key] = (_routeAccessCount[key] ?? 0) + 1;

        DebugLogger.network(
          '✅ [CACHE] HIT: $key (${_routeAccessCount[key]} accesos)',
        );

        // Mover al inicio (LRU)
        _cache.remove(cached);
        _cache.insert(0, cached);

        // Guardar métricas actualizadas (sin await para no bloquear)
        saveCache();

        return cached.routeData;
      }
    }

    _misses++;
    DebugLogger.network(
      '❌ [CACHE] MISS: $key (Total: $_hits hits, $_misses misses)',
    );

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

  /// Elimina rutas menos frecuentes para mantener límite
  void _pruneCache() {
    // Ordenar por frecuencia de acceso (más accesos primero)
    _cache.sort((a, b) {
      final keyA = _generateKey(a.originLat, a.originLon, a.destLat, a.destLon);
      final keyB = _generateKey(b.originLat, b.originLon, b.destLat, b.destLon);
      final countA = _routeAccessCount[keyA] ?? 0;
      final countB = _routeAccessCount[keyB] ?? 0;
      return countB.compareTo(countA); // Descendente
    });

    // Eliminar las últimas (menos frecuentes)
    final removed = _cache.sublist(maxCacheSize);
    _cache.removeRange(maxCacheSize, _cache.length);

    // Limpiar métricas de rutas eliminadas
    for (final route in removed) {
      final key = _generateKey(
        route.originLat,
        route.originLon,
        route.destLat,
        route.destLon,
      );
      _routeAccessCount.remove(key);
    }

    DebugLogger.network(
      '🧹 [CACHE] Limpieza: eliminadas ${removed.length} rutas menos frecuentes',
    );
  }

  String _generateKey(double oLat, double oLon, double dLat, double dLon) {
    // Redondear a 4 decimales (~11m precisión)
    return '${oLat.toStringAsFixed(4)},${oLon.toStringAsFixed(4)}-'
        '${dLat.toStringAsFixed(4)},${dLon.toStringAsFixed(4)}';
  }

  // ============================================================================
  // MÉTRICAS - MEJORA #2
  // ============================================================================

  /// Tasa de aciertos del caché (0-100%)
  double get hitRate {
    final total = _hits + _misses;
    return total > 0 ? (_hits / total) * 100 : 0;
  }

  /// Obtiene métricas completas del caché
  Map<String, dynamic> getMetrics() {
    return {
      'hits': _hits,
      'misses': _misses,
      'hit_rate': hitRate,
      'cached_routes': _cache.length,
      'max_size': maxCacheSize,
      'top_routes': _getTopRoutes(5),
    };
  }

  /// Obtiene las rutas más frecuentemente accedidas
  List<Map<String, dynamic>> _getTopRoutes(int limit) {
    final sorted = _routeAccessCount.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return sorted
        .take(limit)
        .map((e) => {'route': e.key, 'access_count': e.value})
        .toList();
  }

  /// Limpia todo el caché y resetea métricas
  Future<void> clearCache() async {
    _cache.clear();
    _hits = 0;
    _misses = 0;
    _routeAccessCount.clear();
    await saveCache();
    DebugLogger.network('🗑️ [CACHE] Limpiado completamente');
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
    final body = {'biometric_id': biometricToken};

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
  /// Retorna información completa: action (auto_login/register), username, message
  Future<Map<String, dynamic>?> checkBiometricExists(
    String biometricToken,
  ) async {
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
        return data;
      }

      return null;
    } catch (e) {
      DebugLogger.network('⚠️ [API] Error verificando huella biométrica: $e');
      // En caso de error, permitir continuar (modo offline)
      return null;
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

  // ============================================================================
  // MÉTODOS HTTP GENÉRICOS - MEJORA #1
  // ============================================================================
  // Métodos GET y POST genéricos con autorización automática y manejo de errores
  // Desbloquean funcionalidades comentadas en IntegratedNavigationService
  // ============================================================================

  /// GET genérico con autorización automática
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? queryParams,
  }) async {
    final uri = queryParams != null
        ? _uriWithQuery(path, queryParams)
        : _uri(path);

    DebugLogger.network('🌐 [GET] $uri');

    final response = await _safeRequest(() => getAuthorized(uri));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final body = response.body.isEmpty ? '{}' : response.body;
      return jsonDecode(body) as Map<String, dynamic>;
    }

    final errorData =
        jsonDecode(response.body.isEmpty ? '{}' : response.body)
            as Map<String, dynamic>;
    throw ApiException(
      message: errorData['error']?.toString() ?? 'GET request failed',
      statusCode: response.statusCode,
    );
  }

  /// POST genérico con autorización automática
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final uri = _uri(path);

    DebugLogger.network('🌐 [POST] $uri');

    final response = await _safeRequest(() => postAuthorized(uri, body));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final responseBody = response.body.isEmpty ? '{}' : response.body;
      return jsonDecode(responseBody) as Map<String, dynamic>;
    }

    final errorData =
        jsonDecode(response.body.isEmpty ? '{}' : response.body)
            as Map<String, dynamic>;
    throw ApiException(
      message: errorData['error']?.toString() ?? 'POST request failed',
      statusCode: response.statusCode,
    );
  }

  // ============================================================================
  // MÉTODOS ESPECÍFICOS USANDO LOS GENÉRICOS - MEJORA #1
  // ============================================================================

  /// Obtiene llegadas de buses para un paradero específico
  Future<Map<String, dynamic>?> getBusArrivals(String stopCode) async {
    try {
      return await get('/api/arrivals/$stopCode');
    } catch (e) {
      DebugLogger.network('❌ [API] Error obteniendo llegadas: $e');
      return null;
    }
  }

  /// Buscar paraderos por nombre
  Future<List<Map<String, dynamic>>> searchStops(String query) async {
    try {
      final data = await get('/api/stops/search', queryParams: {'name': query});
      return List<Map<String, dynamic>>.from(data['stops'] ?? []);
    } catch (e) {
      DebugLogger.network('❌ [API] Error buscando paraderos: $e');
      return [];
    }
  }

  /// Obtener rutas que pasan por un paradero
  Future<List<String>> getRoutesByStop(String stopCode) async {
    try {
      final data = await get('/api/stops/$stopCode/routes');
      return List<String>.from(data['routes'] ?? []);
    } catch (e) {
      DebugLogger.network('❌ [API] Error obteniendo rutas: $e');
      return [];
    }
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
        DebugLogger.network('✅ Ruta de transporte público encontrada en caché');
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

    DebugLogger.network('🚌 Enviando solicitud de transporte público a: $uri');
    DebugLogger.network('📝 Body: $body');
    DebugLogger.network('📍 Origin: lat=$originLat, lon=$originLon');
    DebugLogger.network('📍 Destination: lat=$destLat, lon=$destLon');

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

      DebugLogger.network('📡 Status Code: ${response.statusCode}');
      DebugLogger.network('📄 Response: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;

        // Verificar si es un fallback a Moovit
        if (data['fallback'] == 'moovit') {
          DebugLogger.network(
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
            DebugLogger.network('✅ Ruta obtenida desde Moovit/Red');

            // Convertir formato de Moovit a formato GTFS para compatibilidad
            return _convertMoovitToGTFSFormat(redData);
          } else {
            DebugLogger.network(
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
      DebugLogger.network('❌ Error en solicitud de transporte público: $e');
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
      DebugLogger.network('No se pudo obtener ruta principal: $e');
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
