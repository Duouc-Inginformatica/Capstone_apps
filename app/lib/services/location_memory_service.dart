import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

/// Servicio para recordar y analizar ubicaciones frecuentes del usuario
/// Sprint 5: Recordar antes de llegar al paradero
class LocationMemoryService {
  LocationMemoryService._internal();
  static final LocationMemoryService instance =
      LocationMemoryService._internal();

  // Almacenamiento de viajes
  final List<TripRecord> _tripHistory = [];
  final List<FrequentLocation> _frequentLocations = [];

  // Preferencias
  static const String _prefKeyTrips = 'trip_history';
  static const String _prefKeyLocations = 'frequent_locations';
  static const int _maxTripHistory = 50;

  /// Cargar historial desde almacenamiento
  Future<void> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();

    // Cargar viajes
    final tripsJson = prefs.getString(_prefKeyTrips);
    if (tripsJson != null) {
      final List<dynamic> tripsList = jsonDecode(tripsJson);
      _tripHistory.clear();
      _tripHistory.addAll(
        tripsList.map((json) => TripRecord.fromJson(json)).toList(),
      );
    }

    // Cargar ubicaciones frecuentes
    final locationsJson = prefs.getString(_prefKeyLocations);
    if (locationsJson != null) {
      final List<dynamic> locationsList = jsonDecode(locationsJson);
      _frequentLocations.clear();
      _frequentLocations.addAll(
        locationsList.map((json) => FrequentLocation.fromJson(json)).toList(),
      );
    }

