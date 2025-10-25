import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Servicio para enviar logs y eventos al Debug Dashboard
/// Solo envía datos cuando LUNCH_WEB_DEBUG_DASHBOARD está habilitado en el backend
class DebugDashboardService {
  static const String _baseUrl = 'http://192.168.1.207:8080/api/debug';
  static bool _enabled = false;
  static int? _userId;

  static Future<void> initialize() async {
    // Verificar si el dashboard está habilitado
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/log'),
        headers: {'Content-Type': 'application/json'},
      ).timeout(const Duration(seconds: 2));
      
      _enabled = response.statusCode != 404;
      
      // Obtener userId si está disponible
      final prefs = await SharedPreferences.getInstance();
      _userId = prefs.getInt('userId');
      
      if (_enabled) {
        print('🐛 Debug Dashboard: Habilitado');
      }
    } catch (e) {
      _enabled = false;
      // Silenciar el error, el dashboard simplemente no está disponible
    }
  }

  /// Enviar log al dashboard
  static Future<void> sendLog({
    required String level,
    required String message,
    Map<String, dynamic>? metadata,
  }) async {
    if (!_enabled) return;

    try {
      await http.post(
        Uri.parse('$_baseUrl/log'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'source': 'frontend',
          'level': level,
          'message': message,
          'metadata': metadata,
          'userId': _userId,
        }),
      ).timeout(const Duration(seconds: 1));
    } catch (e) {
      // Silenciar errores para no interferir con la app
    }
  }

  /// Enviar evento al dashboard
  static Future<void> sendEvent({
    required String eventType,
    Map<String, dynamic>? metadata,
  }) async {
    if (!_enabled) return;

    try {
      await http.post(
        Uri.parse('$_baseUrl/event'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'eventType': eventType,
          'metadata': metadata ?? {},
          'userId': _userId,
        }),
      ).timeout(const Duration(seconds: 1));
    } catch (e) {
      // Silenciar errores
    }
  }

  /// Enviar error al dashboard
  static Future<void> sendError({
    required String errorType,
    required String message,
    String? stackTrace,
    Map<String, dynamic>? metadata,
  }) async {
    if (!_enabled) return;

    try {
      await http.post(
        Uri.parse('$_baseUrl/error'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'errorType': errorType,
          'message': message,
          'stackTrace': stackTrace,
          'metadata': metadata,
          'userId': _userId,
        }),
      ).timeout(const Duration(seconds: 1));
    } catch (e) {
      // Silenciar errores
    }
  }

  /// Enviar métricas al dashboard
  static Future<void> sendMetrics({
    double? gpsAccuracy,
    int? ttsResponseTime,
    int? apiResponseTime,
    required bool navigationActive,
  }) async {
    if (!_enabled) return;

    try {
      await http.post(
        Uri.parse('$_baseUrl/metrics'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'gpsAccuracy': gpsAccuracy,
          'ttsResponseTime': ttsResponseTime,
          'apiResponseTime': apiResponseTime,
          'navigationActive': navigationActive,
          'userId': _userId,
        }),
      ).timeout(const Duration(seconds: 1));
    } catch (e) {
      // Silenciar errores
    }
  }

  /// Enviar evento de navegación al dashboard
  static Future<void> sendNavigationEvent({
    required String eventType,
    int? currentStep,
    int? totalSteps,
    double? distanceRemaining,
    double? currentLat,
    double? currentLng,
    String? busRoute,
    String? stopName,
  }) async {
    if (!_enabled) return;

    try {
      await http.post(
        Uri.parse('$_baseUrl/navigation'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'eventType': eventType,
          'currentStep': currentStep,
          'totalSteps': totalSteps,
          'distanceRemaining': distanceRemaining,
          'currentLat': currentLat,
          'currentLng': currentLng,
          'busRoute': busRoute,
          'stopName': stopName,
          'userId': _userId,
        }),
      ).timeout(const Duration(seconds: 1));
    } catch (e) {
      // Silenciar errores
    }
  }

  // Helpers para diferentes niveles de log
  static Future<void> debug(String message, [Map<String, dynamic>? metadata]) =>
      sendLog(level: 'debug', message: message, metadata: metadata);

  static Future<void> info(String message, [Map<String, dynamic>? metadata]) =>
      sendLog(level: 'info', message: message, metadata: metadata);

  static Future<void> warn(String message, [Map<String, dynamic>? metadata]) =>
      sendLog(level: 'warn', message: message, metadata: metadata);

  static Future<void> error(String message, [Map<String, dynamic>? metadata]) =>
      sendLog(level: 'error', message: message, metadata: metadata);
}
