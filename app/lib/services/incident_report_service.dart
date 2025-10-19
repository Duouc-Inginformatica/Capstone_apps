// ============================================================================
// INCIDENT REPORT SERVICE - Sprint 7 CAP-36
// ============================================================================
// Sistema de reportes de incidentes en transporte público:
// - Reportar buses llenos, paradas fuera de servicio, etc.
// - Compartir con la comunidad
// - Ver incidentes recientes de otros usuarios
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
// import 'api_client.dart'; // TODO: descomentar cuando endpoint esté listo

enum IncidentType {
  busFull,
  busDelayed,
  busNotRunning,
  stopOutOfService,
  stopDamaged,
  unsafeArea,
  accessibility,
  other,
}

enum IncidentSeverity { low, medium, high, critical }

class Incident {
  Incident({
    required this.id,
    required this.type,
    required this.location,
    required this.severity,
    required this.timestamp,
    required this.reporterId,
    this.routeName,
    this.stopName,
    this.description,
    this.isVerified = false,
    this.upvotes = 0,
    this.downvotes = 0,
  });

  final String id;
  final IncidentType type;
  final LatLng location;
  final IncidentSeverity severity;
  final DateTime timestamp;
  final String reporterId;
  final String? routeName;
  final String? stopName;
  final String? description;
  bool isVerified;
  int upvotes;
  int downvotes;

  bool get isRecent {
    final age = DateTime.now().difference(timestamp);
    return age.inHours < 24;
  }

  String get typeText {
    switch (type) {
      case IncidentType.busFull:
        return 'Bus lleno';
      case IncidentType.busDelayed:
        return 'Bus retrasado';
      case IncidentType.busNotRunning:
        return 'Bus no circula';
      case IncidentType.stopOutOfService:
        return 'Parada fuera de servicio';
      case IncidentType.stopDamaged:
        return 'Parada dañada';
      case IncidentType.unsafeArea:
        return 'Área insegura';
      case IncidentType.accessibility:
        return 'Problema de accesibilidad';
      case IncidentType.other:
        return 'Otro problema';
    }
  }

  String get severityText {
    switch (severity) {
      case IncidentSeverity.low:
        return 'Baja';
      case IncidentSeverity.medium:
        return 'Media';
      case IncidentSeverity.high:
        return 'Alta';
      case IncidentSeverity.critical:
        return 'Crítica';
    }
  }

  String get severityIcon {
    switch (severity) {
      case IncidentSeverity.low:
        return 'ℹ️';
      case IncidentSeverity.medium:
        return '⚠️';
      case IncidentSeverity.high:
        return '🚨';
      case IncidentSeverity.critical:
        return '🆘';
    }
  }

  int get score => upvotes - downvotes;

  String getSummary() {
    final buffer = StringBuffer();
    buffer.write('$severityIcon $typeText');

    if (routeName != null) {
      buffer.write(' - Ruta $routeName');
    }

    if (stopName != null) {
      buffer.write(' en $stopName');
    }

    if (description != null && description!.isNotEmpty) {
      buffer.write(': $description');
    }

    if (isVerified) {
      buffer.write(' ✓');
    }

    return buffer.toString();
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.index,
    'location': {'lat': location.latitude, 'lon': location.longitude},
    'severity': severity.index,
    'timestamp': timestamp.toIso8601String(),
    'reporterId': reporterId,
    'routeName': routeName,
    'stopName': stopName,
    'description': description,
    'isVerified': isVerified,
    'upvotes': upvotes,
    'downvotes': downvotes,
  };

  factory Incident.fromJson(Map<String, dynamic> json) {
    final locationData = json['location'] as Map<String, dynamic>;
    return Incident(
      id: json['id'] as String,
      type: IncidentType.values[json['type'] as int],
      location: LatLng(
        (locationData['lat'] as num).toDouble(),
        (locationData['lon'] as num).toDouble(),
      ),
      severity: IncidentSeverity.values[json['severity'] as int],
      timestamp: DateTime.parse(json['timestamp'] as String),
      reporterId: json['reporterId'] as String,
      routeName: json['routeName'] as String?,
      stopName: json['stopName'] as String?,
      description: json['description'] as String?,
      isVerified: json['isVerified'] as bool? ?? false,
      upvotes: json['upvotes'] as int? ?? 0,
      downvotes: json['downvotes'] as int? ?? 0,
    );
  }
}

