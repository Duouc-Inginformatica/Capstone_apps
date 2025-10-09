import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

class ContributionService {
  static final ContributionService _instance = ContributionService._internal();
  factory ContributionService() => _instance;
  ContributionService._internal();

  static ContributionService get instance => _instance;

  // Base URL del servidor (ajustar según tu configuración)
  final String _baseUrl = 'http://localhost:8080/api'; 

  /// Método general para enviar cualquier tipo de contribución
  Future<bool> submitContribution({
    required String type,
    required String title,
    required String description,
    String? category,
    String? busRoute,
    String? stopName,
    int? delayMinutes,
    String severity = 'medium',
    double? latitude,
    double? longitude,
    String? contactEmail,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/contributions'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'type': type,
          'category': category,
          'title': title,
          'description': description,
          'bus_route': busRoute,
          'stop_name': stopName,
          'delay_minutes': delayMinutes,
          'severity': severity,
          'latitude': latitude,
          'longitude': longitude,
          'contact_email': contactEmail,
          'timestamp': DateTime.now().toIso8601String(),
        }),
      );
      
      return response.statusCode == 200 || response.statusCode == 201;
    } catch (e) {
      print('Error submitting contribution: $e');
      return false;
    }
  } 

  /// Reportar estado del bus
  Future<bool> reportBusStatus({
    required String busRoute,
    required String status, // 'delayed', 'crowded', 'broken', 'normal'
    required double lat,
    required double lon,
    String? description,
    int? delayMinutes,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/contributions/bus-status'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'bus_route': busRoute,
          'status': status,
          'latitude': lat,
          'longitude': lon,
          'description': description,
          'delay_minutes': delayMinutes,
          'timestamp': DateTime.now().toIso8601String(),
        }),
      );
      
      return response.statusCode == 200 || response.statusCode == 201;
    } catch (e) {
      print('Error reportando estado de bus: $e');
      return false;
    }
  }

  /// Reportar problemas de ruta
  Future<bool> reportRouteIssue({
    required String routeId,
    required String issueType, // 'detour', 'suspension', 'schedule_change'
    required double lat,
    required double lon,
    String? description,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/contributions/route-issues'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'route_id': routeId,
          'issue_type': issueType,
          'latitude': lat,
          'longitude': lon,
          'description': description,
          'timestamp': DateTime.now().toIso8601String(),
        }),
      );
      
      return response.statusCode == 200 || response.statusCode == 201;
    } catch (e) {
      print('Error reportando problema de ruta: $e');
      return false;
    }
  }

  /// Reportar información de paradas
  Future<bool> reportStopInfo({
    required String stopId,
    required String infoType, // 'new_stop', 'correction', 'accessibility'
    required double lat,
    required double lon,
    String? description,
    String? correctName,
    bool? isAccessible,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/contributions/stop-info'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'stop_id': stopId,
          'info_type': infoType,
          'latitude': lat,
          'longitude': lon,
          'description': description,
          'correct_name': correctName,
          'is_accessible': isAccessible,
          'timestamp': DateTime.now().toIso8601String(),
        }),
      );
      
      return response.statusCode == 200 || response.statusCode == 201;
    } catch (e) {
      print('Error reportando info de parada: $e');
      return false;
    }
  }

  /// Enviar sugerencia general
  Future<bool> submitGeneralSuggestion({
    required String category, // 'app_improvement', 'feature_request', 'bug_report'
    required String description,
    String? contactEmail,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/contributions/suggestions'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'category': category,
          'description': description,
          'contact_email': contactEmail,
          'timestamp': DateTime.now().toIso8601String(),
        }),
      );
      
      return response.statusCode == 200 || response.statusCode == 201;
    } catch (e) {
      print('Error enviando sugerencia: $e');
      return false;
    }
  }

  /// Obtener estadísticas de contribuciones del usuario
  Future<Map<String, dynamic>?> getUserContributionStats() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/contributions/user-stats'),
        headers: {'Content-Type': 'application/json'},
      );
      
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return null;
    } catch (e) {
      print('Error obteniendo estadísticas: $e');
      return null;
    }
  }

  /// Procesar comando de voz para contribución
  String processVoiceCommand(String command) {
    final normalizedCommand = command.toLowerCase().trim();
    
    // Detectar tipo de reporte basado en palabras clave
    if (normalizedCommand.contains('retraso') || normalizedCommand.contains('retrasado')) {
      return 'bus_delay';
    } else if (normalizedCommand.contains('lleno') || normalizedCommand.contains('sobrecarga')) {
      return 'bus_crowded';
    } else if (normalizedCommand.contains('suspendido') || normalizedCommand.contains('cancelado')) {
      return 'route_suspended';
    } else if (normalizedCommand.contains('desvío') || normalizedCommand.contains('desviado')) {
      return 'route_detour';
    } else if (normalizedCommand.contains('parada nueva') || normalizedCommand.contains('nueva parada')) {
      return 'new_stop';
    } else if (normalizedCommand.contains('accesible') || normalizedCommand.contains('silla de ruedas')) {
      return 'accessibility';
    } else if (normalizedCommand.contains('sugerencia') || normalizedCommand.contains('mejora')) {
      return 'general_suggestion';
    }
    
    return 'unknown';
  }

  /// Obtener texto de ayuda para comandos de voz
  List<String> getVoiceCommandExamples() {
    return [
      'El bus está retrasado 10 minutos',
      'La línea 506 va muy llena',
      'El bus está suspendido',
      'Hay un desvío en la ruta',
      'Encontré una parada nueva',
      'Esta parada no es accesible',
      'Tengo una sugerencia para la app',
    ];
  }
}