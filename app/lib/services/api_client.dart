import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'package:http/http.dart' as http;
import 'auth_storage.dart';
import 'server_config.dart';

class ApiClient {
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
  }) async {
    final uri = _uri('/api/register');
    final res = await _safeRequest(
      () => http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'email': email,
          'password': password,
          'name': name,
        }),
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

  // Transit Routing with GraphHopper
  Future<Map<String, dynamic>> getTransitRoute({
    required double originLat,
    required double originLon,
    required double destLat,
    required double destLon,
    DateTime? departureTime,
    bool arriveBy = false,
    bool includeGeometry = true,
  }) async {
    final uri = _uri('/api/route/transit');
    final body = {
      'origin': {'lat': originLat, 'lon': originLon},
      'destination': {'lat': destLat, 'lon': destLon},
      'arrive_by': arriveBy,
      'include_geometry': includeGeometry,
    };

    if (departureTime != null) {
      body['departure_time'] = departureTime.toIso8601String();
    }

    final res = await _safeRequest(() => postAuthorized(uri, body));
    final data =
        jsonDecode(res.body.isEmpty ? '{}' : res.body) as Map<String, dynamic>;

    if (res.statusCode >= 200 && res.statusCode < 300) {
      return data;
    }

    throw ApiException(
      message: data['error']?.toString() ?? 'Failed to get transit route',
      statusCode: res.statusCode,
    );
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
