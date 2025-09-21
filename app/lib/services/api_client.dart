import 'dart:convert';
import 'dart:io' show Platform;
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
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password}),
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
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'email': email,
        'password': password,
        'name': name,
      }),
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
}

class ApiException implements Exception {
  ApiException({required this.message, required this.statusCode});
  final String message;
  final int statusCode;
  @override
  String toString() => 'ApiException($statusCode): $message';
}