    _analyzePatterns();
  }

  /// Guardar historial
  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();

    // Guardar solo los últimos 50 viajes
    final tripsToSave = _tripHistory.take(_maxTripHistory).toList();
    await prefs.setString(
      _prefKeyTrips,
      jsonEncode(tripsToSave.map((trip) => trip.toJson()).toList()),
    );

    await prefs.setString(
      _prefKeyLocations,
      jsonEncode(_frequentLocations.map((loc) => loc.toJson()).toList()),
    );
  }

  /// Registrar un nuevo viaje
  Future<void> recordTrip({
    required LatLng origin,
    required LatLng destination,
    required String destinationName,
    required Duration duration,
    required double distanceMeters,
    String? busRoute,
    List<LatLng>? routeTaken,
  }) async {
    final trip = TripRecord(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      origin: origin,
      destination: destination,
      destinationName: destinationName,
      timestamp: DateTime.now(),
      duration: duration,
      distanceMeters: distanceMeters,
      busRoute: busRoute,
      routeTaken: routeTaken ?? [],
    );

    _tripHistory.insert(0, trip);

    // Actualizar ubicaciones frecuentes
    _updateFrequentLocations(destination, destinationName);

    await _saveHistory();
    _analyzePatterns();
  }

  /// Actualizar ubicaciones frecuentes
  void _updateFrequentLocations(LatLng location, String name) {
    // Buscar si ya existe una ubicación cercana (dentro de 100m)
    final existingIndex = _frequentLocations.indexWhere(
      (freq) => _calculateDistance(freq.location, location) < 100,
    );

    if (existingIndex != -1) {
      // Incrementar contador de visitas
      _frequentLocations[existingIndex] = _frequentLocations[existingIndex]
          .copyWith(
            visitCount: _frequentLocations[existingIndex].visitCount + 1,
            lastVisit: DateTime.now(),
            name: name, // Actualizar nombre si cambió
          );
    } else {
      // Nueva ubicación frecuente
      _frequentLocations.add(
        FrequentLocation(
          location: location,
          name: name,
          visitCount: 1,
          firstVisit: DateTime.now(),
          lastVisit: DateTime.now(),
        ),
      );
    }

    // Ordenar por frecuencia de visitas
    _frequentLocations.sort((a, b) => b.visitCount.compareTo(a.visitCount));
  }

  /// Analizar patrones de viaje
  void _analyzePatterns() {
    // Identificar rutas frecuentes
    // Identificar horarios típicos
    // Identificar paradas más usadas
  }

  /// Obtener ubicaciones frecuentes
  List<FrequentLocation> getFrequentLocations({int limit = 10}) {
    return _frequentLocations.take(limit).toList();
  }

  /// Obtener viajes recientes
  List<TripRecord> getRecentTrips({int limit = 10}) {
    return _tripHistory.take(limit).toList();
  }

  /// Verificar si está cerca de una ubicación frecuente
  FrequentLocation? getNearbyFrequentLocation(LatLng currentLocation) {
    for (final freq in _frequentLocations) {
      final distance = _calculateDistance(currentLocation, freq.location);
      if (distance < 200) {
        // Dentro de 200 metros
        return freq;
      }
    }
    return null;
  }

  /// Sugerir destinos basados en historial
  List<FrequentLocation> suggestDestinations({
    required DateTime currentTime,
    LatLng? currentLocation,
  }) {
    final suggestions = <FrequentLocation>[];

    // Basado en hora del día
    final hour = currentTime.hour;
    final dayOfWeek = currentTime.weekday;

    // Filtrar viajes similares por hora
    final similarTrips = _tripHistory.where((trip) {
      final tripHour = trip.timestamp.hour;
      final tripDay = trip.timestamp.weekday;

      // Mismo día de la semana y hora similar (+/- 2 horas)
      return tripDay == dayOfWeek && (tripHour - hour).abs() <= 2;
    }).toList();

    // Obtener destinos más frecuentes en este contexto
    final destinationCounts = <String, int>{};
    for (final trip in similarTrips) {
      destinationCounts[trip.destinationName] =
          (destinationCounts[trip.destinationName] ?? 0) + 1;
    }

    // Ordenar por frecuencia
    final sortedDestinations = destinationCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // Convertir a FrequentLocation
    for (final entry in sortedDestinations.take(5)) {
      final freq = _frequentLocations.firstWhere(
        (loc) => loc.name == entry.key,
        orElse: () => FrequentLocation(
          location: const LatLng(0, 0),
          name: entry.key,
          visitCount: entry.value,
          firstVisit: DateTime.now(),
          lastVisit: DateTime.now(),
        ),
      );
      suggestions.add(freq);
    }

    return suggestions;
  }

  /// Calcular distancia entre dos puntos
  double _calculateDistance(LatLng point1, LatLng point2) {
    return Geolocator.distanceBetween(
      point1.latitude,
      point1.longitude,
      point2.latitude,
      point2.longitude,
    );
  }

  /// Obtener estadísticas de viajes
  TripStatistics getStatistics() {
    if (_tripHistory.isEmpty) {
      return TripStatistics(
        totalTrips: 0,
        totalDistance: 0,
        totalDuration: Duration.zero,
        averageDistance: 0,
        averageDuration: Duration.zero,
        mostVisitedLocation: null,
        favoriteTimeOfDay: null,
      );
    }

    final totalTrips = _tripHistory.length;
    final totalDistance = _tripHistory.fold<double>(
      0,
      (sum, trip) => sum + trip.distanceMeters,
    );
    final totalDuration = _tripHistory.fold<Duration>(
      Duration.zero,
      (sum, trip) => sum + trip.duration,
    );

    final mostVisited = _frequentLocations.isNotEmpty
        ? _frequentLocations.first.name
        : null;

    // Calcular hora favorita
    final hourCounts = <int, int>{};
    for (final trip in _tripHistory) {
      final hour = trip.timestamp.hour;
      hourCounts[hour] = (hourCounts[hour] ?? 0) + 1;
    }

    final favoriteHour = hourCounts.entries
        .reduce((a, b) => a.value > b.value ? a : b)
        .key;

    return TripStatistics(
      totalTrips: totalTrips,
      totalDistance: totalDistance,
      totalDuration: totalDuration,
      averageDistance: totalDistance / totalTrips,
      averageDuration: Duration(
        milliseconds: totalDuration.inMilliseconds ~/ totalTrips,
      ),
      mostVisitedLocation: mostVisited,
      favoriteTimeOfDay: '$favoriteHour:00',
    );
  }

  /// Limpiar historial antiguo
  Future<void> clearOldHistory({int daysToKeep = 30}) async {
    final cutoffDate = DateTime.now().subtract(Duration(days: daysToKeep));

    _tripHistory.removeWhere((trip) => trip.timestamp.isBefore(cutoffDate));

    await _saveHistory();
  }
}

