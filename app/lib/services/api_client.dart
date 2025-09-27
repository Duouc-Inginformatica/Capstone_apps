import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, SocketException;
import 'package:http/http.dart' as http;
import 'auth_storage.dart';

class ApiClient {
  ApiClient({String? baseUrl}) : baseUrl = _resolveBaseUrl(baseUrl);
  final String baseUrl;

  static String _resolveBaseUrl(String? provided) {
    if (provided != null && provided.isNotEmpty) return provided;
    const envBase = String.fromEnvironment('API_BASE_URL');
    if (envBase.isNotEmpty) return envBase;
    // Default heuristics: Android emulator usa 10.0.2.2
    final defaultBase = Platform.isAndroid
        ? 'http://10.0.2.2:8080'
        : 'http://127.0.0.1:8080';
    return defaultBase;
  }

  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
  }) async {
    final uri = Uri.parse('$baseUrl/api/login');
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
    final uri = Uri.parse('$baseUrl/api/register');
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
    final uri = Uri.parse('$baseUrl/api/stops').replace(
      queryParameters: {
        'lat': lat.toString(),
        'lon': lon.toString(),
        'radius': radius.toString(),
        'limit': limit.toString(),
      },
    );

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
    final uri = Uri.parse('$baseUrl/api/gtfs/sync');
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
    final uri = Uri.parse('$baseUrl/api/route/transit');
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
      return await request().timeout(const Duration(seconds: 20));
    } on SocketException {
      throw ApiException(
        message: 'No se pudo conectar con el servidor.',
        statusCode: 0,
      );
    } on TimeoutException {
      throw ApiException(
        message: 'La petición tardó demasiado. Inténtalo de nuevo.',
        statusCode: 0,
      );
    }
  }
}

class ApiException implements Exception {
  ApiException({required this.message, required this.statusCode});
  final String message;
  final int statusCode;
  @override
  String toString() => 'ApiException($statusCode): $message';
}