class IncidentReportService {
  static final IncidentReportService instance = IncidentReportService._();
  IncidentReportService._();

  static const String _incidentsKey = 'reported_incidents';
  static const String _userIdKey = 'user_id';

  final List<Incident> _localIncidents = [];
  String? _userId;

  // Stream para nuevos incidentes
  final _incidentController = StreamController<Incident>.broadcast();
  Stream<Incident> get incidentStream => _incidentController.stream;

  /// Inicializar servicio
  Future<void> initialize() async {
    await _loadUserId();
    await loadIncidents();
    _cleanOldIncidents();
  }

  /// Reportar nuevo incidente
  Future<Incident> reportIncident({
    required IncidentType type,
    required LatLng location,
    required IncidentSeverity severity,
    String? routeName,
    String? stopName,
    String? description,
  }) async {
    final incident = Incident(
      id: _generateIncidentId(),
      type: type,
      location: location,
      severity: severity,
      timestamp: DateTime.now(),
      reporterId: _userId ?? 'anonymous',
      routeName: routeName,
      stopName: stopName,
      description: description,
    );

    _localIncidents.insert(0, incident);
    await _saveIncidents();

    _incidentController.add(incident);

    // Enviar reporte al backend (TODO: implementar cuando el endpoint esté listo)
    // await _uploadIncidentToServer(incident);

    return incident;
  }

  /// Subir incidente al servidor
  /// TODO: Implementar cuando el backend tenga endpoint /api/incidents/report
  Future<void> _uploadIncidentToServer(Incident incident) async {
    // try {
    //   await ApiClient.instance.post('/api/incidents/report', {
    //     'type': incident.type.toString(),
    //     'location': {
    //       'lat': incident.location.latitude,
    //       'lng': incident.location.longitude,
    //     },
    //     'severity': incident.severity.toString(),
    //     'route_name': incident.routeName,
    //     'stop_name': incident.stopName,
    //     'description': incident.description,
    //     'timestamp': incident.timestamp.toIso8601String(),
    //   });
    //   print('✅ [INCIDENT] Reporte enviado al servidor');
    // } catch (e) {
    //   print('❌ [INCIDENT] Error enviando reporte: $e');
    // }
  }

  /// Reportar bus lleno
  Future<Incident> reportBusFull({
    required String routeName,
    required LatLng location,
    String? stopName,
  }) async {
    return reportIncident(
      type: IncidentType.busFull,
      location: location,
      severity: IncidentSeverity.medium,
      routeName: routeName,
      stopName: stopName,
      description: 'Bus completamente lleno, no permite abordar',
    );
  }

  /// Reportar bus retrasado
  Future<Incident> reportBusDelayed({
    required String routeName,
    required LatLng location,
    String? stopName,
    int? delayMinutes,
  }) async {
    final description = delayMinutes != null
        ? 'Bus retrasado aproximadamente $delayMinutes minutos'
        : 'Bus con retraso significativo';

    return reportIncident(
      type: IncidentType.busDelayed,
      location: location,
      severity: IncidentSeverity.low,
      routeName: routeName,
      stopName: stopName,
      description: description,
    );
  }

  /// Reportar parada fuera de servicio
  Future<Incident> reportStopOutOfService({
    required LatLng location,
    required String stopName,
    String? reason,
  }) async {
    return reportIncident(
      type: IncidentType.stopOutOfService,
      location: location,
      severity: IncidentSeverity.high,
      stopName: stopName,
      description: reason ?? 'Parada temporalmente fuera de servicio',
    );
  }

  /// Reportar problema de accesibilidad
  Future<Incident> reportAccessibilityIssue({
    required LatLng location,
    required String description,
    String? stopName,
  }) async {
    return reportIncident(
      type: IncidentType.accessibility,
      location: location,
      severity: IncidentSeverity.high,
      stopName: stopName,
      description: description,
    );
  }

  /// Votar por un incidente
  Future<void> upvoteIncident(String incidentId) async {
    final incident = _localIncidents.firstWhere((i) => i.id == incidentId);
    incident.upvotes++;
    await _saveIncidents();
  }