/// Modelo de viaje registrado
class TripRecord {
  final String id;
  final LatLng origin;
  final LatLng destination;
  final String destinationName;
  final DateTime timestamp;
  final Duration duration;
  final double distanceMeters;
  final String? busRoute;
  final List<LatLng> routeTaken;

  TripRecord({
    required this.id,
    required this.origin,
    required this.destination,
    required this.destinationName,
    required this.timestamp,
    required this.duration,
    required this.distanceMeters,
    this.busRoute,
    required this.routeTaken,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'origin': {'lat': origin.latitude, 'lon': origin.longitude},
    'destination': {'lat': destination.latitude, 'lon': destination.longitude},
    'destinationName': destinationName,
    'timestamp': timestamp.toIso8601String(),
    'duration': duration.inSeconds,
    'distanceMeters': distanceMeters,
    'busRoute': busRoute,
    'routeTaken': routeTaken
        .map((p) => {'lat': p.latitude, 'lon': p.longitude})
        .toList(),
  };

  factory TripRecord.fromJson(Map<String, dynamic> json) => TripRecord(
    id: json['id'],
    origin: LatLng(json['origin']['lat'], json['origin']['lon']),
    destination: LatLng(json['destination']['lat'], json['destination']['lon']),
    destinationName: json['destinationName'],
    timestamp: DateTime.parse(json['timestamp']),
    duration: Duration(seconds: json['duration']),
    distanceMeters: json['distanceMeters'],
    busRoute: json['busRoute'],
    routeTaken: (json['routeTaken'] as List<dynamic>)
        .map((p) => LatLng(p['lat'], p['lon']))
        .toList(),
  );
}

/// Modelo de ubicación frecuente
class FrequentLocation {
  final LatLng location;
  final String name;
  final int visitCount;
  final DateTime firstVisit;
  final DateTime lastVisit;

  FrequentLocation({
    required this.location,
    required this.name,
    required this.visitCount,
    required this.firstVisit,
    required this.lastVisit,
  });

  FrequentLocation copyWith({
    LatLng? location,
    String? name,
    int? visitCount,
    DateTime? firstVisit,
    DateTime? lastVisit,
  }) {
    return FrequentLocation(
      location: location ?? this.location,
      name: name ?? this.name,
      visitCount: visitCount ?? this.visitCount,
      firstVisit: firstVisit ?? this.firstVisit,
      lastVisit: lastVisit ?? this.lastVisit,
    );
  }

  Map<String, dynamic> toJson() => {
    'location': {'lat': location.latitude, 'lon': location.longitude},
    'name': name,
    'visitCount': visitCount,
    'firstVisit': firstVisit.toIso8601String(),
    'lastVisit': lastVisit.toIso8601String(),
  };

  factory FrequentLocation.fromJson(Map<String, dynamic> json) =>
      FrequentLocation(
        location: LatLng(json['location']['lat'], json['location']['lon']),
        name: json['name'],
        visitCount: json['visitCount'],
        firstVisit: DateTime.parse(json['firstVisit']),
        lastVisit: DateTime.parse(json['lastVisit']),
      );
}

/// Estadísticas de viajes
class TripStatistics {
  final int totalTrips;
  final double totalDistance;
  final Duration totalDuration;
  final double averageDistance;
  final Duration averageDuration;
  final String? mostVisitedLocation;
  final String? favoriteTimeOfDay;

  TripStatistics({
    required this.totalTrips,
    required this.totalDistance,
    required this.totalDuration,
    required this.averageDistance,
    required this.averageDuration,
    this.mostVisitedLocation,
    this.favoriteTimeOfDay,
  });
}