  /// Votar en contra de un incidente
  Future<void> downvoteIncident(String incidentId) async {
    final incident = _localIncidents.firstWhere((i) => i.id == incidentId);
    incident.downvotes++;
    await _saveIncidents();
  }

  /// Obtener incidentes cercanos
  List<Incident> getNearbyIncidents({
    required LatLng location,
    double radiusKm = 2.0,
    bool onlyRecent = true,
  }) {
    const distance = Distance();

    return _localIncidents.where((incident) {
      if (onlyRecent && !incident.isRecent) return false;

      final distanceKm = distance.as(
        LengthUnit.Kilometer,
        location,
        incident.location,
      );

      return distanceKm <= radiusKm;
    }).toList();
  }

  /// Obtener incidentes por ruta
  List<Incident> getIncidentsByRoute(String routeName) {
    return _localIncidents
        .where((i) => i.routeName == routeName && i.isRecent)
        .toList();
  }

  /// Obtener incidentes por parada
  List<Incident> getIncidentsByStop(String stopName) {
    return _localIncidents
        .where((i) => i.stopName == stopName && i.isRecent)
        .toList();
  }

  /// Obtener incidentes por tipo
  List<Incident> getIncidentsByType(IncidentType type) {
    return _localIncidents.where((i) => i.type == type && i.isRecent).toList();
  }

  /// Obtener todos los incidentes recientes
  List<Incident> getRecentIncidents({int limit = 20}) {
    return _localIncidents.where((i) => i.isRecent).take(limit).toList();
  }

  /// Obtener estadísticas de incidentes
  Map<String, dynamic> getIncidentStats() {
    final recent = getRecentIncidents(limit: 1000);

    final typeCount = <IncidentType, int>{};
    for (var type in IncidentType.values) {
      typeCount[type] = recent.where((i) => i.type == type).length;
    }

    final severityCount = <IncidentSeverity, int>{};
    for (var severity in IncidentSeverity.values) {
      severityCount[severity] = recent
          .where((i) => i.severity == severity)
          .length;
    }

    return {
      'totalIncidents': recent.length,
      'byType': typeCount.map((k, v) => MapEntry(k.toString(), v)),
      'bySeverity': severityCount.map((k, v) => MapEntry(k.toString(), v)),
      'verified': recent.where((i) => i.isVerified).length,
      'myReports': recent.where((i) => i.reporterId == _userId).length,
    };
  }

  /// Cargar incidentes guardados
  Future<void> loadIncidents() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final incidentsJson = prefs.getString(_incidentsKey);

      if (incidentsJson != null) {
        final List<dynamic> incidentsList = jsonDecode(incidentsJson) as List;
        _localIncidents.clear();

        for (var item in incidentsList) {
          _localIncidents.add(Incident.fromJson(item as Map<String, dynamic>));
        }
      }
    } catch (e) {
      print('Error loading incidents: $e');
    }
  }

  // ============================================================================
  // MÉTODOS PRIVADOS
  // ============================================================================

  Future<void> _loadUserId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _userId = prefs.getString(_userIdKey);

      if (_userId == null) {
        _userId = _generateUserId();
        await prefs.setString(_userIdKey, _userId!);
      }
    } catch (e) {
      print('Error loading user ID: $e');
      _userId = 'anonymous';
    }
  }

  Future<void> _saveIncidents() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final incidentsJson = jsonEncode(
        _localIncidents.map((i) => i.toJson()).toList(),
      );
      await prefs.setString(_incidentsKey, incidentsJson);
    } catch (e) {
      print('Error saving incidents: $e');
    }
  }

  void _cleanOldIncidents() {
    // Remover incidentes más antiguos que 7 días
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    _localIncidents.removeWhere((i) => i.timestamp.isBefore(cutoff));
    _saveIncidents();
  }

  String _generateIncidentId() {
    return 'INC_${DateTime.now().millisecondsSinceEpoch}';
  }

  String _generateUserId() {
    return 'USER_${DateTime.now().millisecondsSinceEpoch}';
  }

  void dispose() {
    _incidentController.close();
  }
}
